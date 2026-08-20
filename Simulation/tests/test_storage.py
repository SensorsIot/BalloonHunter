"""Output format and durability.

Covers R-4, R-7, R-10, R-11, R-12, R-16, R-18 and §6.1/§6.2/§6.3.
"""

from __future__ import annotations

import json
from datetime import timedelta

from balloonhunter_sim.config import Config
from balloonhunter_sim.flight import Flight, State
from balloonhunter_sim.storage import FlightStore, PredictionRecord, iso

from .conftest import T0, ramp

EXPECTED_FIELDS = {
    "t",
    "tb",
    "rate",
    "alt",
    "lat",
    "lon",
    "plat",
    "plon",
    "vz_real",
    "vz_alt",
    "vz_pred",
    "dataset",
    "repaired",
}


def a_flight() -> Flight:
    flight = Flight(serial="W0000002", station="06610", type="RS41")
    flight.ingest(ramp(500.0, 30.0, 40), Config())
    return flight


def a_record(**kw: object) -> PredictionRecord:
    base = dict(
        t=T0,
        tb=9.3,
        rate=3.0,
        alt=22700.0,
        lat=47.31,
        lon=7.5,
        plat=47.1873,
        plon=7.7979,
        vz_real=-16.55,
        vz_alt=22300.0,
        vz_pred=-12.3,
        dataset="2026-08-20T06:00:00Z",
    )
    base.update(kw)
    return PredictionRecord(**base)  # type: ignore[arg-type]


def test_record_carries_exactly_the_specified_fields(tmp_path) -> None:
    """§6.2: the record schema."""
    obj = json.loads(a_record().to_json())
    assert set(obj) == EXPECTED_FIELDS


def test_trajectory_is_not_stored() -> None:
    """R-12: only the landing point and vz_pred are extracted from the response."""
    obj = json.loads(a_record().to_json())
    assert "trajectory" not in obj
    assert "prediction" not in obj
    assert not any("traj" in key for key in obj)


def test_dataset_epoch_is_recorded() -> None:
    """R-10: without it, real creep cannot be told from the wind model changing."""
    obj = json.loads(a_record().to_json())
    assert obj["dataset"] == "2026-08-20T06:00:00Z"


def test_both_vertical_speeds_recorded() -> None:
    """R-10: the vz_pred/vz_real pair is the instrument for the §4.4 discrepancy."""
    obj = json.loads(a_record().to_json())
    assert obj["vz_real"] == -16.55
    assert obj["vz_pred"] == -12.3


def test_sonde_state_at_call_recorded() -> None:
    """R-11: the analysis never has to infer where the sonde was."""
    obj = json.loads(a_record().to_json())
    assert (obj["alt"], obj["lat"], obj["lon"]) == (22700.0, 47.31, 7.5)


def test_null_vz_real_survives_serialisation() -> None:
    """§8: a tick with no telemetry behind it is written null, not stale."""
    obj = json.loads(a_record(vz_real=None).to_json())
    assert obj["vz_real"] is None


def test_timestamps_are_utc_iso8601() -> None:
    """R-18: mixing local and UTC would be fatal to the analysis and hard to detect."""
    obj = json.loads(a_record().to_json())
    assert obj["t"].endswith("Z")
    assert obj["t"] == "2026-08-20T12:00:00Z"
    assert iso(T0) == "2026-08-20T12:00:00Z"


def test_no_telemetry_file_is_written(tmp_path) -> None:
    """R-7: telemetry is never written; it is re-fetchable from §4.3 indefinitely."""
    flight = a_flight()
    store = FlightStore(tmp_path, flight)
    store.append(a_record())
    store.write_meta(flight)
    names = {p.name for p in store.dir.iterdir()}
    assert names == {"meta.json", "predictions.jsonl"}


def test_meta_write_is_atomic_and_leaves_no_temp_files(tmp_path) -> None:
    """R-16: write to a temporary file, then rename."""
    flight = a_flight()
    store = FlightStore(tmp_path, flight)
    for _ in range(3):
        store.write_meta(flight)
    assert json.loads(store.meta_path.read_text())["serial"] == "W0000002"
    assert not list(store.dir.glob("*.tmp"))


def test_meta_carries_type_and_station(tmp_path) -> None:
    """§6.3: the station listing is the only source of `type`."""
    flight = a_flight()
    store = FlightStore(tmp_path, flight)
    store.write_meta(flight)
    meta = json.loads(store.meta_path.read_text())
    assert meta["type"] == "RS41"
    assert meta["station"] == "06610"


def test_meta_reports_last_heard_not_a_landing(tmp_path) -> None:
    """R-4: it is the last frame received, and must not be named a landing."""
    flight = a_flight()
    store = FlightStore(tmp_path, flight)
    store.write_meta(flight)
    meta = json.loads(store.meta_path.read_text())
    assert "last_heard" in meta
    assert not any("landing" in key or "resting" in key for key in meta)
    assert meta["last_heard"]["alt"] == flight.last_heard.alt


def test_meta_exposes_gap_counts(tmp_path) -> None:
    """§8: sampling gaps must be visible in the output."""
    flight = a_flight()
    flight.ingest(ramp(2000.0, 30.0, 10, start=T0 + timedelta(seconds=900)), Config())
    store = FlightStore(tmp_path, flight)
    store.write_meta(flight)
    meta = json.loads(store.meta_path.read_text())
    assert meta["gaps"] >= 1
    assert meta["max_gap_s"] >= 60.0


def test_appends_accumulate_one_line_each(tmp_path) -> None:
    flight = a_flight()
    store = FlightStore(tmp_path, flight)
    for rate in (2.0, 3.0, 4.0, 5.0, 7.0):
        store.append(a_record(rate=rate))
    lines = store.predictions_path.read_text().strip().splitlines()
    assert len(lines) == 5
    assert [json.loads(line)["rate"] for line in lines] == [2.0, 3.0, 4.0, 5.0, 7.0]


def test_torn_final_line_is_tolerated(tmp_path) -> None:
    """§6.1: JSON Lines was chosen because a truncated tail costs one record."""
    flight = a_flight()
    store = FlightStore(tmp_path, flight)
    store.append(a_record())
    store.append(a_record(t=T0 + timedelta(seconds=120)))
    with store.predictions_path.open("a", encoding="utf-8") as handle:
        handle.write('{"t":"2026-08-20T12:04:0')  # crash mid-write
    times = store.written_tick_times()
    assert len(times) == 2, "earlier records must remain readable"


def test_closed_flight_meta_records_state(tmp_path) -> None:
    flight = a_flight()
    flight.state = State.CLOSED
    flight.closed_at = T0 + timedelta(hours=3)
    store = FlightStore(tmp_path, flight)
    store.write_meta(flight)
    meta = json.loads(store.meta_path.read_text())
    assert meta["state"] == "closed"
    assert meta["closed_at"].endswith("Z")
