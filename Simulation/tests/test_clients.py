"""API client behaviour.

Covers §4.1 (optional vel_v), §4.2 (response shape), §4.3 (gzip and the 302
trap), §4.4 (dataset epoch, vz_pred) and R-13/R-15 (backoff, retries).
"""

from __future__ import annotations

import gzip
import json
from datetime import UTC, datetime

import pytest

from balloonhunter_sim.httpclient import HttpClient, HttpError, TooManyRequests
from balloonhunter_sim.sondehub import Frame, SondeHub, _frames_from, parse_dt
from balloonhunter_sim.tawhiri import PredictionRejected, Tawhiri


class NullLimiter:
    def acquire(self) -> None: ...

    def penalise(self, seconds: float) -> None: ...


def client(responses: list[object]) -> tuple[HttpClient, list[str]]:
    """An HttpClient whose transport replays `responses` (bytes or exceptions)."""
    urls: list[str] = []
    http = HttpClient("test-agent", NullLimiter(), sleep=lambda _s: None)
    queue = list(responses)

    def fetch(url: str) -> bytes:
        urls.append(url)
        item = queue.pop(0)
        if isinstance(item, Exception):
            raise item
        assert isinstance(item, bytes)
        return item

    http._fetch = fetch  # type: ignore[method-assign]
    return http, urls


# ---------------------------------------------------------------------- §4.3


def test_gzip_body_is_decompressed() -> None:
    """§4.3: responses are gzip-encoded regardless of request headers."""
    body = gzip.compress(json.dumps({"ok": True}).encode())
    http, _ = client([body])
    assert http.get_json("https://example/x") == {"ok": True}


def test_plain_body_still_parses() -> None:
    http, _ = client([json.dumps({"ok": 1}).encode()])
    assert http.get_json("https://example/x") == {"ok": 1}


def test_empty_body_is_retried_then_fails() -> None:
    """§4.3: an unfollowed 302 yields zero bytes with no error -- never silently OK."""
    http, _ = client([b"", b"", b"", b""])
    with pytest.raises(HttpError):
        http.get_json("https://example/x")


# ------------------------------------------------------------------- R-13/15


def test_transient_failure_is_retried(caplog) -> None:
    """R-15: any API failure shall be retried with backoff."""
    good = json.dumps({"ok": 1}).encode()
    http, urls = client([HttpError("u", "500"), good])
    assert http.get_json("https://example/x") == {"ok": 1}
    assert len(urls) == 2


def test_429_backs_off_using_retry_after() -> None:
    """R-13: respect HTTP 429 and Retry-After."""
    slept: list[float] = []
    http = HttpClient("agent", NullLimiter(), sleep=slept.append)
    queue: list[object] = [
        TooManyRequests("u", retry_after=17.0),
        json.dumps({"ok": 1}).encode(),
    ]

    def fetch(url: str) -> bytes:
        item = queue.pop(0)
        if isinstance(item, Exception):
            raise item
        assert isinstance(item, bytes)
        return item

    http._fetch = fetch  # type: ignore[method-assign]
    assert http.get_json("https://example/x") == {"ok": 1}
    assert slept == [17.0]


def test_gives_up_after_max_retries() -> None:
    http = HttpClient("agent", NullLimiter(), max_retries=2, sleep=lambda _s: None)
    http._fetch = lambda url: (_ for _ in ()).throw(HttpError(url, "500"))  # type: ignore[method-assign]
    with pytest.raises(HttpError):
        http.get_json("https://example/x")


def test_query_parameters_are_encoded() -> None:
    http, urls = client([json.dumps({}).encode()])
    http.get_json("https://example/t", {"serial": "W1", "duration": "3h"})
    assert "serial=W1" in urls[0] and "duration=3h" in urls[0]


# ---------------------------------------------------------------------- §4.2


def test_nested_telemetry_shape_is_parsed() -> None:
    """§4.2 returns {serial: {timestamp: frame}}."""
    payload = {
        "W1": {
            "2026-08-20T12:00:00Z": {
                "datetime": "2026-08-20T12:00:00Z",
                "alt": 100.0,
                "lat": 47.0,
                "lon": 8.0,
                "vel_v": -5.0,
            }
        }
    }
    got = _frames_from(payload, "W1")
    assert len(got) == 1 and got[0].alt == 100.0 and got[0].vel_v == -5.0


def test_frames_for_other_serials_are_dropped() -> None:
    """§4.2: merging several serials into one flight is a real hazard."""
    payload = {
        "W1": {"a": {"datetime": "2026-08-20T12:00:00Z", "alt": 1, "lat": 1, "lon": 1}},
        "W2": {"a": {"datetime": "2026-08-20T12:00:01Z", "alt": 2, "lat": 2, "lon": 2}},
    }
    assert [f.alt for f in _frames_from(payload, "W1")] == [1.0]


def test_duplicate_timestamps_collapse() -> None:
    """R-6: deduplicate on datetime -- §4.3 returns 333k frames for ~11k real ones."""
    one = {"datetime": "2026-08-20T12:00:00Z", "alt": 5, "lat": 1, "lon": 1}
    assert len(_frames_from([one, dict(one), dict(one)], "W1")) == 1


def test_frames_are_sorted_by_time() -> None:
    late = {"datetime": "2026-08-20T12:00:09Z", "alt": 9, "lat": 1, "lon": 1}
    early = {"datetime": "2026-08-20T12:00:01Z", "alt": 1, "lat": 1, "lon": 1}
    assert [f.alt for f in _frames_from([late, early], "W1")] == [1.0, 9.0]


# ---------------------------------------------------------------------- §4.1


def test_missing_vel_v_does_not_lose_the_frame() -> None:
    """§4.1: iMet omits vel_v; requiring it hid three live sondes from the app."""
    frame = Frame.from_json(
        {"datetime": "2026-08-20T12:00:00Z", "alt": 1629.0, "lat": 47.0, "lon": 8.0}
    )
    assert frame is not None and frame.vel_v is None


def test_frame_without_position_is_dropped() -> None:
    assert Frame.from_json({"datetime": "2026-08-20T12:00:00Z"}) is None


def test_station_listing_tolerates_missing_optional_fields() -> None:
    payload = {"B84004EE": {"serial": "B84004EE", "type": "iMet-4", "alt": 1629}}
    http, _ = client([json.dumps(payload).encode()])
    entries = SondeHub(http).list_station("06610")
    assert len(entries) == 1
    assert entries[0].type == "iMet-4"
    assert entries[0].frequency is None


def test_timestamps_parse_to_utc() -> None:
    """R-18."""
    assert parse_dt("2026-08-20T12:00:00.000000Z") == datetime(
        2026, 8, 20, 12, 0, tzinfo=UTC
    )


# ---------------------------------------------------------------------- §4.4


def _pt(when: str, altitude: float, lat: float, lon: float) -> dict[str, object]:
    return {"datetime": when, "altitude": altitude, "latitude": lat, "longitude": lon}


def tawhiri_payload() -> dict[str, object]:
    return {
        "request": {"dataset": "2026-08-20T06:00:00Z", "descent_rate": 3.0},
        "prediction": [
            {
                "stage": "ascent",
                "trajectory": [
                    _pt("2026-08-20T13:00:00Z", 22700.0, 47.31, 7.50),
                ],
            },
            {
                "stage": "descent",
                "trajectory": [
                    _pt("2026-08-20T13:00:00Z", 22710.0, 47.31, 7.50),
                    _pt("2026-08-20T13:00:10Z", 22610.0, 47.32, 7.55),
                    _pt("2026-08-20T14:03:00Z", 0.0, 47.1873, 7.7979),
                ],
            },
        ],
    }


def tawhiri_client(payload: object) -> Tawhiri:
    http, _ = client([json.dumps(payload).encode()])
    return Tawhiri(http, ascent_rate=5.0, burst_offset_m=10.0)


def test_prediction_extracts_landing_dataset_and_vz() -> None:
    """§4.4 / R-10: the three things taken from the response."""
    api = tawhiri_client(tawhiri_payload())
    got = api.predict(47.31, 7.5, 22700.0, datetime(2026, 8, 20, 13, tzinfo=UTC), 3.0)
    assert (got.landing_lat, got.landing_lon) == (47.1873, 7.7979)
    assert got.dataset == "2026-08-20T06:00:00Z"
    assert got.vz_pred == pytest.approx(-10.0), "100 m in 10 s"


def test_burst_altitude_is_offset_above_the_sonde() -> None:
    """§4.4: the API requires burst above launch, so the descent starts at the sonde."""
    http, urls = client([json.dumps(tawhiri_payload()).encode()])
    api = Tawhiri(http, ascent_rate=5.0, burst_offset_m=10.0)
    api.predict(47.31, 7.5, 22700.0, datetime(2026, 8, 20, 13, tzinfo=UTC), 3.0)
    assert "launch_altitude=22700.0" in urls[0]
    assert "burst_altitude=22710.0" in urls[0]


def test_launch_datetime_is_sent_as_utc_z() -> None:
    """R-18."""
    http, urls = client([json.dumps(tawhiri_payload()).encode()])
    api = Tawhiri(http, ascent_rate=5.0, burst_offset_m=10.0)
    api.predict(47.31, 7.5, 22700.0, datetime(2026, 8, 20, 13, tzinfo=UTC), 3.0)
    assert "launch_datetime=2026-08-20T13%3A00%3A00Z" in urls[0]


def test_error_payload_raises_prediction_rejected() -> None:
    """§2: `hour=-N` means the tick is outside Tawhiri's one loaded dataset."""
    payload = {
        "error": {
            "type": "PredictionException",
            "description": "Prediction did not complete: 'hour=-3.0'.",
        }
    }
    api = tawhiri_client(payload)
    with pytest.raises(PredictionRejected, match="hour=-3.0"):
        api.predict(47.0, 8.0, 20000.0, datetime(2026, 8, 20, 3, tzinfo=UTC), 3.0)


def test_response_without_stages_is_rejected() -> None:
    api = tawhiri_client({"request": {"dataset": "x"}})
    with pytest.raises(PredictionRejected):
        api.predict(47.0, 8.0, 20000.0, datetime(2026, 8, 20, 13, tzinfo=UTC), 3.0)
