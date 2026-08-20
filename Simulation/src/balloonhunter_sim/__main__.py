"""Command line entry point: ``python -m balloonhunter_sim`` / ``sonde-collector``."""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from .collector import Collector
from .config import Config
from .httpclient import HttpClient
from .ratelimit import CeilingReached, PoliteLimiter
from .replay import ReplayHub, fetch_history, shift_for_burst, utcnow
from .sondehub import SondeHub
from .tawhiri import Tawhiri


def build(cfg: Config) -> Collector:
    limiter = PoliteLimiter(
        cfg.min_request_spacing_s,
        cfg.daily_request_ceiling,
        counter_path=cfg.request_counter_path,
    )
    http = HttpClient(cfg.user_agent, limiter, cfg.request_timeout_s, cfg.max_retries)
    return Collector(cfg, SondeHub(http), Tawhiri(http, cfg.ascent_rate, cfg.burst_offset_m))


def run_replay(cfg: Config, args: argparse.Namespace) -> int:
    """Drive the collector from a shifted recording (see replay.py)."""
    log = logging.getLogger(__name__)
    limiter = PoliteLimiter(
        cfg.min_request_spacing_s,
        cfg.daily_request_ceiling,
        counter_path=cfg.request_counter_path,
    )
    http = HttpClient(cfg.user_agent, limiter, cfg.request_timeout_s, cfg.max_retries)

    frames = fetch_history(http, args.replay)
    shift = shift_for_burst(frames, utcnow(), args.replay_lead)
    hub = ReplayHub(args.replay, frames, shift, utcnow, station=args.station)
    log.warning(
        "REPLAY of %s: %d frames shifted by %+.0f s; burst at %s, ends %s. "
        "Pipeline test only -- these predictions are not scientific data.",
        args.replay,
        len(frames),
        shift.total_seconds(),
        hub.burst_at.strftime("%H:%M:%SZ"),
        hub.ends_at.strftime("%H:%M:%SZ"),
    )

    collector = Collector(cfg, hub, Tawhiri(http, cfg.ascent_rate, cfg.burst_offset_m))
    collector.track(args.replay, args.station)
    try:
        collector.run(iterations=args.iterations, sleep_s=args.interval)
    except CeilingReached:
        return 2
    except KeyboardInterrupt:
        return 130
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="sonde-collector",
        description="Radiosonde descent collector - records Tawhiri landing predictions "
        "during descent. See docs/SondeCollectorFSD.md.",
    )
    parser.add_argument("--config", type=Path, help="JSON config file overriding defaults")
    parser.add_argument("--data-dir", type=Path, help="output directory (default: data/)")
    parser.add_argument(
        "--serial",
        action="append",
        default=[],
        metavar="SERIAL",
        help="track this serial directly, bypassing station discovery (repeatable)",
    )
    parser.add_argument("--station", default="manual", help="station label for --serial")
    parser.add_argument(
        "--replay",
        metavar="SERIAL",
        help="replay a completed flight with its clock shifted to now, driving the "
        "real Tawhiri API. Exercises the pipeline; produces no scientific data.",
    )
    parser.add_argument(
        "--replay-lead",
        type=float,
        default=90.0,
        help="seconds from startup until the replayed burst (default: 90)",
    )
    parser.add_argument(
        "--iterations", type=int, help="stop after N loop passes (default: run forever)"
    )
    parser.add_argument("--interval", type=float, default=5.0, help="seconds between passes")
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )

    cfg = Config.load(args.config)
    if args.data_dir is not None:
        from dataclasses import replace

        cfg = replace(cfg, data_dir=args.data_dir)

    if args.replay:
        return run_replay(cfg, args)

    collector = build(cfg)
    collector.resume()
    for serial in args.serial:
        if serial not in collector.flights:
            collector.track(serial, args.station)

    try:
        collector.run(iterations=args.iterations, sleep_s=args.interval)
    except CeilingReached:
        return 2
    except KeyboardInterrupt:
        logging.getLogger(__name__).info("interrupted; flights remain resumable")
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
