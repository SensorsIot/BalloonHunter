"""Flight lifecycle, launch and burst detection.

Covers R-2, R-3, R-4, R-6, R-8, R-10 (vz_real) and §8 (gaps stay visible).
"""

from __future__ import annotations

from datetime import timedelta

from balloonhunter_sim.config import Config
from balloonhunter_sim.flight import Flight, State
from balloonhunter_sim.sondehub import Frame

from .conftest import T0, frames, ramp


def new_flight() -> Flight:
    return Flight(serial="W0000001", station="06610", type="RS41")


# ----------------------------------------------------------------- R-8 launch


def test_ground_reporting_is_not_launch() -> None:
    """R-1/R-8: W4214540 reported from the ground for 15 h before it flew."""
    flight = new_flight()
    ground = frames([561.0 + (i % 3) for i in range(3000)], step_s=18.0)
    flight.ingest(ground, Config())
    assert flight.state is State.PRELAUNCH
    assert flight.launch_datetime is None


def test_sustained_ascent_is_launch() -> None:
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 40), Config())
    assert flight.state is State.ASCENT
    assert flight.launch_datetime is not None


# ------------------------------------------------------------------ R-8 burst


def ascended() -> tuple[Flight, Config]:
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 100), cfg)
    assert flight.state is State.ASCENT
    return flight, cfg


def test_burst_requires_drop_and_consecutive_frames() -> None:
    """R-8: altitude below running max by >300 m, sustained over >=3 frames."""
    flight, cfg = ascended()
    peak = 500.0 + 30.0 * 99
    start = T0 + timedelta(seconds=100)

    # A 200 m drop is under the threshold: not a burst.
    flight.ingest(frames([peak - 20 * i for i in range(1, 11)], start=start), cfg)
    assert flight.state is State.ASCENT

    # Continuing past 300 m triggers it.
    flight.ingest(
        frames([peak - 200 - 20 * i for i in range(1, 21)], start=start + timedelta(seconds=11)),
        cfg,
    )
    assert flight.state is State.DESCENT
    assert flight.burst_altitude == peak
    assert flight.next_sweep_at is not None


def test_single_noisy_dip_is_not_burst() -> None:
    """R-8: hysteresis. Frames are 1-2 s apart and noisy near apogee."""
    flight, cfg = ascended()
    peak = 500.0 + 30.0 * 99
    dip = [peak - 400.0, peak + 10.0, peak + 20.0]
    flight.ingest(frames(dip, start=T0 + timedelta(seconds=200)), cfg)
    assert flight.state is State.ASCENT, "one frame below the max must not trigger burst"


def test_burst_detected_without_vel_v() -> None:
    """§4.1: iMet sondes omit vel_v entirely; altitude alone must govern."""
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 100), cfg)
    peak = 500.0 + 30.0 * 99
    descent = frames(
        [peak - 20 * i for i in range(1, 31)], start=T0 + timedelta(seconds=100), vel_v=False
    )
    assert all(f.vel_v is None for f in descent)
    flight.ingest(descent, cfg)
    assert flight.state is State.DESCENT


def test_positive_vel_v_blocks_burst() -> None:
    """R-8: where vel_v exists it corroborates; a rising vel_v contradicts a burst."""
    flight, cfg = ascended()
    peak = 500.0 + 30.0 * 99
    start = T0 + timedelta(seconds=100)
    contradictory = [
        Frame(t=start + timedelta(seconds=i), alt=peak - 20 * i, lat=47.0, lon=8.0, vel_v=5.0)
        for i in range(1, 31)
    ]
    flight.ingest(contradictory, cfg)
    assert flight.state is State.ASCENT


# -------------------------------------------------------------------- R-6/R-4


def test_frames_deduplicated_on_datetime() -> None:
    """R-6: the same frame arriving twice must not be counted twice."""
    cfg = Config()
    flight = new_flight()
    batch = ramp(500.0, 30.0, 40)
    flight.ingest(batch, cfg)
    first = flight.frames_seen
    flight.ingest(batch, cfg)
    assert flight.frames_seen == first


def test_last_heard_is_the_last_frame() -> None:
    """R-4: recorded as last_heard -- never as a landing position."""
    cfg = Config()
    flight = new_flight()
    batch = ramp(500.0, 30.0, 40)
    flight.ingest(batch, cfg)
    assert flight.last_heard is not None
    assert flight.last_heard.t == batch[-1].t
    assert flight.last_heard.alt == batch[-1].alt


# ----------------------------------------------------------------------- §8


def test_sampling_gaps_are_counted() -> None:
    """§8: gaps must be visible in the output, not smoothed away."""
    cfg = Config()
    flight = new_flight()
    early = ramp(500.0, 30.0, 20)
    late = ramp(2000.0, 30.0, 20, start=T0 + timedelta(seconds=200))
    flight.ingest(early + late, cfg)
    assert flight.gaps == 1
    assert flight.max_gap_s >= 60.0


# ------------------------------------------------------------- R-10 vz_real


def test_vz_real_is_median_over_window() -> None:
    """R-10: median, not mean -- the 0.62 m/s per-frame noise floor is real."""
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 60), cfg)
    flight.ingest(ramp(20000.0, -5.0, 60, start=T0 + timedelta(seconds=100)), cfg)
    vz = flight.vz_real(cfg)
    assert vz is not None
    assert abs(vz - (-5.0)) < 0.01


def test_vz_real_none_when_no_telemetry() -> None:
    """§8: a tick with no telemetry behind it gets null, never a stale value."""
    flight = new_flight()
    assert flight.vz_real(Config()) is None


def test_vz_real_ignores_intervals_across_a_gap() -> None:
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 40), cfg)
    flight.ingest(ramp(9000.0, -5.0, 40, start=T0 + timedelta(seconds=600)), cfg)
    vz = flight.vz_real(cfg)
    assert vz is not None
    assert abs(vz - (-5.0)) < 0.01, "the 600 s jump must not be treated as a descent rate"


# --------------------------------------------------------------------- R-3


def test_closed_on_silence_only() -> None:
    """R-3: silence is the close condition."""
    cfg = Config()
    flight = new_flight()
    batch = ramp(500.0, 30.0, 40)
    flight.ingest(batch, cfg)
    last = batch[-1].t
    assert not flight.is_silent(last + timedelta(minutes=29), cfg)
    assert flight.is_silent(last + timedelta(minutes=31), cfg)


def test_low_and_slow_sonde_stays_open_while_reporting() -> None:
    """R-3: the removed 'below 1000 m, static for 10 min' rule must not close a flight.

    All four sondes at station 06610 on 2026-08-20 lost contact while still
    descending; that rule never fires in practice, and a still-reporting sonde
    near the ground must remain active.
    """
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 40), cfg)
    static_low = frames([900.0] * 700, start=T0 + timedelta(seconds=100), step_s=1.0)
    flight.ingest(static_low, cfg)
    assert flight.last_heard is not None
    assert not flight.is_silent(flight.last_heard.t + timedelta(seconds=30), cfg)


# ----------------------------------------------- near-duplicate frames (real)


def test_near_duplicate_frames_do_not_poison_vz_real() -> None:
    """Frames milliseconds apart survive datetime dedup and must not be used.

    Observed live on W3821271: several receivers upload the same frame with
    timestamps 1-5 ms apart. Dividing a 12 m altitude step by 0.004 s gives
    3000+ m/s, which would swamp any mean and can skew a median if frequent.
    """
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 40), cfg)

    start = T0 + timedelta(seconds=200)
    poisoned: list[Frame] = []
    alt = 10000.0
    for i in range(40):
        # a well-spaced frame, then a near-duplicate 4 ms later
        poisoned.append(
            Frame(t=start + timedelta(seconds=i), alt=alt, lat=47.0, lon=8.0, vel_v=-5.0)
        )
        poisoned.append(
            Frame(
                t=start + timedelta(seconds=i, milliseconds=4),
                alt=alt - 0.05,
                lat=47.0,
                lon=8.0,
                vel_v=-5.0,
            )
        )
        alt -= 5.0
    flight.ingest(poisoned, cfg)

    vz = flight.vz_real(cfg)
    assert vz is not None
    assert abs(vz - (-5.0)) < 0.5, f"near-duplicates poisoned vz_real: {vz}"
    assert abs(vz) < 100.0, "a millisecond interval must never yield a huge rate"


def test_intervals_below_the_minimum_are_ignored_entirely() -> None:
    """If every interval is a near-duplicate, report nothing rather than nonsense."""
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 40), cfg)
    start = T0 + timedelta(seconds=300)
    burst = [
        Frame(
            t=start + timedelta(milliseconds=4 * i),
            alt=9000.0 - 0.05 * i,
            lat=47.0,
            lon=8.0,
            vel_v=-5.0,
        )
        for i in range(20)
    ]
    flight.ingest(burst, cfg)
    assert flight.vz_real(cfg, at=burst[-1].t) is None


def test_near_duplicates_do_not_block_burst_detection() -> None:
    """Defensive: a relayed frame must not reset the consecutive-falling counter.

    This is a constructed worst case, not an observed failure. On W3821271's
    real descent all 118 sub-0.5 s pairs stepped downward with the trend, so
    they never reset the counter and burst was detected 41 s after the peak --
    exactly the 300 m threshold at 7.3 m/s. The test pins the behaviour anyway,
    because nothing guarantees an upward wobble cannot occur.
    """
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 100), cfg)
    peak = 500.0 + 30.0 * 99

    start = T0 + timedelta(seconds=100)
    interleaved: list[Frame] = []
    for i in range(1, 40):
        alt = peak - 20.0 * i
        interleaved.append(
            Frame(t=start + timedelta(seconds=i), alt=alt, lat=47.0, lon=8.0, vel_v=-20.0)
        )
        # relayed copy 7 ms later, a hair higher
        interleaved.append(
            Frame(
                t=start + timedelta(seconds=i, milliseconds=7),
                alt=alt + 0.05,
                lat=47.0,
                lon=8.0,
                vel_v=-20.0,
            )
        )
    flight.ingest(interleaved, cfg)
    assert flight.state is State.DESCENT, "near-duplicates blocked burst detection"


def test_near_duplicates_do_not_inflate_gap_counts() -> None:
    """§8: gap statistics describe real sampling, not relay timing."""
    cfg = Config()
    flight = new_flight()
    base = ramp(500.0, 30.0, 30)
    extra = [
        Frame(t=f.t + timedelta(milliseconds=5), alt=f.alt + 0.02, lat=f.lat, lon=f.lon)
        for f in base
    ]
    merged = sorted(base + extra, key=lambda f: f.t)
    flight.ingest(merged, cfg)
    assert flight.gaps == 0


# ------------------------------------------- uploader-aware rates (real data)


def test_rates_are_computed_within_one_uploaders_stream() -> None:
    """Two receivers interleaved must not manufacture an interval.

    Measured on W3821271: each of 26 uploaders had 0.0% sub-0.5 s intervals
    individually, while the merged stream had 5.0%. The artifact is created by
    merging, so rates must be computed per uploader.
    """
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 40), cfg)

    start = T0 + timedelta(seconds=200)
    merged: list[Frame] = []
    alt = 12000.0
    for i in range(20):
        # station A stamps with millisecond precision, 3 ms early
        merged.append(
            Frame(
                t=start + timedelta(seconds=2 * i, milliseconds=-3),
                alt=alt,
                lat=47.0,
                lon=8.0,
                uploader="WBGS-4",
            )
        )
        # station B stamps the SAME instant rounded to the whole second
        merged.append(
            Frame(
                t=start + timedelta(seconds=2 * i),
                alt=alt,
                lat=47.0,
                lon=8.0,
                uploader="MARKA",
            )
        )
        alt -= 20.0  # 10 m/s over the 2 s cadence
    merged.sort(key=lambda f: f.t)
    flight.ingest(merged, cfg)

    vz = flight.vz_real(cfg, at=merged[-1].t)
    assert vz is not None
    assert abs(vz - (-10.0)) < 0.5, f"cross-uploader intervals corrupted vz_real: {vz}"


def test_frames_carry_their_uploader() -> None:
    """§4.2 frames include uploader_callsign; a 1m window held 22 distinct ones."""
    frame = Frame.from_json(
        {
            "datetime": "2026-08-20T12:00:00Z",
            "alt": 1000.0,
            "lat": 47.0,
            "lon": 8.0,
            "uploader_callsign": "DL2MF-14",
        }
    )
    assert frame is not None
    assert frame.uploader == "DL2MF-14"


def test_missing_uploader_still_yields_a_rate() -> None:
    """Frames without an uploader form one stream rather than being discarded."""
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 40), cfg)
    flight.ingest(ramp(9000.0, -6.0, 40, start=T0 + timedelta(seconds=200)), cfg)
    vz = flight.vz_real(cfg)
    assert vz is not None and abs(vz - (-6.0)) < 0.01


# ------------------------------------- adaptive window + station quality (R-19)


def descending_at(rate: float, n: int = 200) -> Flight:
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 60), cfg)
    flight.ingest(
        ramp(30000.0, -rate, n, start=T0 + timedelta(seconds=200)), cfg
    )
    return flight


def test_window_is_short_when_falling_fast_and_long_when_slow() -> None:
    """The window spans the altitude needed for a fixed relative precision."""
    cfg = Config()
    fast = descending_at(30.0).vz_window_s(cfg)
    slow = descending_at(5.0).vz_window_s(cfg)
    assert fast < slow, "a fast descent needs a shorter window than a slow one"
    assert fast == cfg.vz_window_min_s, "30 m/s hits the floor"
    assert abs(slow - cfg.vz_gps_jitter_scale_m / (cfg.vz_target_relative_precision * 5.0)) < 1


def test_window_is_clamped_at_both_ends() -> None:
    cfg = Config()
    assert descending_at(200.0).vz_window_s(cfg) == cfg.vz_window_min_s
    assert descending_at(0.5).vz_window_s(cfg) == cfg.vz_window_max_s


def test_window_falls_back_without_telemetry() -> None:
    assert new_flight().vz_window_s(Config()) == Config().vz_window_s


def test_vz_altitude_is_below_the_tick_altitude_while_descending() -> None:
    """The rate describes the window midpoint, not the tick (§6.3)."""
    cfg = Config()
    flight = descending_at(10.0)
    latest = flight.latest()
    vz_alt = flight.vz_altitude(cfg)
    assert vz_alt is not None and latest is not None
    assert vz_alt > latest.alt, "midpoint is earlier, so higher, during a descent"
    span = flight.vz_window_s(cfg)
    assert abs((vz_alt - latest.alt) - 10.0 * span / 2) < 30.0


def test_station_reporting_wrong_altitudes_is_excluded() -> None:
    """R-19: the sonde sends one set of values; a station can only corrupt them."""
    cfg = Config()
    flight = new_flight()
    flight.ingest(ramp(500.0, 30.0, 60), cfg)
    start = T0 + timedelta(seconds=200)
    mixed: list[Frame] = []
    alt = 20000.0
    for i in range(60):
        for name, err in (("GOOD-1", 0.0), ("GOOD-2", 0.0), ("BAD-9", -40.0)):
            mixed.append(
                Frame(
                    t=start + timedelta(seconds=2 * i, milliseconds=100 * len(name)),
                    alt=alt + err,
                    lat=47.0,
                    lon=8.0,
                    uploader=name,
                )
            )
        alt -= 16.0
    mixed.sort(key=lambda f: f.t)
    flight.ingest(mixed, cfg)
    vz = flight.vz_real(cfg)
    assert vz is not None
    assert "BAD-9" in flight.excluded_stations
    assert "GOOD-1" not in flight.excluded_stations


def test_a_single_station_is_never_excluded() -> None:
    """With nothing to compare against, exclusion would be guesswork."""
    cfg = Config()
    flight = descending_at(8.0)
    flight.vz_real(cfg)
    assert flight.excluded_stations == set()
