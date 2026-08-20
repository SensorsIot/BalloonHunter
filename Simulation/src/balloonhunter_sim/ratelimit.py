"""Request pacing and the daily ceiling (R-13).

SondeHub and Tawhiri are free community services. Requests are serialised with a
minimum spacing rather than bursting, and a daily ceiling exists to catch a
runaway loop -- not to throttle normal operation, which at ~2000 calls/day sits
well under it.

The ceiling is counted in a **file shared by every process on the host**, not in
memory. An in-memory counter gives each process its own budget, so N processes
issue N times the ceiling and nothing observes the total -- which is exactly what
happened while analysing flights on 2026-08-20.
"""

from __future__ import annotations

import fcntl
import json
import logging
import os
import threading
import time
from datetime import UTC, date, datetime
from pathlib import Path

log = logging.getLogger(__name__)

#: Shared across processes; overridable per Config.
DEFAULT_COUNTER_PATH = Path.home() / ".cache" / "sonde-collector" / "requests.json"


class CeilingReached(RuntimeError):
    """The daily request ceiling was hit. R-13 requires logging loudly, not continuing."""


class PoliteLimiter:
    """Serialises requests with a minimum spacing and enforces a daily ceiling."""

    def __init__(
        self,
        min_spacing_s: float,
        daily_ceiling: int,
        clock: object = None,
        sleep: object = None,
        counter_path: Path | None = DEFAULT_COUNTER_PATH,
    ) -> None:
        self._min_spacing_s = min_spacing_s
        self._daily_ceiling = daily_ceiling
        self._monotonic = clock if callable(clock) else time.monotonic
        self._sleep = sleep if callable(sleep) else time.sleep
        self._lock = threading.Lock()
        self._last_at: float | None = None
        self._penalty_until: float | None = None
        self._day: date = self._today()
        self._count = 0
        #: None keeps the count in memory (tests). A path shares it host-wide.
        self._counter_path = counter_path

    @staticmethod
    def _today() -> date:
        return datetime.now(UTC).date()

    @property
    def count_today(self) -> int:
        return self._count

    def _bump_shared(self, today: date) -> int:
        """Increment the host-wide counter under an exclusive lock."""
        path = self._counter_path
        assert path is not None
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            raw = os.read(fd, 4096).decode("utf-8").strip()
            state: dict[str, object] = {}
            if raw:
                try:
                    loaded = json.loads(raw)
                    if isinstance(loaded, dict):
                        state = loaded
                except json.JSONDecodeError:
                    pass  # corrupt counter: start the day again rather than die
            stamp = str(today)
            count = state.get("count")
            n = int(count) if state.get("date") == stamp and isinstance(count, int) else 0
            if n >= self._daily_ceiling:
                raise CeilingReached(
                    f"daily request ceiling of {self._daily_ceiling} reached "
                    f"({n} requests on {stamp}, counted across every process); "
                    "refusing to continue"
                )
            n += 1
            os.lseek(fd, 0, os.SEEK_SET)
            os.ftruncate(fd, 0)
            os.write(fd, json.dumps({"date": stamp, "count": n}).encode("utf-8"))
            return n
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def acquire(self) -> None:
        """Block until it is polite to issue the next request."""
        with self._lock:
            today = self._today()
            if today != self._day:
                log.info("new UTC day, resetting request count (was %d)", self._count)
                self._day = today
                self._count = 0

            if self._counter_path is not None:
                self._count = self._bump_shared(today)
            elif self._count >= self._daily_ceiling:
                raise CeilingReached(
                    f"daily request ceiling of {self._daily_ceiling} reached "
                    f"({self._count} requests on {self._day}); refusing to continue"
                )

            now = float(self._monotonic())
            due = now
            if self._last_at is not None:
                due = max(due, self._last_at + self._min_spacing_s)
            if self._penalty_until is not None:
                due = max(due, self._penalty_until)
            wait = due - now
            if wait > 0:
                self._sleep(wait)
                now = due
            self._last_at = now
            if self._counter_path is None:
                self._count += 1  # shared mode already counted in _bump_shared

    def penalise(self, seconds: float) -> None:
        """Hold off all requests for `seconds` after a 429."""
        with self._lock:
            until = float(self._monotonic()) + seconds
            if self._penalty_until is None or until > self._penalty_until:
                self._penalty_until = until
