"""Shared fixtures and fakes.

Nothing in the test suite touches the network. SondeHub and Tawhiri are replaced
by fakes implementing the same call signatures.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from balloonhunter_sim.config import Config
from balloonhunter_sim.sondehub import Frame, StationEntry
from balloonhunter_sim.tawhiri import Prediction, PredictionRejected

T0 = datetime(2026, 8, 20, 12, 0, 0, tzinfo=UTC)


def frames(
    alts: list[float],
    start: datetime = T0,
    step_s: float = 1.0,
    vel_v: bool = True,
    lat: float = 47.0,
    lon: float = 8.0,
) -> list[Frame]:
    """Build a frame series from a list of altitudes."""
    out: list[Frame] = []
    for i, alt in enumerate(alts):
        vz: float | None = None
        if vel_v and i > 0:
            vz = (alt - alts[i - 1]) / step_s
        out.append(
            Frame(t=start + timedelta(seconds=i * step_s), alt=alt, lat=lat, lon=lon, vel_v=vz)
        )
    return out


def ramp(start_alt: float, rate: float, count: int, start: datetime = T0) -> list[Frame]:
    """A constant-rate altitude ramp, one frame per second."""
    return frames([start_alt + rate * i for i in range(count)], start=start)


class FakeHub:
    """Stands in for SondeHub."""

    def __init__(self) -> None:
        self.stations: dict[str, list[StationEntry]] = {}
        self.frames: dict[str, list[Frame]] = {}
        self.telemetry_calls: list[tuple[str, str]] = []
        self.fail_telemetry: Exception | None = None

    def list_station(self, station_id: str) -> list[StationEntry]:
        return self.stations.get(station_id, [])

    def telemetry(self, serial: str, duration: str) -> list[Frame]:
        self.telemetry_calls.append((serial, duration))
        if self.fail_telemetry is not None:
            raise self.fail_telemetry
        return self.frames.get(serial, [])


class FakeTawhiri:
    """Stands in for Tawhiri. Landing point drifts with the requested rate."""

    def __init__(self, dataset: str | None = "2026-08-20T06:00:00Z") -> None:
        self.calls: list[dict[str, object]] = []
        self.dataset = dataset
        self.reject_rates: set[float] = set()
        self.fail: Exception | None = None

    def predict(
        self, lat: float, lon: float, alt: float, when: datetime, descent_rate: float
    ) -> Prediction:
        self.calls.append(
            {"lat": lat, "lon": lon, "alt": alt, "when": when, "rate": descent_rate}
        )
        if self.fail is not None:
            raise self.fail
        if descent_rate in self.reject_rates:
            raise PredictionRejected(f"rejected rate {descent_rate}")
        # A slower rate stays aloft longer and lands further downwind.
        return Prediction(
            landing_lat=lat + 0.1,
            landing_lon=lon + (10.0 / descent_rate) * 0.05,
            dataset=self.dataset,
            vz_pred=-descent_rate,
        )


class Clock:
    """Controllable UTC clock."""

    def __init__(self, now: datetime = T0) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now

    def advance(self, seconds: float) -> datetime:
        self.now = self.now + timedelta(seconds=seconds)
        return self.now


@pytest.fixture
def cfg(tmp_path) -> Config:
    return Config(data_dir=tmp_path / "data", stations=("06610",))


@pytest.fixture
def hub() -> FakeHub:
    return FakeHub()


@pytest.fixture
def tawhiri() -> FakeTawhiri:
    return FakeTawhiri()


@pytest.fixture
def clock() -> Clock:
    return Clock()
