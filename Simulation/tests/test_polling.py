"""Which window each poll actually asks for, and what a 200-with-text means.

Both of these were found by making one real call against the live API after the
unit suite was already green. The suite replayed JSON written by hand, so it
agreed with itself.
"""

from __future__ import annotations

import json

import pytest

from balloonhunter_sim.collector import Collector
from balloonhunter_sim.config import Config
from balloonhunter_sim.httpclient import HttpClient, HttpError, PermanentError

from .conftest import ramp


class NullLimiter:
    def acquire(self) -> None: ...

    def penalise(self, seconds: float) -> None: ...


# ------------------------------------------------------------- poll windows


def test_first_poll_replays_history_then_polls_short(cfg, hub, tawhiri, clock) -> None:
    """R-6: bootstrap needs the running maximum; steady state does not."""
    hub.frames["W1"] = ramp(500.0, 30.0, 60)
    collector = Collector(cfg, hub, tawhiri, clock)
    flight = collector.track("W1", "06610")

    collector.poll(flight)
    collector.poll(flight)
    collector.poll(flight)

    windows = [window for _serial, window in hub.telemetry_calls]
    assert windows == [
        cfg.telemetry_window_initial,
        cfg.telemetry_window,
        cfg.telemetry_window,
    ]


def test_each_flight_bootstraps_independently(cfg, hub, tawhiri, clock) -> None:
    hub.frames["W1"] = ramp(500.0, 30.0, 20)
    hub.frames["W2"] = ramp(500.0, 30.0, 20)
    collector = Collector(cfg, hub, tawhiri, clock)
    first = collector.track("W1", "06610")
    second = collector.track("W2", "06610")
    collector.poll(first)
    collector.poll(first)
    collector.poll(second)
    assert [w for _s, w in hub.telemetry_calls] == ["3h", "1m", "3h"]


def test_failed_bootstrap_is_retried_as_a_bootstrap(cfg, hub, tawhiri, clock) -> None:
    """A flight whose first poll failed still has no history to compare against."""
    collector = Collector(cfg, hub, tawhiri, clock)
    flight = collector.track("W1", "06610")
    hub.fail_telemetry = HttpError("u", "boom")
    collector.poll(flight)
    assert flight.bootstrapped is False

    hub.fail_telemetry = None
    hub.frames["W1"] = ramp(500.0, 30.0, 20)
    collector.poll(flight)
    assert [w for _s, w in hub.telemetry_calls] == ["3h", "3h"]


def test_steady_state_poll_stays_small(cfg) -> None:
    """Measured live: 1m = 57 kB, 3h = 1.56 MB. At 30 s polling that is 27x."""
    assert cfg.telemetry_window == "1m"


# ---------------------------------------------------- 200 with a text body


def client(bodies: list[bytes]) -> tuple[HttpClient, list[str]]:
    urls: list[str] = []
    http = HttpClient("agent", NullLimiter(), sleep=lambda _s: None)
    queue = list(bodies)

    def fetch(url: str) -> bytes:
        urls.append(url)
        return queue.pop(0)

    http._fetch = fetch  # type: ignore[method-assign]
    return http, urls


def test_plain_text_error_is_not_retried() -> None:
    """§4.2 answers a bad duration with HTTP 200 and prose. Retrying is impolite."""
    body = b"Duration must be either 3d, 1d, 12h, 6h, 3h, 1h, 30m, 1m, 15s, 0"
    http, urls = client([body])
    with pytest.raises(PermanentError, match="Duration must be either"):
        http.get_json("https://example/t")
    assert len(urls) == 1, "a permanent rejection must cost exactly one request"


def test_permanent_error_surfaces_the_servers_own_words() -> None:
    http, _ = client([b"Serial not found"])
    with pytest.raises(PermanentError, match="Serial not found"):
        http.get_json("https://example/t")


def test_empty_body_is_still_retried() -> None:
    """An empty body may be truncation rather than refusal, so it keeps its retries."""
    good = json.dumps({"ok": 1}).encode()
    http, urls = client([b"", b"", good])
    assert http.get_json("https://example/x") == {"ok": 1}
    assert len(urls) == 3


def test_valid_json_still_parses_after_the_change() -> None:
    http, _ = client([json.dumps({"W1": {}}).encode()])
    assert http.get_json("https://example/x") == {"W1": {}}


def test_collector_survives_a_permanent_telemetry_error(cfg, hub, tawhiri, clock) -> None:
    """R-15: it is logged and the flight is kept, not abandoned."""
    collector = Collector(cfg, hub, tawhiri, clock)
    flight = collector.track("W1", "06610")
    hub.fail_telemetry = PermanentError("u", "non-JSON response: Duration must be either")
    assert collector.poll(flight) is False
    assert collector.flights["W1"] is flight


def test_default_config_would_have_caught_the_shipped_defect() -> None:
    """The window/interval pair the collector actually ran with must now be illegal."""
    with pytest.raises(ValueError):
        Config(telemetry_window="3h", telemetry_poll_interval_s=30.0)
