"""Collector orchestration (§5).

Single-threaded on purpose: R-13 requires requests to be serialised with a
minimum spacing, which a single loop gives for free, and twelve simultaneous
descents at five rates fit inside a two-minute tick with room to spare.

The collector makes no scientific decisions (§8). It detects launch, burst and
silence so it knows *when* to ask Tawhiri, and it records what comes back.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .config import Config
from .flight import Flight, State
from .httpclient import HttpError
from .ratelimit import CeilingReached
from .sondehub import Frame, TelemetrySource
from .storage import FlightStore, PredictionRecord
from .tawhiri import PredictionRejected, Tawhiri

log = logging.getLogger(__name__)

Clock = Callable[[], datetime]


def _utcnow() -> datetime:
    return datetime.now(UTC)


class Collector:
    def __init__(
        self,
        cfg: Config,
        sondehub: TelemetrySource,
        tawhiri: Tawhiri,
        clock: Clock = _utcnow,
    ) -> None:
        self.cfg = cfg
        self._hub = sondehub
        self._tawhiri = tawhiri
        self._now = clock
        self.flights: dict[str, Flight] = {}
        self._stores: dict[str, FlightStore] = {}
        self._next_station_poll: datetime | None = None
        self._next_telemetry_poll: dict[str, datetime] = {}

    # ------------------------------------------------------------- discovery

    def discover(self) -> list[Flight]:
        """R-1: poll every configured station; each unseen serial is a new flight."""
        created: list[Flight] = []
        for station in self.cfg.stations:
            try:
                entries = self._hub.list_station(station)
            except HttpError as exc:
                log.warning("station %s listing failed: %s", station, exc)
                continue
            for entry in entries:
                flight = self.flights.get(entry.serial)
                if flight is None:
                    created.append(self.track(entry.serial, station, entry.type))
                elif flight.type is None and entry.type is not None:
                    flight.type = entry.type
        return created

    def track(self, serial: str, station: str, kind: str | None = None) -> Flight:
        """Begin following a serial. Not the same as launch -- see Flight._is_launch."""
        flight = Flight(serial=serial, station=station, type=kind)
        self.flights[serial] = flight
        log.info("tracking %s from station %s", serial, station)
        return flight

    def store_for(self, flight: Flight) -> FlightStore:
        store = self._stores.get(flight.serial)
        if store is None:
            store = FlightStore(self.cfg.data_dir, flight)
            self._stores[flight.serial] = store
        return store

    # -------------------------------------------------------------- telemetry

    def poll(self, flight: Flight) -> bool:
        """R-6: fetch the windowed telemetry and ingest it. Returns True on burst.

        The first poll of a flight replays its history, because burst detection
        compares against the running maximum altitude. Every poll after that uses
        the short steady-state window.
        """
        window = (
            self.cfg.telemetry_window
            if flight.bootstrapped
            else self.cfg.telemetry_window_initial
        )
        try:
            frames = self._hub.telemetry(flight.serial, window)
        except HttpError as exc:
            log.warning("%s telemetry failed: %s", flight.serial, exc)
            return False
        flight.bootstrapped = True
        return flight.ingest(frames, self.cfg)

    # -------------------------------------------------------------- the sweep

    def sweep(self, flight: Flight, now: datetime, repaired: bool = False) -> int:
        """R-9/R-10: one Tawhiri call per swept rate; one line written per call."""
        frame = self._frame_for(flight, now)
        if frame is None:
            log.warning("%s: no telemetry behind tick at %s, skipping", flight.serial, now)
            return 0
        store = self.store_for(flight)
        vz_real = flight.vz_real(self.cfg, at=frame.t)
        vz_alt = flight.vz_altitude(self.cfg, at=frame.t)
        written = 0
        for rate in self.cfg.sweep_rates:
            try:
                prediction = self._tawhiri.predict(
                    frame.lat, frame.lon, frame.alt, frame.t, rate
                )
            except PredictionRejected as exc:
                # Expected for a repair that has fallen out of Tawhiri's window.
                log.warning("%s rate=%.1f rejected: %s", flight.serial, rate, exc)
                continue
            except HttpError as exc:
                log.warning("%s rate=%.1f failed: %s", flight.serial, rate, exc)
                continue
            store.append(
                PredictionRecord(
                    t=frame.t,
                    tb=flight.minutes_since_burst(frame.t),
                    rate=rate,
                    alt=frame.alt,
                    lat=frame.lat,
                    lon=frame.lon,
                    plat=prediction.landing_lat,
                    plon=prediction.landing_lon,
                    vz_real=vz_real,
                    vz_alt=vz_alt,
                    vz_pred=prediction.vz_pred,
                    dataset=prediction.dataset,
                    repaired=repaired,
                )
            )
            written += 1
        if written:
            store.write_meta(flight)
        return written

    def _frame_for(
        self, flight: Flight, when: datetime, tolerance_s: float = 120.0
    ) -> Frame | None:
        """The telemetry frame that best represents the sonde at `when` (R-11)."""
        latest = flight.latest()
        if latest is None:
            return None
        if abs((latest.t - when).total_seconds()) <= tolerance_s:
            return latest
        candidates = [
            f
            for f in flight.recent_frames()
            if abs((f.t - when).total_seconds()) <= tolerance_s
        ]
        if not candidates:
            return None
        return min(candidates, key=lambda f: abs((f.t - when).total_seconds()))

    def schedule_next_sweep(self, flight: Flight, now: datetime) -> None:
        """R-9: 120 s for the first 20 minutes after burst, 300 s thereafter."""
        interval = self.cfg.sweep_interval_s(flight.minutes_since_burst(now))
        flight.next_sweep_at = now + timedelta(seconds=interval)

    # ------------------------------------------------------------- gap repair

    def repair(self, flight: Flight, now: datetime) -> int:
        """R-17: re-issue ticks missed during an outage, marked `repaired`.

        Validity is decided later by the analysis, by comparing each repaired
        line's `dataset` against its live neighbours -- equal epoch means the
        same winds were in play.
        """
        if not self.cfg.repair_enabled or flight.burst_datetime is None:
            return 0
        store = self.store_for(flight)
        written = store.written_tick_times()
        if not written:
            return 0

        expected: list[datetime] = []
        cursor = written[-1]
        while cursor < now:
            since_burst = (cursor - flight.burst_datetime).total_seconds() / 60.0
            interval = self.cfg.sweep_interval_s(since_burst)
            cursor = cursor + timedelta(seconds=interval)
            if cursor < now:
                expected.append(cursor)

        repaired = 0
        for tick in expected:
            if (now - tick).total_seconds() > self.cfg.repair_max_age_s:
                continue  # beyond Tawhiri's reach (§2); unrecoverable
            if self.sweep(flight, tick, repaired=True):
                repaired += 1
        if repaired:
            log.info("%s: repaired %d missed tick(s)", flight.serial, repaired)
        return repaired

    # ------------------------------------------------------------------ close

    def close(self, flight: Flight, now: datetime) -> None:
        """R-3/R-4: close on silence and record the last frame heard."""
        flight.state = State.CLOSED
        flight.closed_at = now
        self.store_for(flight).write_meta(flight)
        log.info(
            "%s: closed, %d frames, last heard %.0f m",
            flight.serial,
            flight.frames_seen,
            flight.last_heard.alt if flight.last_heard else 0.0,
        )

    # ------------------------------------------------------------- main cycle

    def tick(self) -> None:
        """One pass of the loop. R-15: no failure here may terminate the program."""
        now = self._now()

        if self._next_station_poll is None or now >= self._next_station_poll:
            self.discover()
            self._next_station_poll = now + timedelta(seconds=self.cfg.station_poll_interval_s)

        for flight in list(self.flights.values()):
            if flight.state is State.CLOSED:
                continue

            due = self._next_telemetry_poll.get(flight.serial)
            if due is None or now >= due:
                self.poll(flight)
                self._next_telemetry_poll[flight.serial] = now + timedelta(
                    seconds=self.cfg.telemetry_poll_interval_s
                )

            if flight.is_silent(now, self.cfg):
                self.close(flight, now)
                continue

            if flight.is_descending and flight.next_sweep_at is not None:
                if now >= flight.next_sweep_at:
                    self.sweep(flight, now)
                    self.schedule_next_sweep(flight, now)

    def run(self, iterations: int | None = None, sleep_s: float = 1.0) -> None:
        """Run the loop. `iterations` bounds it for testing; None runs forever."""
        import time

        count = 0
        while iterations is None or count < iterations:
            try:
                self.tick()
            except CeilingReached as exc:
                # R-13: log loudly on reaching the ceiling rather than continuing.
                log.error("%s", exc)
                raise
            except Exception:  # noqa: BLE001 - R-15: never die on a transient fault
                log.exception("unhandled error in collector tick; continuing")
            count += 1
            if iterations is None or count < iterations:
                time.sleep(sleep_s)

    # -------------------------------------------------------------- recovery

    def resume(self) -> list[Flight]:
        """R-14: rebuild active flights from disk, then a fresh poll re-establishes state."""
        resumed: list[Flight] = []
        root: Path = self.cfg.data_dir
        if not root.exists():
            return resumed
        import json

        for meta_path in sorted(root.glob("*/meta.json")):
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                log.warning("%s unreadable: %s", meta_path, exc)
                continue
            if not isinstance(meta, dict) or meta.get("state") == State.CLOSED.value:
                continue
            serial = str(meta.get("serial", ""))
            if not serial or serial in self.flights:
                continue
            station = str(meta.get("station", ""))
            kind = meta.get("type")
            flight = self.track(serial, station, str(kind) if isinstance(kind, str) else None)
            resumed.append(flight)
            log.info("%s: resumed from %s", serial, meta_path.parent.name)
        return resumed
