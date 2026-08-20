"""Configuration for the radiosonde descent collector.

Every value the FSD marks "configurable" lives here. Defaults are the FSD
defaults; see docs/SondeCollectorFSD.md for the reasoning behind each.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

# §3 open item 1: the station list is not yet decided. Payerne is the operator's
# hunting ground and the only station the FSD commits to. Neighbouring stations
# are expected to be added by WMO id via the config file — they are deliberately
# not guessed here.
DEFAULT_STATIONS: tuple[str, ...] = ("06610",)

# R-9. Must span the whole observed range, because both ends were broken on
# 2026-08-20: X1422041 ran off the top (implied rate past 12 m/s below 4.5 km)
# and X2823364 sat below 2.0 m/s for its entire 93-minute descent, so its rate
# was unmeasurable with the original 2.0-7.0 set. Normal flights sit near 5
# (W4214540: 5.03); fast chutes reach 9-12; a partial burst or oversized chute
# goes under 2.
DEFAULT_SWEEP: tuple[float, ...] = (1.0, 2.0, 3.0, 4.0, 5.0, 7.0, 10.0, 12.0, 15.0)

#: §4.2 accepts only an enumerated set of durations. Anything else is answered
#: with HTTP 200 and a plain-text complaint, which is easy to miss.
DURATION_SECONDS: dict[str, float] = {
    "0": 0.0,
    "15s": 15.0,
    "1m": 60.0,
    "30m": 1800.0,
    "1h": 3600.0,
    "3h": 10800.0,
    "6h": 21600.0,
    "12h": 43200.0,
    "1d": 86400.0,
    "3d": 259200.0,
}
ALLOWED_DURATIONS: frozenset[str] = frozenset(DURATION_SECONDS)

#: The steady-state window must cover the poll interval (so consecutive polls
#: overlap and no frame is missed) without dwarfing it. A window far larger than
#: the interval re-downloads the whole flight every poll: 3h against a 30 s
#: interval is 1.56 MB each time, for ~60 new frames.
MIN_WINDOW_RATIO = 1.0
MAX_WINDOW_RATIO = 20.0


@dataclass(frozen=True)
class Config:
    """Collector configuration."""

    data_dir: Path = Path("data")
    stations: tuple[str, ...] = DEFAULT_STATIONS

    # --- R-1 / R-6: polling ---
    station_poll_interval_s: float = 60.0
    telemetry_poll_interval_s: float = 30.0
    #: Steady-state `duration` for the windowed telemetry endpoint (§4.2): the
    #: shortest value that still overlaps consecutive polls, so nothing is missed.
    #: Measured on a live flight: 1m = 57 kB, 30m = 1.5 MB, 3h = 1.56 MB. Polling
    #: a long window every 30 s pulls the whole flight repeatedly to learn about
    #: ~60 new frames, which is the anti-pattern R-13 exists to prevent.
    telemetry_window: str = "1m"
    #: First poll of a flight (and after a restart) needs the flight's history,
    #: not just the last minute: the running maximum altitude is what burst
    #: detection compares against, and launch detection needs the ground level.
    telemetry_window_initial: str = "3h"

    # --- R-3: lifecycle ---
    silence_timeout_s: float = 30.0 * 60.0

    # --- R-8: burst detection ---
    burst_drop_m: float = 300.0
    burst_consecutive_frames: int = 3
    burst_vel_v_corroboration: float = -3.0
    #: Launch is not first sighting: W4214540 reported from the ground for 15 h
    #: before it flew. Require sustained ascent above the ground.
    launch_rise_m: float = 500.0
    launch_consecutive_frames: int = 3

    # --- R-9: prediction sweep ---
    sweep_rates: tuple[float, ...] = DEFAULT_SWEEP
    dense_phase_s: float = 20.0 * 60.0
    dense_interval_s: float = 120.0
    sparse_interval_s: float = 300.0
    #: Tawhiri requires an ascent rate even for a descent-only prediction.
    ascent_rate: float = 5.0
    #: §4.4: burst must sit above launch, so the descent starts at the sonde.
    burst_offset_m: float = 10.0

    # --- R-10: vz_real smoothing ---
    #: Fallback window when the current rate is not yet known.
    vz_window_s: float = 30.0
    #: Effective GPS vertical uncertainty over an averaging window, in metres.
    #: Measured on W4214540: rate jitter follows ``scale / window_seconds`` with
    #: scale = 4.8 m (0.482 m/s at 10 s, 0.162 at 30 s, 0.077 at 60 s, 0.044 at
    #: 120 s; fitted exponent -0.96). Note it is 1/T, not the 1/T**1.5 that
    #: independent noise would give -- GPS vertical error is time-correlated, so
    #: a longer window buys less than theory suggests.
    vz_gps_jitter_scale_m: float = 4.8
    #: Target precision as a fraction of the rate being measured. The window is
    #: then jitter_scale / (precision * rate), which is short where the sonde
    #: falls fast and its profile changes quickly, and long near the ground where
    #: it falls slowly through an almost constant profile. 0.5 m/s of jitter is
    #: 1.6% of 30 m/s but 10% of 5 m/s, so a constant *relative* target is what
    #: keeps every altitude equally well measured.
    vz_target_relative_precision: float = 0.02
    vz_window_min_s: float = 10.0
    vz_window_max_s: float = 120.0

    # --- R-19: receiving-station quality ---
    #: The sonde transmits one set of values; every station receives exactly the
    #: same numbers and can only corrupt them. A station whose altitudes sit
    #: systematically off the consensus trajectory is decoding or reporting them
    #: wrongly and must be excluded. Measured on W3821271: eight stations agreed
    #: to within +/-0.2 m while DB0NH read 9.45 m low across 50 frames.
    station_bias_max_m: float = 5.0
    #: Scatter, as opposed to offset, disqualifies a station too.
    station_scatter_max_m: float = 8.0
    #: Below this many frames in the window, a station is neither judged nor used
    #: as evidence against itself.
    station_min_frames: int = 4

    # --- R-13: being a good citizen ---
    user_agent: str = (
        "BalloonHunter-SondeCollector/0.1 (+https://github.com/SensorsIot/BalloonHunter)"
    )
    min_request_spacing_s: float = 1.0
    daily_request_ceiling: int = 5000
    #: The ceiling is counted in this file, shared by every process on the host.
    #: An in-memory counter gives each process its own budget, so several
    #: concurrent runs silently issue several times the ceiling.
    request_counter_path: Path = Path.home() / ".cache" / "sonde-collector" / "requests.json"
    request_timeout_s: float = 40.0
    max_retries: int = 4

    # --- R-17: gap repair ---
    repair_enabled: bool = True
    #: Tawhiri holds one dataset and rejects launch_datetime earlier than its
    #: epoch minus one 3 h grid step (§2). 8 h is the practical outer limit; the
    #: API is the real authority and a too-old repair simply fails.
    repair_max_age_s: float = 8.0 * 3600.0

    extra: dict[str, object] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for name in ("telemetry_window", "telemetry_window_initial"):
            value = getattr(self, name)
            if value not in ALLOWED_DURATIONS:
                raise ValueError(
                    f"{name}={value!r} is not a SondeHub duration; "
                    f"allowed: {', '.join(sorted(ALLOWED_DURATIONS))}"
                )
        window = DURATION_SECONDS[self.telemetry_window]
        interval = self.telemetry_poll_interval_s
        if interval > 0 and not MIN_WINDOW_RATIO <= window / interval <= MAX_WINDOW_RATIO:
            raise ValueError(
                f"telemetry_window={self.telemetry_window} ({window:.0f}s) is not "
                f"proportionate to telemetry_poll_interval_s={interval:.0f}: the ratio "
                f"must be between {MIN_WINDOW_RATIO:g} and {MAX_WINDOW_RATIO:g}. "
                "Too small drops frames between polls; too large re-downloads the "
                "whole flight every poll (R-13)."
            )

    @classmethod
    def load(cls, path: Path | None) -> Config:
        """Load configuration, overriding defaults with a JSON file if given."""
        cfg = cls()
        if path is None:
            return cfg
        raw = json.loads(path.read_text())
        if not isinstance(raw, dict):
            raise ValueError(f"{path}: expected a JSON object")
        # Any, not object: the values are validated against the field they
        # replace just below, and dataclasses.replace is typed per-field.
        updates: dict[str, Any] = {}
        for key, value in raw.items():
            if not hasattr(cfg, key):
                raise ValueError(f"{path}: unknown setting {key!r}")
            current = getattr(cfg, key)
            if isinstance(current, Path):
                updates[key] = Path(str(value))
            elif isinstance(current, tuple):
                if not isinstance(value, list):
                    raise ValueError(f"{path}: {key!r} must be a list")
                updates[key] = tuple(value)
            else:
                updates[key] = value
        return replace(cfg, **updates)

    def sweep_interval_s(self, minutes_since_burst: float) -> float:
        """R-9: dense cadence where the answer lives, sparse through the tail."""
        if minutes_since_burst * 60.0 <= self.dense_phase_s:
            return self.dense_interval_s
        return self.sparse_interval_s
