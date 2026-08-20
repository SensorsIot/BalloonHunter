"""Replay a completed flight with its clock shifted to the present.

A real descent happens twice a day and lasts under an hour, which makes the one
path that matters -- burst detection, the sweep, Tawhiri, the written record --
awkward to exercise. Replay solves that: take a flight that already happened,
shift every timestamp so its burst falls a minute from now, and serve the frames
to the collector as if they were arriving live.

Time runs 1:1. Frames keep their real spacing, so `vz_real` is the rate the sonde
actually fell at, and `launch_datetime` lands inside Tawhiri's loaded dataset.

**What this does and does not prove.** It exercises the pipeline against the live
API with real telemetry. It does *not* produce scientific data: the positions
come from an earlier flight while the winds are today's, so the predicted
landings correspond to nothing that ever happened. Replay output belongs in its
own directory and must never be mixed with collected flights.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import replace
from datetime import UTC, datetime, timedelta

from .config import DURATION_SECONDS
from .httpclient import HttpClient
from .sondehub import BASE, Frame, StationEntry, _frames_from

log = logging.getLogger(__name__)

Clock = Callable[[], datetime]


def fetch_history(http: HttpClient, serial: str) -> list[Frame]:
    """Load a complete past flight (§4.3).

    Measured: a three-week-old flight returns 333 282 frames in 2.4 s, which
    deduplicate to ~11 000.
    """
    payload = http.get_json(f"{BASE}/sonde/{serial}")
    frames = _frames_from(payload, serial)
    if not frames:
        raise ValueError(f"{serial}: no frames returned")
    return frames


def burst_index(frames: list[Frame]) -> int:
    return max(range(len(frames)), key=lambda i: frames[i].alt)


def shift_for_burst(frames: list[Frame], at: datetime, lead_s: float) -> timedelta:
    """The offset that places this flight's burst `lead_s` seconds after `at`."""
    return (at + timedelta(seconds=lead_s)) - frames[burst_index(frames)].t


class ReplayHub:
    """A SondeHub stand-in that serves a shifted recording as if it were live.

    Only frames whose shifted timestamp has already passed are visible, so the
    collector sees the flight unfold rather than all at once.
    """

    def __init__(
        self,
        serial: str,
        frames: list[Frame],
        shift: timedelta,
        clock: Clock,
        station: str = "replay",
        kind: str | None = None,
    ) -> None:
        self.serial = serial
        self.station = station
        self.kind = kind
        self._shift = shift
        self._clock = clock
        self._frames = [replace(f, t=f.t + shift) for f in frames]
        self.telemetry_calls: list[tuple[str, str]] = []

    @property
    def burst_at(self) -> datetime:
        return self._frames[burst_index(self._frames)].t

    @property
    def ends_at(self) -> datetime:
        return self._frames[-1].t

    def list_station(self, station_id: str) -> list[StationEntry]:
        if station_id != self.station:
            return []
        visible = self._visible()
        if not visible:
            return []
        return [
            StationEntry(
                serial=self.serial,
                station=self.station,
                type=self.kind,
                frequency=None,
                last_seen=visible[-1].t,
            )
        ]

    def telemetry(self, serial: str, duration: str) -> list[Frame]:
        self.telemetry_calls.append((serial, duration))
        if serial != self.serial:
            return []
        window = DURATION_SECONDS.get(duration)
        if window is None:
            raise ValueError(f"{duration!r} is not a SondeHub duration")
        now = self._clock()
        earliest = now - timedelta(seconds=window)
        return [f for f in self._frames if earliest <= f.t <= now]

    def _visible(self) -> list[Frame]:
        now = self._clock()
        return [f for f in self._frames if f.t <= now]


def utcnow() -> datetime:
    return datetime.now(UTC)
