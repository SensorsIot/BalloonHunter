"""Flight lifecycle and burst detection (§5.1, §5.2).

Telemetry lives here, in memory only (R-7). A bounded window of recent frames is
retained for `vz_real` and for the consecutive-frame tests; the running extremes
needed for launch and burst detection are maintained incrementally, so memory does
not grow with flight length.
"""

from __future__ import annotations

import logging
import statistics
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import Enum

from .config import Config
from .sondehub import Frame

log = logging.getLogger(__name__)

#: §6.3 / §8: an interval longer than this is a sampling gap, and must stay
#: visible in the output rather than being smoothed away.
GAP_THRESHOLD_S = 60.0

#: Enough history for the vz_real window and the consecutive-frame tests.
_WINDOW_FRAMES = 600

#: A radiosonde transmits one packet per second, so no genuine interval is
#: shorter than this. Anything that looks shorter has a corrupted timestamp:
#: uploaders disagree on precision, one stamping `...08.997000Z` and the next
#: `...09.000Z`, which records a real 1 s interval as 3 ms. The frames are
#: distinct and their altitudes are sound -- a 10 m step at 13 m/s is 0.77 s of
#: real flight -- but the interval is unusable, and dividing by it yields
#: thousands of m/s. Discard the interval, keep the frames.
MIN_INTERVAL_S = 0.5


class State(Enum):
    PRELAUNCH = "prelaunch"
    ASCENT = "ascent"
    DESCENT = "descent"
    CLOSED = "closed"


@dataclass
class Flight:
    """One sonde's flight. R-5: many of these are active simultaneously."""

    serial: str
    station: str
    type: str | None = None

    state: State = State.PRELAUNCH
    launch_datetime: datetime | None = None
    burst_datetime: datetime | None = None
    burst_altitude: float | None = None
    burst_lat: float | None = None
    burst_lon: float | None = None
    closed_at: datetime | None = None

    frames_seen: int = 0
    gaps: int = 0
    max_gap_s: float = 0.0

    #: R-4. The last frame received -- NOT a landing position. Radiosondes drop
    #: below the receivers' horizon while still descending, essentially always.
    last_heard: Frame | None = None

    next_sweep_at: datetime | None = None

    #: False until the first poll has replayed the flight's history. Steady-state
    #: polls use a short window; the first one cannot.
    bootstrapped: bool = False

    #: Receiving stations found to disagree with the consensus trajectory (R-19).
    #: Recorded in meta.json so an exclusion is never silent (§8).
    excluded_stations: set[str | None] = field(default_factory=set)

    def __post_init__(self) -> None:
        self._recent: deque[Frame] = deque(maxlen=_WINDOW_FRAMES)
        self._seen_times: set[datetime] = set()
        self._max_alt: float | None = None
        self._min_alt: float | None = None
        self._rising = 0
        self._falling = 0

    # ------------------------------------------------------------------ ingest

    def ingest(self, frames: list[Frame], cfg: Config) -> bool:
        """Add newly seen frames. Returns True if burst was detected in this batch."""
        burst_now = False
        for frame in frames:
            if frame.t in self._seen_times:
                continue  # R-6: deduplicate on datetime
            if self.last_heard is not None and frame.t < self.last_heard.t:
                continue  # out-of-order straggler, already accounted for
            self._seen_times.add(frame.t)
            if self._observe(frame, cfg):
                burst_now = True
        # Bound the dedup set alongside the frame window.
        if len(self._seen_times) > _WINDOW_FRAMES * 4:
            keep = {f.t for f in self._recent}
            self._seen_times = keep
        return burst_now

    def _observe(self, frame: Frame, cfg: Config) -> bool:
        previous = self._recent[-1] if self._recent else None
        if previous is not None:
            delta = (frame.t - previous.t).total_seconds()
            if delta > GAP_THRESHOLD_S:
                self.gaps += 1
                self.max_gap_s = max(self.max_gap_s, delta)
            # Defensive only. A mis-stamped interval says nothing about whether
            # the sonde rose or fell, but in practice both frames are real and
            # follow the trend: on W3821271's descent all 118 such pairs stepped
            # downward, the counter was never reset, and burst was detected 41 s
            # after the peak -- exactly the 300 m threshold at 7.3 m/s. The damage
            # these intervals do is to vertical speed, not to detection.
            if delta >= MIN_INTERVAL_S:
                if frame.alt > previous.alt:
                    self._rising += 1
                    self._falling = 0
                elif frame.alt < previous.alt:
                    self._falling += 1
                    self._rising = 0

        self._recent.append(frame)
        self.frames_seen += 1
        self.last_heard = frame
        self._max_alt = frame.alt if self._max_alt is None else max(self._max_alt, frame.alt)
        self._min_alt = frame.alt if self._min_alt is None else min(self._min_alt, frame.alt)

        if self.state is State.PRELAUNCH and self._is_launch(frame, cfg):
            self.state = State.ASCENT
            self.launch_datetime = frame.t
            log.info("%s: launch detected at %.0f m", self.serial, frame.alt)
        elif self.state is State.ASCENT and self._is_burst(frame, cfg):
            self.state = State.DESCENT
            self.burst_datetime = frame.t
            self.burst_altitude = self._max_alt
            self.burst_lat, self.burst_lon = frame.lat, frame.lon
            self.next_sweep_at = frame.t
            log.info("%s: BURST at %.0f m (%s)", self.serial, self._max_alt or 0.0, frame.t)
            return True
        return False

    def _is_launch(self, frame: Frame, cfg: Config) -> bool:
        """Launch is sustained ascent, not first sighting.

        W4214540 reported from the ground at 561 m for 15 hours before it flew.
        """
        if self._min_alt is None:
            return False
        return (
            frame.alt - self._min_alt >= cfg.launch_rise_m
            and self._rising >= cfg.launch_consecutive_frames
        )

    def _is_burst(self, frame: Frame, cfg: Config) -> bool:
        """R-8. Hysteresis is required: frames are 1-2 s apart and noisy near apogee."""
        if self._max_alt is None:
            return False
        if self._max_alt - frame.alt < cfg.burst_drop_m:
            return False
        if self._falling < cfg.burst_consecutive_frames:
            return False
        # Where vel_v exists it may corroborate; where it does not (iMet) the
        # altitude condition alone governs.
        if frame.vel_v is not None and frame.vel_v > cfg.burst_vel_v_corroboration:
            return False
        return True

    # ----------------------------------------------------------------- queries

    def vz_window_s(self, cfg: Config, at: datetime | None = None) -> float:
        """Averaging window sized from measured GPS jitter and a precision target.

        Rate jitter follows ``scale / window_seconds`` (measured: scale = 4.8 m),
        so reaching a relative precision ``p`` on a rate ``v`` needs a window of
        ``scale / (p * v)``. That is short just after burst, where the sonde falls
        at ~30 m/s and its profile changes quickly, and long near the ground where
        it falls at ~5 m/s through an almost constant profile.

        A coarse rate from the last few seconds picks the window; the resulting
        window then produces the reported rate. The estimate need only be good to
        a factor of two, which a handful of frames easily achieves.
        """
        if len(self._recent) < 2:
            return cfg.vz_window_s
        end = at or self._recent[-1].t
        probe = [f for f in self._recent if end - timedelta(seconds=10.0) <= f.t <= end]
        if len(probe) < 2:
            return cfg.vz_window_s
        span_s = (probe[-1].t - probe[0].t).total_seconds()
        if span_s <= 0:
            return cfg.vz_window_s
        rate = abs(probe[-1].alt - probe[0].alt) / span_s
        if rate <= 0.1:
            return cfg.vz_window_max_s
        needed = cfg.vz_gps_jitter_scale_m / (cfg.vz_target_relative_precision * rate)
        return max(cfg.vz_window_min_s, min(cfg.vz_window_max_s, needed))

    def vz_altitude(self, cfg: Config, at: datetime | None = None) -> float | None:
        """The altitude `vz_real` actually describes.

        vz_real averages a trailing window, so it describes the sonde at the
        window's midpoint, not at the tick. At 16 m/s a 30 s window puts that
        240 m below the recorded altitude -- and §6.3 is explicit that a descent
        rate without the altitude it applies to is meaningless.
        """
        if len(self._recent) < 2:
            return None
        end = at or self._recent[-1].t
        span = self.vz_window_s(cfg, at=end)
        window = [f for f in self._recent if end - timedelta(seconds=span) <= f.t <= end]
        if len(window) < 2:
            return None
        midpoint = window[0].t + (window[-1].t - window[0].t) / 2
        nearest = min(window, key=lambda f: abs((f.t - midpoint).total_seconds()))
        return nearest.alt

    def vz_real(self, cfg: Config, at: datetime | None = None) -> float | None:
        """Observed descent rate, median over the trailing window (R-10).

        Rates are computed **within each uploader's own stream**, never across
        two of them. Dozens of receiving stations report one flight, each with
        its own clock and timestamp precision; interleaving them manufactures
        intervals that never happened. Measured on W3821271: every individual
        uploader had 0.0% bad intervals, while the merged stream had 5.0%.

        Returns None rather than a stale value when no telemetry backs the tick
        -- §8 requires sampling gaps to stay visible.
        """
        if len(self._recent) < 2:
            return None
        end = at or self._recent[-1].t
        span = self.vz_window_s(cfg, at=end)
        window = [f for f in self._recent if end - timedelta(seconds=span) <= f.t <= end]
        if len(window) < 2:
            return None

        streams: dict[str | None, list[Frame]] = {}
        for frame in window:  # already time-ordered
            streams.setdefault(frame.uploader, []).append(frame)

        for bad in self._bad_stations(window, streams, cfg):
            self.excluded_stations.add(bad)
            streams.pop(bad, None)
        if not streams:
            return None

        rates: list[float] = []
        for stream in streams.values():
            for previous, current in zip(stream, stream[1:], strict=False):
                dt = (current.t - previous.t).total_seconds()
                # MIN_INTERVAL_S remains a backstop: one uploader can still
                # emit a duplicate of its own frame.
                if MIN_INTERVAL_S <= dt <= GAP_THRESHOLD_S:
                    rates.append((current.alt - previous.alt) / dt)
        if not rates:
            return None
        # Median, not mean: the 0.62 m/s per-frame noise floor makes single
        # intervals unusable raw.
        return statistics.median(rates)

    @staticmethod
    def _robust_line(window: list[Frame]) -> tuple[float, float] | None:
        """Median-of-slopes line through the window: slope m, intercept c.

        Median-based so a minority of misreporting stations cannot drag the
        reference they are being judged against.
        """
        t0 = window[0].t
        xs = [(f.t - t0).total_seconds() for f in window]
        slopes = [
            (window[j].alt - window[i].alt) / (xs[j] - xs[i])
            for i in range(len(window))
            for j in range(i + 1, len(window))
            if xs[j] - xs[i] >= 5.0
        ]
        if not slopes:
            return None
        m = statistics.median(slopes)
        c = statistics.median([f.alt - m * x for f, x in zip(window, xs, strict=False)])
        return m, c

    def _bad_stations(
        self,
        window: list[Frame],
        streams: dict[str | None, list[Frame]],
        cfg: Config,
    ) -> list[str | None]:
        """Stations whose altitudes disagree with the consensus trajectory (R-19).

        The sonde transmits one set of numbers; every station receives exactly
        those. A station that reports something else is corrupting them, so it is
        excluded rather than averaged in.
        """
        if len(streams) < 2:
            return []  # nothing to compare against
        line = self._robust_line(window)
        if line is None:
            return []
        m, c = line
        t0 = window[0].t
        bad: list[str | None] = []
        for name, stream in streams.items():
            if len(stream) < cfg.station_min_frames:
                continue
            res = [f.alt - (m * (f.t - t0).total_seconds() + c) for f in stream]
            offset = abs(statistics.median(res))
            scatter = statistics.pstdev(res) if len(res) > 1 else 0.0
            if offset > cfg.station_bias_max_m or scatter > cfg.station_scatter_max_m:
                log.warning(
                    "%s: excluding station %s (offset %+.1f m, scatter %.1f m)",
                    self.serial,
                    name,
                    statistics.median(res),
                    scatter,
                )
                bad.append(name)
        # Never exclude everyone: if the consensus itself is unusable, keep all.
        return bad if len(bad) < len(streams) else []

    def latest(self) -> Frame | None:
        return self._recent[-1] if self._recent else None

    def recent_frames(self) -> list[Frame]:
        """The retained window, oldest first. Used to place a repaired tick (R-17)."""
        return list(self._recent)

    def minutes_since_burst(self, now: datetime) -> float:
        if self.burst_datetime is None:
            return 0.0
        return (now - self.burst_datetime).total_seconds() / 60.0

    def is_silent(self, now: datetime, cfg: Config) -> bool:
        """R-3: closed on silence. The old 'below 1000 m and static' rule never fired."""
        if self.last_heard is None:
            return False
        return (now - self.last_heard.t).total_seconds() > cfg.silence_timeout_s

    @property
    def is_descending(self) -> bool:
        return self.state is State.DESCENT
