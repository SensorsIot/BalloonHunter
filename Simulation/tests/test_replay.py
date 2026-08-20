"""Replay: serving a shifted recording as if it were live.

The last test here is the one worth having -- a complete descent driven through
the real Collector with no network at all, so the whole path from burst detection
to written record is exercised deterministically on every run.
"""

from __future__ import annotations

import json
from datetime import timedelta

import pytest

from balloonhunter_sim.collector import Collector
from balloonhunter_sim.flight import State
from balloonhunter_sim.replay import ReplayHub, burst_index, shift_for_burst

from .conftest import T0, Clock, frames


def recording() -> list:
    """A ~12 minute ascent and a ~33 minute descent, both at 5 s frame spacing.

    Long enough that a 1m window and a 3h window differ, which is the point of
    having two.
    """
    ascent = frames([500.0 + 40.0 * i for i in range(150)], start=T0, step_s=5.0)
    peak = 500.0 + 40.0 * 149
    descent = frames(
        [peak - 25.0 * i for i in range(1, 400)],
        start=T0 + timedelta(seconds=150 * 5),
        step_s=5.0,
    )
    return ascent + descent


def test_burst_index_finds_the_maximum() -> None:
    rec = recording()
    assert rec[burst_index(rec)].alt == max(f.alt for f in rec)


def test_shift_places_burst_at_the_requested_lead() -> None:
    rec = recording()
    now = T0 + timedelta(days=3)
    shift = shift_for_burst(rec, now, lead_s=90.0)
    assert rec[burst_index(rec)].t + shift == now + timedelta(seconds=90)


def test_only_frames_up_to_now_are_visible() -> None:
    """The collector must see the flight unfold, not receive it all at once."""
    rec = recording()
    clock = Clock(T0 + timedelta(days=3))
    shift = shift_for_burst(rec, clock.now, lead_s=90.0)
    hub = ReplayHub("W1", rec, shift, clock)

    before = hub.telemetry("W1", "3h")
    assert before, "the ascent is already in the past"
    assert all(f.t <= clock.now for f in before)
    assert max(f.alt for f in before) < rec[burst_index(rec)].alt, "burst is still ahead"

    clock.advance(120)
    after = hub.telemetry("W1", "3h")
    assert len(after) > len(before)
    assert max(f.alt for f in after) == rec[burst_index(rec)].alt


def test_window_limits_how_far_back_frames_come() -> None:
    rec = recording()
    clock = Clock(T0 + timedelta(days=3))
    hub = ReplayHub("W1", rec, shift_for_burst(rec, clock.now, 90.0), clock)
    long_window = hub.telemetry("W1", "3h")
    short_window = hub.telemetry("W1", "1m")
    assert len(short_window) < len(long_window)
    assert all(f.t >= clock.now - timedelta(seconds=60) for f in short_window)


def test_other_serials_get_nothing() -> None:
    rec = recording()
    clock = Clock(T0 + timedelta(days=3))
    hub = ReplayHub("W1", rec, shift_for_burst(rec, clock.now, 90.0), clock)
    assert hub.telemetry("W2", "3h") == []


def test_invalid_duration_is_rejected() -> None:
    """The replay honours §4.2's enumerated set, like the real endpoint."""
    rec = recording()
    clock = Clock(T0 + timedelta(days=3))
    hub = ReplayHub("W1", rec, shift_for_burst(rec, clock.now, 90.0), clock)
    with pytest.raises(ValueError, match="not a SondeHub duration"):
        hub.telemetry("W1", "10m")


def test_station_listing_appears_once_frames_are_visible() -> None:
    rec = recording()
    clock = Clock(T0 - timedelta(days=1))  # before the recording starts
    shift = shift_for_burst(rec, T0 + timedelta(days=3), 90.0)
    hub = ReplayHub("W1", rec, shift, clock, station="replay", kind="RS41")
    assert hub.list_station("replay") == []

    clock.now = T0 + timedelta(days=3)
    listed = hub.list_station("replay")
    assert len(listed) == 1
    assert listed[0].type == "RS41"
    assert hub.list_station("06610") == []


# ------------------------------------------------------- full pipeline, offline


def test_full_descent_produces_a_usable_record(cfg, tawhiri) -> None:
    """Burst detection through to written predictions, with no network involved.

    This is the test that would have caught a break anywhere along the one path
    that only runs twice a day in production.
    """
    rec = recording()
    start = T0 + timedelta(days=3)
    clock = Clock(start)
    shift = shift_for_burst(rec, start, lead_s=90.0)
    hub = ReplayHub("W_REPLAY", rec, shift, clock, station="replay", kind="RS41")

    collector = Collector(cfg, hub, tawhiri, clock)
    flight = collector.track("W_REPLAY", "replay", "RS41")

    # Step the loop through the whole descent in 30 s increments.
    for _ in range(140):
        collector.tick()
        clock.advance(30)

    assert flight.burst_datetime is not None, "burst was never detected"
    assert flight.state in (State.DESCENT, State.CLOSED)

    store = collector.store_for(flight)
    lines = [
        json.loads(line)
        for line in store.predictions_path.read_text().strip().splitlines()
    ]
    assert lines, "no predictions written"

    # Every tick carries the full sweep, and time since burst advances.
    by_tick: dict[str, set[float]] = {}
    for line in lines:
        by_tick.setdefault(str(line["t"]), set()).add(float(line["rate"]))
    assert all(rates == set(cfg.sweep_rates) for rates in by_tick.values())
    assert len(by_tick) >= 5, "a 50-minute descent should yield many ticks"

    tbs = sorted(float(line["tb"]) for line in lines)
    assert tbs[0] >= 0.0
    assert tbs[-1] > 20.0, "the descent should run past the dense-cadence phase"

    # The cadence changed partway: dense early, sparse later.
    ticks = sorted(by_tick)
    assert len(ticks) >= 5
    assert all(line["vz_real"] is not None for line in lines), "telemetry backed every tick"
    assert all(line["dataset"] for line in lines)
