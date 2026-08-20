"""On-disk output (§6).

Two files per flight. There is no telemetry.jsonl: the track is re-fetched from
§4.3 by serial whenever the analysis wants it (R-7), which measured complete at
three weeks old in 2.4 s.
"""

from __future__ import annotations

import json
import logging
import os
import tempfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .flight import Flight
from .sondehub import Frame

log = logging.getLogger(__name__)


def iso(dt: datetime) -> str:
    """R-18: UTC, ISO 8601, unambiguous."""
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass(frozen=True)
class PredictionRecord:
    """One line of predictions.jsonl (§6.2)."""

    t: datetime
    tb: float
    rate: float
    alt: float
    lat: float
    lon: float
    plat: float
    plon: float
    vz_real: float | None
    #: The altitude vz_real describes (window midpoint), not the tick altitude.
    vz_alt: float | None
    vz_pred: float | None
    dataset: str | None
    repaired: bool = False

    def to_json(self) -> str:
        payload: dict[str, object] = {
            "t": iso(self.t),
            "tb": round(self.tb, 2),
            "rate": self.rate,
            "alt": round(self.alt, 1),
            "lat": round(self.lat, 6),
            "lon": round(self.lon, 6),
            "plat": round(self.plat, 6),
            "plon": round(self.plon, 6),
            "vz_real": None if self.vz_real is None else round(self.vz_real, 3),
            "vz_alt": None if self.vz_alt is None else round(self.vz_alt, 1),
            "vz_pred": None if self.vz_pred is None else round(self.vz_pred, 3),
            "dataset": self.dataset,
            "repaired": self.repaired,
        }
        return json.dumps(payload, separators=(",", ":"))


def _atomic_write(path: Path, text: str) -> None:
    """R-16: write to a temporary file, then rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=path.name, suffix=".tmp")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


class FlightStore:
    """One directory per flight, so a flight can be copied or deleted whole."""

    def __init__(self, root: Path, flight: Flight) -> None:
        launch = flight.launch_datetime
        if launch is None and flight.last_heard is not None:
            launch = flight.last_heard.t
        stamp = (launch or datetime.now(UTC)).strftime("%Y-%m-%d")
        self.dir = root / f"{flight.serial}_{stamp}"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.meta_path = self.dir / "meta.json"
        self.predictions_path = self.dir / "predictions.jsonl"

    def append(self, record: PredictionRecord) -> None:
        """Append one prediction line.

        A complete short line is written in a single call and fsynced. §6.1 chose
        JSON Lines precisely because a torn tail after a crash costs one record
        and leaves every earlier one readable.
        """
        with self.predictions_path.open("a", encoding="utf-8") as handle:
            handle.write(record.to_json() + "\n")
            handle.flush()
            os.fsync(handle.fileno())

    def written_tick_times(self) -> list[datetime]:
        """Tick times already on disk -- the basis for restart recovery (R-14)."""
        if not self.predictions_path.exists():
            return []
        times: list[datetime] = []
        for line in self.predictions_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue  # torn tail from a crash; §6.1 tolerates exactly this
            if isinstance(obj, dict) and isinstance(obj.get("t"), str):
                try:
                    times.append(datetime.fromisoformat(str(obj["t"]).replace("Z", "+00:00")))
                except ValueError:
                    continue
        return sorted(times)

    def write_meta(self, flight: Flight) -> None:
        """§6.3. Rewritten whenever the flight's lifecycle advances."""
        _atomic_write(self.meta_path, json.dumps(_meta_of(flight), indent=2) + "\n")


def _frame_json(frame: Frame | None) -> dict[str, object] | None:
    if frame is None:
        return None
    return {
        "datetime": iso(frame.t),
        "alt": round(frame.alt, 1),
        "lat": round(frame.lat, 6),
        "lon": round(frame.lon, 6),
        "vel_v": frame.vel_v,
    }


def _meta_of(flight: Flight) -> dict[str, object]:
    return {
        "serial": flight.serial,
        # §6.3: type and station come from the station listing and exist nowhere
        # else in the record. Whether the profile varies by sonde type is a
        # question the statistics will want to ask.
        "type": flight.type,
        "station": flight.station,
        "state": flight.state.value,
        "launch_datetime": None if flight.launch_datetime is None else iso(flight.launch_datetime),
        "burst_datetime": None if flight.burst_datetime is None else iso(flight.burst_datetime),
        "burst_altitude": flight.burst_altitude,
        "burst_lat": flight.burst_lat,
        "burst_lon": flight.burst_lon,
        # R-4: the last frame received. NOT a landing position.
        "last_heard": _frame_json(flight.last_heard),
        "closed_at": None if flight.closed_at is None else iso(flight.closed_at),
        "frames_seen": flight.frames_seen,
        # §8: sampling gaps must be visible in the output, not smoothed away.
        "gaps": flight.gaps,
        "max_gap_s": round(flight.max_gap_s, 1),
        # R-19: an excluded station is never silent.
        "excluded_stations": sorted(
            str(s) for s in flight.excluded_stations if s is not None
        ),
    }
