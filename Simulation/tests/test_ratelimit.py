"""Politeness towards two free community services (R-13)."""

from __future__ import annotations

import pytest

from balloonhunter_sim.ratelimit import CeilingReached, PoliteLimiter


class FakeTime:
    """Monotonic clock whose sleeps advance it, so tests never wait."""

    def __init__(self) -> None:
        self.now = 1000.0
        self.slept: list[float] = []

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.now += seconds


def limiter(spacing: float = 1.0, ceiling: int = 5000) -> tuple[PoliteLimiter, FakeTime]:
    clock = FakeTime()
    # counter_path=None keeps the count in memory: a test must never touch the
    # host-wide counter file that real runs share.
    return (
        PoliteLimiter(
            spacing, ceiling, clock=clock.monotonic, sleep=clock.sleep, counter_path=None
        ),
        clock,
    )


def test_requests_are_serialised_with_minimum_spacing() -> None:
    """R-13: serialise with a minimum spacing rather than bursting."""
    gate, clock = limiter(spacing=1.0)
    gate.acquire()
    assert clock.slept == []
    gate.acquire()
    gate.acquire()
    assert clock.slept == [1.0, 1.0]


def test_spacing_not_applied_when_caller_is_already_slow() -> None:
    gate, clock = limiter(spacing=1.0)
    gate.acquire()
    clock.now += 30.0
    gate.acquire()
    assert clock.slept == []


def test_daily_ceiling_raises_rather_than_continuing() -> None:
    """R-13: log loudly on reaching the ceiling rather than continuing."""
    gate, _ = limiter(spacing=0.0, ceiling=3)
    for _ in range(3):
        gate.acquire()
    with pytest.raises(CeilingReached):
        gate.acquire()


def test_ceiling_counts_only_issued_requests() -> None:
    gate, _ = limiter(spacing=0.0, ceiling=10)
    for _ in range(4):
        gate.acquire()
    assert gate.count_today == 4


def test_penalty_holds_off_subsequent_requests() -> None:
    """R-13: respect 429/Retry-After by holding the whole gate, not just one call."""
    gate, clock = limiter(spacing=0.0)
    gate.acquire()
    gate.penalise(45.0)
    gate.acquire()
    assert clock.slept and clock.slept[-1] == pytest.approx(45.0)


def test_longest_penalty_wins() -> None:
    gate, clock = limiter(spacing=0.0)
    gate.penalise(10.0)
    gate.penalise(60.0)
    gate.acquire()
    assert clock.slept[-1] == pytest.approx(60.0)


# ------------------------------------------------ host-wide counter (R-13)


def test_ceiling_is_shared_between_processes(tmp_path) -> None:
    """Two limiters sharing a counter file must share one budget.

    An in-memory counter gives each process its own ceiling, so N concurrent
    runs issue N times the limit and nothing observes the total.
    """
    path = tmp_path / "requests.json"
    a = PoliteLimiter(0.0, 5, counter_path=path)
    b = PoliteLimiter(0.0, 5, counter_path=path)
    for _ in range(3):
        a.acquire()
    for _ in range(2):
        b.acquire()
    assert b.count_today == 5
    with pytest.raises(CeilingReached):
        a.acquire()
    with pytest.raises(CeilingReached):
        b.acquire()


def test_shared_counter_survives_a_new_limiter(tmp_path) -> None:
    """A restart must not hand the process a fresh budget."""
    path = tmp_path / "requests.json"
    first = PoliteLimiter(0.0, 3, counter_path=path)
    first.acquire()
    first.acquire()
    revived = PoliteLimiter(0.0, 3, counter_path=path)
    revived.acquire()
    with pytest.raises(CeilingReached):
        revived.acquire()


def test_corrupt_counter_file_does_not_kill_the_collector(tmp_path) -> None:
    path = tmp_path / "requests.json"
    path.write_text("{ not json")
    gate = PoliteLimiter(0.0, 2, counter_path=path)
    gate.acquire()
    assert gate.count_today == 1


def test_counter_resets_on_a_new_utc_day(tmp_path) -> None:
    import json as _json

    path = tmp_path / "requests.json"
    path.write_text(_json.dumps({"date": "2000-01-01", "count": 999}))
    gate = PoliteLimiter(0.0, 3, counter_path=path)
    gate.acquire()
    assert gate.count_today == 1


def test_in_memory_mode_still_works() -> None:
    gate = PoliteLimiter(0.0, 2, counter_path=None)
    gate.acquire()
    gate.acquire()
    with pytest.raises(CeilingReached):
        gate.acquire()
