# 🐍 Simulation

Python target of the [BalloonHunter](../README.md) monorepo.

Contains the **Radiosonde Descent Collector** — an unattended program that watches
for radiosonde flights and, from burst onward, repeatedly asks the SondeHub
Tawhiri API where each one will land using several descent rates at once.

It exists to answer one question: *how soon after burst does the predicted landing
point stop moving, and what must Tawhiri be fed to make it stop moving sooner?*
The apps currently assume a fixed 5 m/s descent rate; when that is wrong the
predicted landing can be tens of kilometres out.

Full specification: [`../docs/SondeCollectorFSD.md`](../docs/SondeCollectorFSD.md).

## What it records, and what it doesn't

Tawhiri holds exactly one GFS dataset and refuses any `launch_datetime` earlier
than that run's epoch minus 3 hours — so a prediction not made during the flight
**cannot be made afterwards at all**. Predictions are the only one-shot data.

Telemetry, by contrast, is retrievable from SondeHub indefinitely (a three-week-old
flight came back complete in 2.4 s), so the collector **never writes it**. The
analysis re-fetches the track by serial.

The result is ~12 kB per flight instead of ~9.8 MB:

```
data/<serial>_<launch-date>/
  meta.json          identity, lifecycle, burst point, last_heard
  predictions.jsonl  one ~140-byte line per (tick, rate)
```

The collector makes no scientific decisions. It detects launch, burst and silence
so it knows *when* to ask, and records what comes back. Conclusions are drawn
separately, from statistics over many flights.

## Running it

Stdlib only — no runtime dependencies.

```bash
python -m balloonhunter_sim                        # poll configured stations
python -m balloonhunter_sim --serial W3821271      # follow one sonde directly
python -m balloonhunter_sim --config my.json -v    # override any FSD default
```

Configuration is JSON, keyed by the field names in `config.py`:

```json
{"stations": ["06610"], "data_dir": "data", "sweep_rates": [2, 3, 4, 5, 7]}
```

It survives restart: `resume()` rebuilds active flights from disk, and ticks
missed during an outage are re-issued and flagged `"repaired": true`. A repaired
tick is equivalent to a live one only if its `dataset` epoch matches its
neighbours — which is why the epoch is on every line.

## Layout

```
Simulation/
├── src/balloonhunter_sim/
│   ├── config.py       every FSD-configurable value
│   ├── httpclient.py   gzip + 302 handling, retries, backoff
│   ├── ratelimit.py    request spacing and the daily ceiling
│   ├── sondehub.py     station listing and windowed telemetry
│   ├── tawhiri.py      landing prediction
│   ├── flight.py       lifecycle, launch/burst detection, vz_real
│   ├── storage.py      atomic meta.json, append-only predictions.jsonl
│   └── collector.py    orchestration
└── tests/              85 tests, one or more per requirement R-1..R-18
```

## Development

The devcontainer at the repo root provides Python 3.11 and installs
`requirements-dev.txt` on create. From `/workspaces/BalloonHunter`:

```bash
pip install -e Simulation
pytest Simulation/tests      # 85 tests
ruff check Simulation
mypy                         # strict, from Simulation/pyproject.toml
```

## See also

- [`../docs/SondeCollectorFSD.md`](../docs/SondeCollectorFSD.md) — the specification
- [`../docs/SondeHub_API_Reference.md`](../docs/SondeHub_API_Reference.md) — endpoint details
- [`../ios/README.md`](../ios/README.md), [`../android/README.md`](../android/README.md)
