"""Tawhiri client (§4.4).

Only three things are taken from the response: the landing point, the descent
rate Tawhiri itself modelled, and the GFS dataset epoch. The trajectory is
discarded (R-12) -- creep is movement of the landing point, and Tawhiri's
descent curve is model-internal and probeable synthetically at any time.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime

from .httpclient import HttpClient
from .sondehub import parse_dt

log = logging.getLogger(__name__)

URL = "https://api.v2.sondehub.org/tawhiri"


class PredictionRejected(Exception):
    """Tawhiri refused the request.

    Most often ``PredictionException: 'hour=-N'`` -- the requested
    ``launch_datetime`` falls before the loaded dataset's epoch minus one 3 h grid
    step, which is unrecoverable (§2).
    """


@dataclass(frozen=True)
class Prediction:
    landing_lat: float
    landing_lon: float
    #: The GFS run that answered. Distinguishes real creep from the wind model
    #: changing underneath you, and is the validity test for a repaired tick.
    dataset: str | None
    #: Tawhiri's own descent rate at the sonde's altitude, m/s, negative falling.
    vz_pred: float | None
    #: Modelled seconds from the sonde's current altitude to the ground.
    #:
    #: The descent_rate parameter's only effect is on this number -- the landing
    #: point is downstream of it, because drift is the integral of wind over
    #: flight time. At a fixed altitude Tawhiri's model gives T = (H/r)(1 - e^-h/H),
    #: so T is inversely proportional to r and the parameter needed to reach a
    #: target flight time is one multiplication away: r_new = r * T_pred/T_target.
    #: Controlling on time rather than on landing position keeps wind entirely
    #: out of the loop.
    flight_time_s: float | None = None
    #: Descent trajectory as (time, lat, lon, altitude), for computing the wind
    #: profile. Differencing consecutive points gives the horizontal wind at each
    #: altitude -- the one thing Tawhiri knows that we cannot measure ourselves.
    #: Held for computation only; R-12 still forbids storing it.
    trajectory: tuple[tuple[datetime, float, float, float], ...] = ()


def _num(obj: object) -> float | None:
    if isinstance(obj, bool) or obj is None:
        return None
    return float(obj) if isinstance(obj, (int, float)) else None


def _stages(payload: object) -> list[dict[str, object]]:
    if not isinstance(payload, dict):
        return []
    stages = payload.get("prediction")
    if not isinstance(stages, list):
        return []
    return [s for s in stages if isinstance(s, dict)]


def _points(stage: dict[str, object]) -> list[dict[str, object]]:
    traj = stage.get("trajectory")
    if not isinstance(traj, list):
        return []
    return [p for p in traj if isinstance(p, dict)]


def _descent_rate(stage: dict[str, object]) -> float | None:
    """Slope of the descent trajectory where it leaves the sonde's altitude."""
    pts = _points(stage)
    if len(pts) < 2:
        return None
    first = pts[0]
    t0, a0 = first.get("datetime"), _num(first.get("altitude"))
    if not isinstance(t0, str) or a0 is None:
        return None
    for nxt in pts[1:]:
        t1, a1 = nxt.get("datetime"), _num(nxt.get("altitude"))
        if not isinstance(t1, str) or a1 is None or a1 == a0:
            continue
        try:
            dt = (parse_dt(t1) - parse_dt(t0)).total_seconds()
        except ValueError:
            return None
        if dt > 0:
            return (a1 - a0) / dt
    return None


def _trajectory(stage: dict[str, object]) -> tuple[tuple[datetime, float, float, float], ...]:
    out: list[tuple[datetime, float, float, float]] = []
    for pt in _points(stage):
        when = pt.get("datetime")
        lat, lon = _num(pt.get("latitude")), _num(pt.get("longitude"))
        alt = _num(pt.get("altitude"))
        if not isinstance(when, str) or lat is None or lon is None or alt is None:
            continue
        try:
            out.append((parse_dt(when), lat, lon, alt))
        except ValueError:
            continue
    return tuple(out)


def _flight_time(stage: dict[str, object]) -> float | None:
    """Seconds spanned by the descent trajectory: sonde altitude to the ground."""
    pts = _points(stage)
    if len(pts) < 2:
        return None
    first, last = pts[0].get("datetime"), pts[-1].get("datetime")
    if not isinstance(first, str) or not isinstance(last, str):
        return None
    try:
        return (parse_dt(last) - parse_dt(first)).total_seconds()
    except ValueError:
        return None


def _error_of(payload: object) -> str | None:
    if not isinstance(payload, dict):
        return None
    err = payload.get("error")
    if not isinstance(err, dict):
        return None
    desc = err.get("description")
    return str(desc) if desc is not None else str(err.get("type", "unknown"))


class Tawhiri:
    def __init__(self, http: HttpClient, ascent_rate: float, burst_offset_m: float) -> None:
        self._http = http
        self._ascent_rate = ascent_rate
        self._burst_offset_m = burst_offset_m

    def predict(
        self, lat: float, lon: float, alt: float, when: datetime, descent_rate: float
    ) -> Prediction:
        """Predict the landing for a descent already underway (§4.4)."""
        params: dict[str, str | float] = {
            "launch_latitude": round(lat, 7),
            "launch_longitude": round(lon, 7),
            "launch_datetime": when.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "launch_altitude": round(alt, 1),
            # The API requires burst above launch, so the descent starts here.
            "burst_altitude": round(alt + self._burst_offset_m, 1),
            "ascent_rate": self._ascent_rate,
            "descent_rate": descent_rate,
            "profile": "standard_profile",
            "format": "json",
        }
        payload = self._http.get_json(URL, params)

        error = _error_of(payload)
        if error is not None:
            raise PredictionRejected(error)

        stages = _stages(payload)
        if not stages:
            raise PredictionRejected("response carried no prediction stages")

        descent = next((s for s in stages if s.get("stage") == "descent"), stages[-1])
        pts = _points(descent)
        if not pts:
            raise PredictionRejected("descent stage carried no trajectory")
        last = pts[-1]
        llat, llon = _num(last.get("latitude")), _num(last.get("longitude"))
        if llat is None or llon is None:
            raise PredictionRejected("final trajectory point had no coordinates")

        dataset: str | None = None
        if isinstance(payload, dict):
            request = payload.get("request")
            if isinstance(request, dict):
                value = request.get("dataset")
                dataset = str(value) if value is not None else None

        return Prediction(
            landing_lat=llat,
            landing_lon=llon,
            dataset=dataset,
            vz_pred=_descent_rate(descent),
            flight_time_s=_flight_time(descent),
            trajectory=_trajectory(descent),
        )
