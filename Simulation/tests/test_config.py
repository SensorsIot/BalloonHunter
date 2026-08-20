"""Configuration guards.

These exist because the implementation shipped `telemetry_window="3h"` against a
30 s poll interval: 1.56 MB re-downloaded every 30 seconds to learn about ~60 new
frames. That is the anti-pattern R-13 exists to prevent, and nothing caught it,
because no test related the window to the interval.

Also covers §4.2's enumerated duration set, which SondeHub rejects with HTTP 200
and a plain-text body rather than an error status.
"""

from __future__ import annotations

import json
from dataclasses import replace

import pytest

from balloonhunter_sim.config import (
    ALLOWED_DURATIONS,
    DURATION_SECONDS,
    MAX_WINDOW_RATIO,
    Config,
)

# ------------------------------------------------------- window proportionality


def test_default_window_is_proportionate_to_the_poll_interval() -> None:
    """The regression guard: window must cover the interval without dwarfing it."""
    cfg = Config()
    ratio = DURATION_SECONDS[cfg.telemetry_window] / cfg.telemetry_poll_interval_s
    assert 1.0 <= ratio <= MAX_WINDOW_RATIO
    assert ratio >= 1.0, "a window shorter than the interval drops frames between polls"


def test_window_far_larger_than_the_interval_is_rejected() -> None:
    """The exact defect: 3h against a 30 s poll is a 360x ratio."""
    with pytest.raises(ValueError, match="proportionate"):
        Config(telemetry_window="3h", telemetry_poll_interval_s=30.0)


def test_window_shorter_than_the_interval_is_rejected() -> None:
    with pytest.raises(ValueError, match="proportionate"):
        Config(telemetry_window="15s", telemetry_poll_interval_s=60.0)


def test_a_slower_poll_may_use_a_longer_window() -> None:
    """The rule is a ratio, not a fixed pair."""
    cfg = Config(telemetry_window="30m", telemetry_poll_interval_s=300.0)
    assert cfg.telemetry_window == "30m"


def test_initial_window_is_exempt_and_long() -> None:
    """Bootstrap needs the flight's history: the running max drives burst detection."""
    cfg = Config()
    initial = DURATION_SECONDS[cfg.telemetry_window_initial]
    assert initial > DURATION_SECONDS[cfg.telemetry_window] * MAX_WINDOW_RATIO


# ------------------------------------------------------------- duration values


def test_only_sondehub_durations_are_accepted() -> None:
    """§4.2: '10m' is answered with 200 and 'Duration must be either ...'."""
    with pytest.raises(ValueError, match="not a SondeHub duration"):
        Config(telemetry_window="10m")


def test_allowed_durations_match_the_documented_set() -> None:
    assert ALLOWED_DURATIONS == {
        "3d",
        "1d",
        "12h",
        "6h",
        "3h",
        "1h",
        "30m",
        "1m",
        "15s",
        "0",
    }


def test_initial_window_is_also_validated() -> None:
    with pytest.raises(ValueError, match="telemetry_window_initial"):
        Config(telemetry_window_initial="10m")


# --------------------------------------------------------------- file loading


def test_config_file_overrides_defaults(tmp_path) -> None:
    path = tmp_path / "c.json"
    path.write_text(json.dumps({"stations": ["06610", "10739"], "sweep_rates": [3, 5]}))
    cfg = Config.load(path)
    assert cfg.stations == ("06610", "10739")
    assert cfg.sweep_rates == (3, 5)


def test_config_file_rejects_unknown_settings(tmp_path) -> None:
    path = tmp_path / "c.json"
    path.write_text(json.dumps({"nonsense": 1}))
    with pytest.raises(ValueError, match="unknown setting"):
        Config.load(path)


def test_config_file_is_validated_too(tmp_path) -> None:
    """A bad window in a file must fail at startup, not at 3 a.m. mid-descent."""
    path = tmp_path / "c.json"
    path.write_text(json.dumps({"telemetry_window": "3h"}))
    with pytest.raises(ValueError):
        Config.load(path)


def test_no_config_file_yields_defaults() -> None:
    assert Config.load(None) == Config()


def test_replace_revalidates() -> None:
    with pytest.raises(ValueError):
        replace(Config(), telemetry_window="12h")
