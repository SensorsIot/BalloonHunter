# Landing prediction track — W4214924, 2026-08-21

How the predicted landing point moved over one flight, as the app actually
recorded it. Sonde **W4214924**, launched from Payerne at 10:10 UTC
(12:10 local). Times below are **device-local (CEST, UTC+2)**.

This is an observational record pulled from the device's unified log, not a
synthetic run. The app predicts about once a minute; the rows here are the
predictions that survived in the log ring buffer across several pulls, so the
series is **sparse where info-level entries had already aged out** — it is a
faithful sample of the real track, not every tick of it.

Two servers appear because the run spanned the switch to the
Swiss-Balloon-Predictor: the early rows came from **SondeHub**, the later ones
from **predictor.fabia.ch** once the new build was installed. Both speak the same
Tawhiri contract, so the points are directly comparable.

**Drift** is the great-circle distance from the previous predicted landing point.

| # | Time (CEST) | Server | Landing lat | Landing lon | Burst lat | Burst lon | Drift (km) |
|--:|:-----------:|:-------|------------:|------------:|----------:|----------:|-----------:|
| 1 | 13:46:52 | SondeHub | 47.64227 | 7.50285 | 47.35779 | 7.23019 | — |
| 2 | 13:47:08 | SondeHub | 47.64065 | 7.50026 | 47.35621 | 7.22758 | 0.26 |
| 3 | 14:32:40 | SondeHub | 47.64585 | 7.48591 | 47.36256 | 7.21099 | 1.22 |
| 4 | 14:33:40 | SondeHub | 47.64690 | 7.48488 | 47.36355 | 7.20998 | 0.14 |
| 5 | 14:34:41 | SondeHub | 47.64635 | 7.48791 | 47.36303 | 7.21306 | 0.23 |
| 6 | 14:42:34 | predictor.fabia.ch | 47.65963 | 7.47583 | 47.35922 | 7.20826 | 1.73 |
| 7 | 14:43:34 | predictor.fabia.ch | 47.66055 | 7.47287 | 47.36017 | 7.20512 | 0.24 |
| 8 | 14:43:53 | predictor.fabia.ch | 47.66115 | 7.47167 | 47.36062 | 7.20397 | 0.11 |
| 9 | 15:24:37 | predictor.fabia.ch | 47.71244 | 7.53390 | 47.59167 | 7.37350 | 7.35 |
| 10 | 15:25:37 | predictor.fabia.ch | 47.71343 | 7.53437 | 47.60475 | 7.37531 | 0.11 |
| 11 | 15:26:37 | predictor.fabia.ch | 47.71429 | 7.53771 | 47.61704 | 7.38128 | 0.27 |

## What the track shows

- **While ascending (rows 1–8)** the predicted landing sat around
  **47.64–47.66 N, 7.47–7.50 E**, moving only a few hundred metres between
  consecutive predictions — steady, because the trajectory rested on the assumed
  burst altitude and the winds aloft were stable.
- **The 7.35 km jump at row 9 is the burst.** The burst point leapt north from
  ~47.36 N to ~47.59 N: the balloon burst higher and further downrange than the
  ascent-phase assumption, so the whole descent shifted and the landing estimate
  moved with it. This is the moment the prediction stops being a forecast and
  starts tracking the real fall.
- **After burst (rows 9–11)** the estimate settled again near
  **47.71 N, 7.54 E**, drifting only ~0.1–0.3 km per prediction as the descent
  proceeded.

## How this was produced

Pulled with `idevicesyslog archive`, filtered to `subsystem ==
"com.yourcompany.BalloonHunter"`, and reduced to the
`PredictionService … Landing: (…), Burst: (…)` lines. Drift is the great-circle
distance between successive landing points. No values were smoothed or
interpolated; gaps in time are gaps in the surviving log, nothing more.
