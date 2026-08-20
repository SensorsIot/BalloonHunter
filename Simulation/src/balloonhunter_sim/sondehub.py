"""SondeHub client: station listing (§4.1) and live windowed telemetry (§4.2)."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol

from .httpclient import HttpClient

log = logging.getLogger(__name__)

BASE = "https://api.v2.sondehub.org"


def parse_dt(raw: str) -> datetime:
    """Parse a SondeHub ISO 8601 timestamp as UTC (R-18)."""
    dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC)


def _f(obj: object) -> float | None:
    if isinstance(obj, bool) or obj is None:
        return None
    if isinstance(obj, (int, float)):
        return float(obj)
    if isinstance(obj, str):
        try:
            return float(obj)
        except ValueError:
            return None
    return None


@dataclass(frozen=True)
class Frame:
    """One telemetry frame. Held in memory only -- never written (R-7)."""

    t: datetime
    alt: float
    lat: float
    lon: float
    #: §4.1: optional. iMet sondes omit it entirely; a decoder that requires it
    #: fails to parse the whole response.
    vel_v: float | None = None
    #: Which receiving station uploaded this frame. Dozens contribute to one
    #: flight, each with its own clock and timestamp precision, so an interval
    #: is only meaningful between two frames from the *same* uploader.
    uploader: str | None = None

    @classmethod
    def from_json(cls, obj: object) -> Frame | None:
        if not isinstance(obj, dict):
            return None
        raw_t = obj.get("datetime")
        alt, lat, lon = _f(obj.get("alt")), _f(obj.get("lat")), _f(obj.get("lon"))
        if not isinstance(raw_t, str) or alt is None or lat is None or lon is None:
            return None
        try:
            t = parse_dt(raw_t)
        except ValueError:
            return None
        uploader = obj.get("uploader_callsign")
        return cls(
            t=t,
            alt=alt,
            lat=lat,
            lon=lon,
            vel_v=_f(obj.get("vel_v")),
            uploader=str(uploader) if isinstance(uploader, str) else None,
        )


@dataclass(frozen=True)
class StationEntry:
    """A sonde as it appears in the station listing. The only source of `type`."""

    serial: str
    station: str
    type: str | None
    frequency: float | None
    last_seen: datetime | None


class TelemetrySource(Protocol):
    """What the collector needs from a source of flights.

    Satisfied by `SondeHub` against the live API and by `ReplayHub` against a
    shifted recording, so the collector is identical in both cases.
    """

    def list_station(self, station_id: str) -> list[StationEntry]: ...

    def telemetry(self, serial: str, duration: str) -> list[Frame]: ...


class SondeHub:
    def __init__(self, http: HttpClient) -> None:
        self._http = http

    def list_station(self, station_id: str) -> list[StationEntry]:
        """§4.1. Tolerates missing vel_v/vel_h -- they are optional fields."""
        payload = self._http.get_json(f"{BASE}/sondes/site/{station_id}")
        if not isinstance(payload, dict):
            log.warning("station %s: unexpected payload %s", station_id, type(payload))
            return []
        entries: list[StationEntry] = []
        for serial, value in payload.items():
            if not isinstance(value, dict):
                continue
            raw_t = value.get("datetime")
            last_seen: datetime | None = None
            if isinstance(raw_t, str):
                try:
                    last_seen = parse_dt(raw_t)
                except ValueError:
                    last_seen = None
            kind = value.get("type")
            entries.append(
                StationEntry(
                    serial=str(serial),
                    station=station_id,
                    type=str(kind) if isinstance(kind, str) else None,
                    frequency=_f(value.get("frequency")),
                    last_seen=last_seen,
                )
            )
        return entries

    def telemetry(self, serial: str, duration: str) -> list[Frame]:
        """§4.2 windowed poll. Returns frames sorted by time, deduplicated (R-6)."""
        payload = self._http.get_json(
            f"{BASE}/sondes/telemetry", {"serial": serial, "duration": duration}
        )
        return _frames_from(payload, serial)


def _frames_from(payload: object, serial: str) -> list[Frame]:
    """Extract frames from either response shape.

    §4.2 returns ``{serial: {timestamp: frame}}``. §4.3 returns a bare list. The
    outer key is the **serial**; merging several serials into one flight is a real
    hazard, so anything not keyed to `serial` is dropped.
    """
    raw: list[object] = []
    if isinstance(payload, list):
        raw = list(payload)
    elif isinstance(payload, dict):
        for key, value in payload.items():
            if str(key) != serial:
                log.debug("dropping frames for %s while collecting %s", key, serial)
                continue
            if isinstance(value, dict):
                raw.extend(value.values())
            elif isinstance(value, list):
                raw.extend(value)

    seen: dict[datetime, Frame] = {}
    for item in raw:
        frame = Frame.from_json(item)
        if frame is not None:
            seen[frame.t] = frame  # dedup on datetime (R-6)
    return sorted(seen.values(), key=lambda f: f.t)
