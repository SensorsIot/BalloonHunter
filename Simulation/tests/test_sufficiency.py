"""Does the recorded data answer the questions in §7?

§7 says implementation is complete when the dataset can answer its questions
"without further collection". These tests take what the collector actually wrote
and compute those answers from it alone -- no telemetry, no second API call.

Also covers R-2 (a flight is active from launch until it is closed).
"""

from __future__ import annotations

import json
import math
from datetime import timedelta

from balloonhunter_sim.collector import Collector
from balloonhunter_sim.flight import State

from .conftest import T0, frames, ramp

EARTH_R = 6371000.0


def haversine_bearing(a: tuple[float, float], b: tuple[float, float]) -> tuple[float, float]:
    """Great-circle distance in metres and initial bearing in degrees."""
    lat1, lon1, lat2, lon2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    distance = 2 * EARTH_R * math.asin(math.sqrt(h))
    y = math.sin(dlon) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return distance, math.degrees(math.atan2(y, x)) % 360.0


def flown(cfg, hub, tawhiri, clock, ticks: int = 5):
    """Run a full descent, sweeping at several ticks, and return the written lines."""
    serial = "W_SUFFICIENT"
    ascent = ramp(500.0, 40.0, 100)
    peak = 500.0 + 40.0 * 99
    descent = frames(
        [peak - 25.0 * i for i in range(1, 400)],
        start=T0 + timedelta(seconds=100),
        step_s=5.0,
    )
    hub.frames[serial] = ascent + descent
    collector = Collector(cfg, hub, tawhiri, clock)
    flight = collector.track(serial, "06610", "RS41")
    collector.poll(flight)
    assert flight.state is State.DESCENT

    burst = flight.burst_datetime
    assert burst is not None
    for n in range(ticks):
        collector.sweep(flight, burst + timedelta(seconds=120 * n))

    store = collector.store_for(flight)
    lines = [
        json.loads(line)
        for line in store.predictions_path.read_text().strip().splitlines()
    ]
    return collector, flight, lines


# ---------------------------------------------------------------------- R-2


def test_flight_is_active_from_launch_until_closed(cfg, hub, tawhiri, clock) -> None:
    """R-2: active from launch detection until closed by R-3."""
    serial = "W_LIFECYCLE"
    ascent = ramp(500.0, 40.0, 100)
    peak = 500.0 + 40.0 * 99
    descent = frames(
        [peak - 25.0 * i for i in range(1, 60)], start=T0 + timedelta(seconds=100), step_s=5.0
    )
    hub.frames[serial] = []
    collector = Collector(cfg, hub, tawhiri, clock)
    flight = collector.track(serial, "06610")
    assert flight.state is State.PRELAUNCH

    hub.frames[serial] = ascent
    collector.poll(flight)
    assert flight.state is State.ASCENT

    hub.frames[serial] = ascent + descent
    collector.poll(flight)
    assert flight.state is State.DESCENT

    clock.now = flight.last_heard.t + timedelta(seconds=cfg.silence_timeout_s + 1)
    collector.tick()
    assert flight.state is State.CLOSED
    assert flight.closed_at is not None


# ------------------------------------------------------------------ §7 item 1


def test_creep_distance_and_bearing_are_computable_per_rate(cfg, hub, tawhiri, clock) -> None:
    """§7.1: how far AND in which direction the predicted landing moved, per rate.

    Everything needed comes from consecutive `plat`/`plon` pairs of one rate.
    """
    _, _, lines = flown(cfg, hub, tawhiri, clock)
    by_rate: dict[float, list[dict[str, object]]] = {}
    for line in lines:
        by_rate.setdefault(float(line["rate"]), []).append(line)

    assert set(by_rate) == set(cfg.sweep_rates)
    for rate, series in by_rate.items():
        series.sort(key=lambda item: str(item["t"]))
        assert len(series) >= 2, f"rate {rate} needs consecutive ticks to show creep"
        for before, after in zip(series, series[1:], strict=False):
            distance, bearing = haversine_bearing(
                (float(before["plat"]), float(before["plon"])),
                (float(after["plat"]), float(after["plon"])),
            )
            assert distance >= 0.0
            assert 0.0 <= bearing < 360.0


def test_creep_is_measured_against_time_since_burst(cfg, hub, tawhiri, clock) -> None:
    """§7.1: 'as a function of time since burst' -- tb must be present and increasing."""
    _, _, lines = flown(cfg, hub, tawhiri, clock)
    for_rate = sorted(
        (line for line in lines if line["rate"] == cfg.sweep_rates[0]),
        key=lambda item: str(item["t"]),
    )
    tbs = [float(line["tb"]) for line in for_rate]
    assert tbs == sorted(tbs)
    assert tbs[0] >= 0.0, "the first tick is at or after burst"
    assert tbs[-1] > tbs[0]


# ------------------------------------------------------------------ §7 item 2


def test_rates_are_distinguishable_at_every_tick(cfg, hub, tawhiri, clock) -> None:
    """§7.2: which rate's prediction stops moving -- requires all rates per tick."""
    _, _, lines = flown(cfg, hub, tawhiri, clock)
    by_tick: dict[str, set[float]] = {}
    for line in lines:
        by_tick.setdefault(str(line["t"]), set()).add(float(line["rate"]))
    assert by_tick, "at least one tick"
    for tick, rates in by_tick.items():
        assert rates == set(cfg.sweep_rates), f"tick {tick} is missing rates"


# ------------------------------------------------------------------ §7 item 4


def test_modelled_and_actual_descent_rates_are_comparable(cfg, hub, tawhiri, clock) -> None:
    """§7.4: does Tawhiri's modelled rate match the sonde's actual, at the same altitude?

    The comparison must be possible from one line: vz_pred, vz_real and alt.
    """
    _, _, lines = flown(cfg, hub, tawhiri, clock)
    comparable = [
        line
        for line in lines
        if line["vz_pred"] is not None and line["vz_real"] is not None
    ]
    assert comparable, "no line supports the comparison"
    for line in comparable:
        assert line["alt"] is not None, "a rate without its altitude is meaningless (§6.3)"
        residual = float(line["vz_pred"]) - float(line["vz_real"])
        assert isinstance(residual, float)


# ------------------------------------------------------------ dataset validity


def test_dataset_epoch_present_on_every_line(cfg, hub, tawhiri, clock) -> None:
    """R-10: the epoch is what separates real creep from a wind model change."""
    _, _, lines = flown(cfg, hub, tawhiri, clock)
    assert all(line["dataset"] == "2026-08-20T06:00:00Z" for line in lines)


def test_repaired_ticks_are_distinguishable_from_live_ones(cfg, hub, tawhiri, clock) -> None:
    """R-17: the analysis must be able to exclude a contaminated repair."""
    collector, flight, lines = flown(cfg, hub, tawhiri, clock, ticks=2)
    assert all(line["repaired"] is False for line in lines)

    tawhiri.dataset = "2026-08-20T12:00:00Z"  # a newer GFS run loaded
    collector.repair(flight, flight.latest().t)
    after = [
        json.loads(line)
        for line in collector.store_for(flight).predictions_path.read_text().splitlines()
    ]
    repaired = [line for line in after if line["repaired"]]
    assert repaired, "repair wrote nothing"
    assert all(line["dataset"] == "2026-08-20T12:00:00Z" for line in repaired)
    # Equal epoch => equivalent to live; advanced epoch => exclude.
    live_epochs = {line["dataset"] for line in after if not line["repaired"]}
    assert live_epochs == {"2026-08-20T06:00:00Z"}


# ------------------------------------------------------------- self-containment


def test_analysis_needs_no_fields_beyond_the_record(cfg, hub, tawhiri, clock) -> None:
    """§6.2: the eight necessary fields plus lat/lon/repaired, and nothing missing."""
    _, _, lines = flown(cfg, hub, tawhiri, clock)
    required = {"t", "tb", "rate", "alt", "plat", "plon", "vz_real", "vz_pred", "dataset"}
    for line in lines:
        assert required <= set(line)
        assert all(line[key] is not None for key in ("t", "tb", "rate", "alt", "plat", "plon"))
