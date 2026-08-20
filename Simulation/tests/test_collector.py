"""Collector orchestration.

Covers R-1, R-3, R-5, R-6, R-9, R-10, R-11, R-14, R-15, R-17 and §3 (ascent out
of scope).
"""

from __future__ import annotations

import json
from dataclasses import replace
from datetime import timedelta

from balloonhunter_sim.collector import Collector
from balloonhunter_sim.flight import State
from balloonhunter_sim.httpclient import HttpError
from balloonhunter_sim.sondehub import StationEntry
from balloonhunter_sim.storage import iso

from .conftest import T0, frames, ramp

BURST_AT = T0 + timedelta(seconds=400)


def descending_flight(cfg, hub, tawhiri, clock, serial: str = "W0000003"):
    """A collector with `serial` already past burst, with frames through descent."""
    ascent = ramp(500.0, 40.0, 100)
    peak = 500.0 + 40.0 * 99
    descent = frames(
        [peak - 25.0 * i for i in range(1, 300)],
        start=T0 + timedelta(seconds=100),
        step_s=5.0,
    )
    hub.frames[serial] = ascent + descent
    collector = Collector(cfg, hub, tawhiri, clock)
    flight = collector.track(serial, "06610", "RS41")
    collector.poll(flight)
    assert flight.state is State.DESCENT
    clock.now = flight.last_heard.t
    return collector, flight


# ------------------------------------------------------------------- R-1/R-5


def test_discover_creates_a_flight_per_unseen_serial(cfg, hub, tawhiri, clock) -> None:
    """R-1: each unseen serial in the station listing is a new flight."""
    hub.stations["06610"] = [
        StationEntry("W1", "06610", "RS41", 404.0, T0),
        StationEntry("B2", "06610", "iMet-4", 403.0, T0),
    ]
    collector = Collector(cfg, hub, tawhiri, clock)
    created = collector.discover()
    assert {f.serial for f in created} == {"W1", "B2"}
    assert collector.flights["B2"].type == "iMet-4"


def test_discover_is_idempotent(cfg, hub, tawhiri, clock) -> None:
    hub.stations["06610"] = [StationEntry("W1", "06610", "RS41", 404.0, T0)]
    collector = Collector(cfg, hub, tawhiri, clock)
    collector.discover()
    assert collector.discover() == []
    assert len(collector.flights) == 1


def test_concurrent_flights_are_independent(cfg, hub, tawhiri, clock) -> None:
    """R-5: synoptic launches are synchronised, so simultaneous descents are normal."""
    collector, first = descending_flight(cfg, hub, tawhiri, clock, "W_A")
    hub.frames["W_B"] = hub.frames["W_A"]
    second = collector.track("W_B", "06700", "RS41")
    collector.poll(second)
    assert first.state is State.DESCENT and second.state is State.DESCENT
    collector.sweep(first, clock.now)
    collector.sweep(second, clock.now)
    dirs = sorted(p.name for p in cfg.data_dir.iterdir())
    assert len(dirs) == 2, "each flight gets its own directory"


# --------------------------------------------------------------------- R-9


def test_no_sweep_before_burst(cfg, hub, tawhiri, clock) -> None:
    """§3: ascent is out of scope; the sweep is gated on burst detection."""
    hub.frames["W1"] = ramp(500.0, 30.0, 60)
    collector = Collector(cfg, hub, tawhiri, clock)
    flight = collector.track("W1", "06610")
    collector.poll(flight)
    assert flight.state is State.ASCENT
    clock.now = flight.last_heard.t
    collector.tick()
    assert tawhiri.calls == []


def test_sweep_issues_one_call_per_rate(cfg, hub, tawhiri, clock) -> None:
    """R-9: once per rate in the sweep set."""
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    written = collector.sweep(flight, clock.now)
    assert written == len(cfg.sweep_rates)
    assert [c["rate"] for c in tawhiri.calls] == list(cfg.sweep_rates)


def test_sweep_writes_one_line_per_rate(cfg, hub, tawhiri, clock) -> None:
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    collector.sweep(flight, clock.now)
    store = collector.store_for(flight)
    lines = store.predictions_path.read_text().strip().splitlines()
    assert len(lines) == len(cfg.sweep_rates)
    assert {json.loads(line)["rate"] for line in lines} == set(cfg.sweep_rates)


def test_cadence_is_dense_then_sparse(cfg, hub, tawhiri, clock) -> None:
    """R-9: 120 s for the first 20 minutes after burst, 300 s thereafter."""
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    burst = flight.burst_datetime
    assert burst is not None

    early = burst + timedelta(minutes=5)
    collector.schedule_next_sweep(flight, early)
    assert flight.next_sweep_at == early + timedelta(seconds=120)

    late = burst + timedelta(minutes=25)
    collector.schedule_next_sweep(flight, late)
    assert flight.next_sweep_at == late + timedelta(seconds=300)


def test_cadence_boundary_at_twenty_minutes(cfg) -> None:
    assert cfg.sweep_interval_s(19.9) == 120.0
    assert cfg.sweep_interval_s(20.0) == 120.0
    assert cfg.sweep_interval_s(20.1) == 300.0


# ------------------------------------------------------------------ R-10/R-11


def test_written_record_carries_dataset_and_both_speeds(cfg, hub, tawhiri, clock) -> None:
    """R-10: dataset epoch, vz_pred and vz_real on every line."""
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    collector.sweep(flight, clock.now)
    line = json.loads(
        collector.store_for(flight).predictions_path.read_text().splitlines()[0]
    )
    assert line["dataset"] == "2026-08-20T06:00:00Z"
    assert line["vz_pred"] is not None
    assert line["vz_real"] is not None
    assert line["vz_real"] < 0, "descending"


def test_written_record_carries_sonde_state(cfg, hub, tawhiri, clock) -> None:
    """R-11: the sonde's own position at the moment of the call."""
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    collector.sweep(flight, clock.now)
    line = json.loads(
        collector.store_for(flight).predictions_path.read_text().splitlines()[0]
    )
    latest = flight.latest()
    assert line["alt"] == round(latest.alt, 1)
    assert line["t"] == iso(latest.t)
    assert line["tb"] > 0, "minutes since burst"


def test_tick_time_matches_the_frame_not_the_wall_clock(cfg, hub, tawhiri, clock) -> None:
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    clock.advance(30)
    collector.sweep(flight, clock.now)
    line = json.loads(
        collector.store_for(flight).predictions_path.read_text().splitlines()[0]
    )
    assert line["t"] == iso(flight.latest().t)


# --------------------------------------------------------------------- R-15


def test_telemetry_failure_is_not_fatal(cfg, hub, tawhiri, clock) -> None:
    """R-15: a failed call shall never terminate the program or abandon a flight."""
    collector = Collector(cfg, hub, tawhiri, clock)
    flight = collector.track("W1", "06610")
    hub.fail_telemetry = HttpError("url", "boom")
    assert collector.poll(flight) is False
    assert collector.flights["W1"] is flight


def test_station_listing_failure_is_not_fatal(cfg, hub, tawhiri, clock) -> None:
    class Broken(type(hub)):  # type: ignore[misc]
        def list_station(self, station_id: str):
            raise HttpError("url", "boom")

    collector = Collector(cfg, Broken(), tawhiri, clock)
    assert collector.discover() == []


def test_rejected_rate_is_skipped_not_fatal(cfg, hub, tawhiri, clock) -> None:
    """A rate Tawhiri refuses costs one line, not the tick."""
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    tawhiri.reject_rates = {2.0}
    written = collector.sweep(flight, clock.now)
    assert written == len(cfg.sweep_rates) - 1


def test_sweep_without_telemetry_writes_nothing(cfg, hub, tawhiri, clock) -> None:
    """§8: no telemetry behind the tick means no fabricated record."""
    collector = Collector(cfg, hub, tawhiri, clock)
    flight = collector.track("W1", "06610")
    assert collector.sweep(flight, clock.now) == 0


# --------------------------------------------------------------------- R-3


def test_tick_closes_a_silent_flight(cfg, hub, tawhiri, clock) -> None:
    """R-3: closed after the silence timeout, with meta written."""
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    clock.advance(cfg.silence_timeout_s + 60)
    collector.tick()
    assert flight.state is State.CLOSED
    meta = json.loads(collector.store_for(flight).meta_path.read_text())
    assert meta["state"] == "closed"
    assert meta["last_heard"] is not None


# --------------------------------------------------------------------- R-14


def test_resume_picks_up_unclosed_flights(cfg, hub, tawhiri, clock) -> None:
    """R-14: survive restart without losing active flights."""
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    collector.sweep(flight, clock.now)

    fresh = Collector(cfg, hub, tawhiri, clock)
    resumed = fresh.resume()
    assert [f.serial for f in resumed] == [flight.serial]
    assert fresh.flights[flight.serial].type == "RS41"


def test_resume_ignores_closed_flights(cfg, hub, tawhiri, clock) -> None:
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    collector.sweep(flight, clock.now)
    collector.close(flight, clock.now)
    fresh = Collector(cfg, hub, tawhiri, clock)
    assert fresh.resume() == []


# --------------------------------------------------------------------- R-17


def test_repair_reissues_missed_ticks_marked_repaired(cfg, hub, tawhiri, clock) -> None:
    """R-17: ticks missed during an outage are re-issued and flagged."""
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    # One tick written at burst, then nothing -- the outage. On restart the
    # re-poll has already supplied the telemetry covering the gap.
    first_tick = flight.burst_datetime
    assert first_tick is not None
    collector.sweep(flight, first_tick)

    later = flight.latest().t
    clock.now = later
    repaired = collector.repair(flight, later)
    assert repaired > 0

    lines = [
        json.loads(line)
        for line in collector.store_for(flight).predictions_path.read_text().splitlines()
    ]
    assert any(line["repaired"] for line in lines)
    assert any(not line["repaired"] for line in lines)


def test_repair_skips_ticks_beyond_tawhiris_reach(cfg, hub, tawhiri, clock) -> None:
    """§2: a tick older than the dataset window is unrecoverable at any price."""
    tight = replace(cfg, repair_max_age_s=30.0)
    collector, flight = descending_flight(tight, hub, tawhiri, clock)
    first_tick = flight.latest().t
    collector.sweep(flight, first_tick)
    before = len(tawhiri.calls)

    later = first_tick + timedelta(hours=12)
    assert collector.repair(flight, later) == 0
    assert len(tawhiri.calls) == before, "no call should be attempted for an unreachable tick"


def test_repair_needs_a_prior_tick(cfg, hub, tawhiri, clock) -> None:
    collector, flight = descending_flight(cfg, hub, tawhiri, clock)
    assert collector.repair(flight, clock.now) == 0
