# Functional Specification: Radiosonde Descent Collector

**Status:** draft for implementation
**Audience:** the agent implementing this program. You are not expected to have
seen the BalloonHunter app or this conversation.

> **Revision note (2026-08-20).** This revision folds in decisions taken during a
> design review, together with measurements taken against the live SondeHub and
> Tawhiri APIs and against flight `W4214540` (Payerne, 2026-08-20, burst 12:50:39Z
> at 36 178 m). Blocks marked **Measured** were established empirically on that
> date. They are recorded so nobody re-derives them; re-measure only if the
> upstream APIs change.

---

## 1. Why this exists

The BalloonHunter app predicts where a weather balloon will land, so its operator
can drive there and recover the sonde. The prediction is made by the SondeHub
**Tawhiri** API, and one of its inputs is `descent_rate`.

That input is frequently wrong, and the error is not small. On one recorded
flight (`W4214915`, 31 July 2026) the sonde descended at ~2.3 m/s near the ground
against an assumed 5.0 m/s. Being aloft far longer than modelled, it drifted, and
came down roughly **50 km from where the first prediction placed it**.

Two failure modes matter, and they are opposite in sign:

- **Slow descent** — an oversized or over-performing parachute. The sonde stays
  up longer and drifts well beyond the prediction.
- **Partially opened parachute** — fast descent, hard landing. This is the case
  the operator most wants to catch, because it causes damage.

The app now corrects the rate in flight, by comparing how far the sonde has
actually fallen against how far Tawhiri predicted it would. Three constants in
that correction were **chosen by judgement, not measured**:

| constant | current value | what it does |
|---|---|---|
| minimum accumulated drop | 2 000 m | below this, refuse to correct at all |
| maximum single step | factor of 2 | cap on how far one correction may move the rate |
| plausible rate range | 1.0–15.0 m/s | reject a correction landing outside this |

**The purpose of this program is to gather the evidence that replaces those
guesses.** The question it must answer is:

> How soon after burst does the predicted landing point stop moving, and what
> must be fed to Tawhiri to make it stop moving sooner?

This is a question about **the behaviour of the prediction**, not about where the
sonde actually landed. The true landing position is *not* required (see §5.1,
R-4). What matters is the creep of the predicted landing point during descent,
because that creep is what sends the operator to the wrong place.

> **Measured — the stakes.** From 20 km altitude, the swept rates predict landings
> **66 km apart** between 2.0 and 5.0 m/s, and still **12 km apart** between 4.0
> and 5.0 m/s. The §1 disaster is reproducible from a single tick. Separation
> between rates is never the problem; knowing which rate is right is.

---

## 2. What the program does

Runs unattended. Watches for radiosonde flights, and — from burst onward —
repeatedly asks Tawhiri where each one will land **using several different
descent rates at once**, recording only where each rate says it will land.

Because several rates are tried at every moment of the descent, the recording
shows directly how each rate's predicted landing point moves as the sonde falls.
The rate whose prediction stops moving is the rate that was right, and it is
identifiable **in flight** — which is the only kind of answer the app can act on.

### Why predictions must be captured live

Telemetry can be replayed from SondeHub at any time. **Tawhiri's wind forecasts
cannot.**

> **Measured — the Tawhiri time window.** Tawhiri holds exactly **one** dataset at
> a time (the response carries `request.dataset`, e.g. `2026-08-20T06:00:00Z`).
> A `launch_datetime` earlier than that epoch minus one 3-hour grid step fails
> with `PredictionException: 'hour=-N'`. Probes at −3 h, −6 h, −9 h, −1 d, −7 d
> and −30 d all failed identically; −1 h, −2 h and −2.5 h succeeded. **There is no
> historical archive.** A prediction not made during the flight cannot be made
> afterwards at any price.

This is stronger than a data-quality argument: retrospective prediction is not
merely contaminated by hindsight winds, it is **impossible**. Live capture is the
only option.

### Repairing a gap

The same measurement gives a bounded recovery path. Because the loaded dataset
typically lags real time by several hours, a tick missed during a descent can
often still be issued afterwards — in practice for roughly **8 hours**.

**R-17** After an outage, the program shall re-issue missed prediction ticks for
any still-active or recently-closed flight, and shall mark each re-issued record
with `"repaired": true`.

A repaired tick is scientifically equivalent to the live one **if and only if**
the `dataset` epoch recorded on it equals the epoch on the neighbouring live
ticks. If the epoch has advanced, the tick was informed by winds that were not
available at the time and the analysis must exclude it. This check is only
possible because R-10 records the epoch.

---

## 3. Scope

**In scope**

- Sondes launched from Payerne, Switzerland (SondeHub station `06610`) **and from
  neighbouring European stations**. Payerne alone yields 2 flights/day (~60/month),
  of which anomalous parachutes are a handful — too slow to build a dataset.
  Roughly 12 stations gives ~24 flights/day and reaches statistical power in weeks.
- The flight from **burst onward**. Ascent is not the subject of study.
- Any sonde type the stations launch (RS41 predominantly; also iMet, which
  reports no vertical velocity — see §4.1).

**Out of scope**

- Any interaction with the BalloonHunter iOS or Android app. This program is standalone.
- Real-time alerting, dashboards, or a UI. It writes files.
- Analysis. It gathers; conclusions are drawn separately from what it wrote.
- **Storing telemetry.** See §6.

**Resolved during review** (these were previously deferred to the operator)

1. **Station scope** — Payerne plus neighbouring stations, ~12 total.
2. **Retention** — predictions only, uncompressed. See §6.
3. **Output destination** — files on the host running the collector. At ~60 MB/year
   the destination is unconstrained; any host that stays up qualifies.

**Still open — ask the operator before implementing**

1. **The station list itself.** Which ~12 stations, by WMO ID.
2. **Deployment host.** Must survive reboots and keep 11Z/23Z appointments for
   months. A development container is not a suitable home.
3. ~~**Sweep set.**~~ **Resolved 2026-08-20 — the set was too narrow.** See the
   measured block in §5.3: the first flight captured end to end fell **outside**
   2.0–7.0 m/s for 8 of its 12 ticks. Fast failures are real. The sweep must be
   extended upward; 10.0 and 12.0 m/s are the obvious additions.

---

## 4. External interfaces

### 4.1 SondeHub — station listing

```
GET https://api.v2.sondehub.org/sondes/site/{station_id}
```

Returns a JSON object keyed by **sonde serial**, each value carrying at minimum:
`serial`, `type`, `datetime` (ISO 8601), `lat`, `lon`, `alt`, `vel_h`, `vel_v`,
`frequency`, `tx_frequency`, `uploader_position`.

> **`vel_v` and `vel_h` are optional.** iMet sondes omit them. A decoder that
> requires them fails to parse the entire response — this exact bug hid three
> live sondes from the app. Confirmed still live on 2026-08-20: station 06610
> carried `B84004EE` (iMet-4) with no `vel_v` field at all.

### 4.2 SondeHub — live telemetry (windowed)

```
GET https://api.v2.sondehub.org/sondes/telemetry?serial={serial}&duration={duration}
```

Returns `{ serial: { timestamp: frame } }`. This is the endpoint for **live
polling**: small, incremental, and windowed. Use a `duration` that covers the
poll interval so consecutive polls overlap and no frame is missed, without
dwarfing it.

> **Measured — `duration` is an enumerated set, and a bad one is not an error.**
> Only `3d, 1d, 12h, 6h, 3h, 1h, 30m, 1m, 15s, 0` are accepted. Anything else —
> `10m`, say — is answered with **HTTP 200 and a plain-text body**: `Duration
> must be either 3d, 1d, 12h, 6h, 3h, 1h, 30m, 1m, 15s, 0`. A client that assumes
> 200 means JSON sees only a decode failure, retries a permanent rejection, and
> reports the wrong cause. Treat a 200 carrying non-JSON as permanent.

> **Measured — window size dominates cost.** For one live flight: `15s` = 15 kB,
> `1m` = 57 kB, `30m` = 1.5 MB, `3h` = 1.56 MB. Polling a long window at a short
> interval re-downloads the entire flight every time: `3h` against a 30 s poll is
> 1.56 MB per poll to learn about ~60 new frames, which is exactly the behaviour
> R-13 exists to prevent. Pair `1m` with a 30 s interval.
>
> The **first** poll of a flight is the exception and must use a long window: burst
> detection compares against the running maximum altitude, and launch detection
> needs the ground level, neither of which exists in a one-minute window.

### 4.3 SondeHub — full flight history

```
GET https://api.v2.sondehub.org/sonde/{serial}
```

Returns the complete flight for **any sonde ever recorded**.

> **Measured — permanence and traps.** `W4214915` (31 July 2026) was retrieved in
> full on 2026-08-20, three weeks later: 333 282 frames, 9.27 MB, in 2.4 s.
> Historical telemetry does not expire. Two traps: the endpoint answers **302**
> and a client that does not follow redirects silently receives **zero bytes with
> no error**; and responses are **gzip-encoded regardless of request headers**, so
> a naive UTF-8 decode fails at byte 1. The 333 282 frames deduplicate to ~11 000
> — the duplication is many receivers uploading the same frame. Deduplicate on
> `datetime`.

**This endpoint is not used by the collector.** It is documented because it is how
the analysis recovers the track later (§6).

### 4.4 Tawhiri — landing prediction

```
GET https://api.v2.sondehub.org/tawhiri
    ?launch_latitude=..&launch_longitude=..&launch_datetime=<ISO8601>
    &launch_altitude=..&burst_altitude=..&ascent_rate=..&descent_rate=..
    &profile=standard_profile&format=json
```

To predict a **descent already underway**, set `launch_altitude` to the sonde's
current altitude and `burst_altitude` to that altitude **+10 m** (the API requires
burst above launch).

Response contains `prediction: [{stage, trajectory: [{datetime, latitude,
longitude, altitude}]}]` with stages `ascent` and `descent`, and `request.dataset`
identifying the GFS run used.

> **Measured — cost.** 0.17–0.39 s per call, 5.8–25.6 kB response (larger for
> slower rates). Latency is not a constraint; twelve simultaneous descents at
> 5 rates fit comfortably inside a 2-minute tick at 1 s politeness spacing.

> **Measured — determinism and the noise floor.** Tawhiri is **exactly
> deterministic**: three calls with identical parameters returned bit-identical
> landing coordinates. There is therefore no stochastic noise to average away, and
> every difference between consecutive ticks has a cause.
>
> It is not, however, smooth. Shifting the launch position by ±10–30 m moved the
> landing point 1:1 in six of eight probes, but two probes jumped by ~110 m in
> directions unrelated to the input — a quantisation step from crossing a wind-grid
> cell or changing the integration step count, not a gain.
>
> Consequence for the analysis: treat **100–150 m** as the tick-to-tick floor, and
> use **bearing consistency** rather than step magnitude to separate real creep
> from the floor. Quantisation jumps scattered across 7°, 69°, 87°, 187° and 273°
> in the probes; creep from a wrong descent rate is systematically downwind and
> holds its bearing across consecutive ticks.

**Verified behaviour — do not re-derive:** Tawhiri **models atmospheric density
itself**. Its `descent_rate` is a **sea-level terminal velocity**, not the rate a
sonde is observed falling at. Measured across releases from 3 000–30 000 m, its
flight time is 0.44–0.84 of the naive `altitude / rate`, implying a velocity scale
height near **15 500 m** above 12 km. Feeding it a rate observed at altitude
therefore over-states the descent, because it scales an already-scaled figure.

> **Measured — a discrepancy worth testing.** Fitting `W4214540`'s own descent
> profile (36 altitude bands, R² = 0.948) gives a velocity scale height of
> **19 556 m**, not 15 500 m, and an implied sea-level rate of **5.03 m/s**.
> Anchoring at the observed 1–2 km rate and extrapolating upward with 15 500 m
> predicts **52 m/s at 35.5 km where the sonde actually fell at 25.4 m/s**.
> The textbook value for terminal velocity under ρ^−½ scaling in a ~7.7 km
> density atmosphere is ~15.4 km, so Tawhiri appears to implement ideal scaling
> while a real chute falls shallower.
>
> On one flight this is an observation, not a finding. But if it holds across
> flights it is a **structural** source of landing-point creep that no choice of
> `descent_rate` can remove — the curve shape would be wrong, not just its scale.
> This is the single most valuable thing the dataset can settle, and R-10's
> `vz_pred`/`vz_real` pair exists to settle it.

> **Measured — the pair working, first tick.** Replaying `W4214540` through the
> collector against the live API: at **35 347 m** the sonde was falling at
> `vz_real` = **−28.40 m/s**, while Tawhiri returned `vz_pred` of −23.95, −35.01,
> −45.53, −55.57 and −74.32 m/s for swept rates of 2, 3, 4, 5 and 7. That is a
> scaling of 10.6–12.0× the sea-level rate at 35 km, implying a Tawhiri velocity
> scale height near **14 700 m** — against the **19 556 m** this flight actually
> flew. Fed its true sea-level rate of 5.03 m/s, Tawhiri has the sonde descending
> at 55.6 m/s where it really descends at 28.4.
>
> Note this comparison survives replay: `vz_pred` comes from Tawhiri's **vertical**
> model, which is wind-independent, and `vz_real` is real telemetry. §7 item 4 is
> therefore answerable from replay runs. §7 items 1–2 are **not** — a replayed
> landing point combines old positions with today's winds and means nothing.

---

## 5. Requirements

### 5.1 Flight lifecycle

**R-1** The program shall poll the station listing for every configured station at
a configurable interval (default 60 s) and treat each unseen serial as a new flight.

> A sonde may appear in telemetry long before it flies: `W4214540` reported from
> the ground at 561 m for **15 hours** before its launch. First sighting is not
> launch. A flight is not considered launched until sustained ascent is observed.

**R-2** A flight shall be **active** from launch detection until closed by R-3.

**R-3** A flight shall be closed when no new telemetry frame has appeared for a
configurable timeout (default 30 min).

> The previously specified alternative condition — altitude below 1 000 m and
> changed by less than 50 m for 10 minutes — has been removed because it **never
> fires**. All four sondes present at station 06610 on 2026-08-20 lost contact
> while still descending, at 652 m (−6.1 m/s), 1 021 m (−12.8 m/s), 1 032 m
> (−6.9 m/s) and 1 629 m (`vel_v` absent). Radiosondes drop below the receivers'
> horizon before landing, essentially always.

**R-4** On closing a flight, the program shall record the **last received frame**
(lat, lon, alt, timestamp) in `meta.json` as `last_heard`.

> This is **not** ground truth and shall not be described as a landing position.
> It is retained because it is free and bounds the flight. Per §1 the study
> concerns creep of the *predicted* landing point; the true landing position is
> not required, which is fortunate because it is almost never observed.

**R-5** The program shall handle **concurrent flights**.

> Synoptic launches are synchronised worldwide: 11Z and 23Z at every station, so
> the sonde is at altitude for the 00Z/12Z observation. Adding stations does not
> spread load across the day — it produces ~12 **simultaneous** descents twice a
> day, all bursting within the same 90-minute window. Design for a burst of
> concurrency, not a steady trickle.

**R-6** For each active flight, telemetry shall be fetched from §4.2 at a
configurable interval (default 30 s), deduplicated on `datetime`, and held **in
memory only**. It is the input to burst detection (R-8) and to `vz_real` (R-10).

The **first** poll of a flight, and the first after a restart, shall use a long
window (default `3h`) to establish the flight's history; every poll thereafter
shall use the short steady-state window (default `1m`). The steady-state window
shall cover the poll interval without exceeding it by more than a small factor,
and this shall be validated at startup rather than discovered in production.

**R-7** Telemetry shall **not** be written to disk. It is recoverable in full from
§4.3 at any later date (measured: three weeks, complete, 2.4 s). The analysis
re-fetches it by `serial`.

> This reverses the previous requirement to retain every frame. It removes ~9.8 MB
> per flight — ~99% of the volume — and loses nothing, because unlike predictions,
> telemetry is not one-shot.

### 5.2 Burst detection

**R-8** The program shall detect burst from the live telemetry stream, and shall
begin the prediction sweep at that moment.

Detection rule: current altitude below the running maximum by more than **300 m**,
with descent sustained across **≥3 consecutive deduplicated frames**. Where
`vel_v` is present it may corroborate (`< −3 m/s`); where it is absent (iMet) the
altitude condition alone governs.

> Hysteresis is required: frames arrive 1–2 s apart and altitude is noisy near
> apogee. `W4214540` burst at 36 178 m, 1 h 50 m after launch.

> **Telemetry polling begins at launch, not at burst.** Waking the collector at
> T+1.5 h would be sufficient for a normal flight, but a balloon that fails at
> 15 km around T+50 min is on the ground by T+70 min and would never be recorded.
> Those are the anomalous flights the dataset is short of. Telemetry polling is
> cheap; only the Tawhiri sweep is gated on burst.

### 5.3 Prediction sweep — the core requirement

**R-9** While a flight is descending, the program shall call Tawhiri **once per
rate** in a configurable sweep set, at a **two-phase cadence**:

| phase | interval |
|---|---|
| first 20 minutes after burst | **120 s** |
| thereafter until close | **300 s** |

Default sweep set: **2.0, 3.0, 4.0, 5.0, 7.0 m/s**, to be extended upward
(see below).

> **Measured — the first flight captured end to end broke the sweep set.**
> `W3821271` (Oberschleißheim, 2026-08-20) burst at **15 523 m, only 40 minutes
> after launch** — an early balloon failure — and was recorded from burst to loss
> of contact: 12 ticks, 60 prediction lines, no gaps.
>
> Its descent rate **roughly doubled at ~10.4 km**, from 7 m/s to 13 m/s over
> about 90 seconds, and stayed between 10 and 15 m/s to the ground. §8 warns that
> this signature can be a logging artifact; it is not. Frames are 1 s apart
> straight through the transition, the whole 1 400-frame descent contains only
> two intervals over 10 s (both near the ground, minutes later), and `vel_v`
> tracks the derived rate frame by frame. This is a parachute changing state in
> flight — the damage case §1 says the operator most wants to catch.
>
> Consequences:
>
> - **The sweep set did not cover it.** The implied sea-level rate ran 3.5–4.7 m/s
>   above 10 km, then left the swept range entirely below 8 km. Eight of twelve
>   ticks produced no bracketing pair. Extend the sweep upward.
> - **A single sea-level rate does not describe such a flight.** Fitting one
>   exponential gives R² = 0.18 and a *negative* scale height, because the chute
>   changed state partway down. Analysis must allow a flight to have a
>   before and an after, not one number.
> - **Waking at T+1.5 h would have missed this flight completely.** It burst at
>   T+40 min and was on the ground by T+66 min. This is why R-8 polls telemetry
>   from launch and gates only the sweep on burst.

> The transition being measured sits at roughly 8–12 minutes after burst, where a
> flat 5-minute cadence yields only samples at 5, 10 and 15 minutes — too coarse
> to distinguish "settles at 8" from "settles at 12". The dense phase covers the
> window where the answer lives; the tail changes slowly.

Budget at defaults: ~17 ticks × 5 rates ≈ 85 calls per flight; ~2 000 per day
across 12 stations. No ascent-phase predictions are made (the previous R-9 ascent
baseline is dropped — ascent is out of scope per §3).

> **Measured — the sonde is not at terminal velocity when the sweep starts.**
> `W3960661` burst at 33 508 m while still *ascending at +5 m/s*, and took about
> 90 seconds to accelerate downward: −40.0 m/s at 0.5 min (32.9 km), peaking at
> **−50.8 m/s at 1.5 min** (30.2 km), then slowing to −39.6 and −35.0 as the air
> thickened. All 41 receiving stations agreed to within ±7 m, so this is the real
> trajectory, not a reporting artifact.
>
> Consequence for the analysis: `vz_real` from the first minute or two after burst
> describes an accelerating body, not a terminal-velocity descent, so matching it
> against `vz_pred` there is meaningless. The first tick of `W3960661` implied a
> sea-level rate of 3.64 m/s and the second 6.54 — the first was taken mid-
> acceleration. Ticks before terminal velocity is reached must be identifiable and
> excludable, which `tb` and `vz_real` together already allow. The collector still
> records them: excluding data is the analysis's decision, not the collector's (§8).

**R-10** Every prediction shall be recorded as one line carrying **exactly** the
fields in §6.2 — including `dataset`, `vz_pred`, `vz_real` and `vz_alt`.

- `dataset` — the GFS run epoch from `request.dataset`. **Without it, a landing
  point that jumps between consecutive ticks cannot be distinguished from a wind
  model that changed underneath you.** The run that was live is unrecoverable.
- `vz_real` — the sonde's observed descent rate at the moment of the call, as the
  median over the trailing 30 s of frames.
- `vz_pred` — Tawhiri's own descent rate at the same altitude, derived from the
  response trajectory's altitude/time.

> The `vz_pred`/`vz_real` pair is the instrument for §4.4's scale-height
> discrepancy: two floats per line that record, at every altitude of every flight,
> how fast Tawhiri thinks the sonde is falling versus how fast it is actually
> falling.

**R-11** The sonde's altitude, latitude, longitude and timestamp **at the moment
of the call** shall be recorded on the same line, so the analysis never has to
infer where the sonde was.

**R-12** The full response trajectory shall **not** be stored — only the landing
point and `vz_pred` extracted from it.

> Creep is movement of the landing point; the intermediate trajectory does not
> contribute. Tawhiri's descent-rate-versus-altitude curve is model-internal and
> can be probed synthetically at any time, so retaining it per-tick buys nothing.

### 5.4 Being a good citizen

**R-13** SondeHub and Tawhiri are free community services. The program shall:
- send a descriptive `User-Agent` identifying the program and a contact address;
- serialise requests with a minimum spacing (default 1 s) rather than bursting;
- respect HTTP 429 and `Retry-After`, backing off exponentially;
- enforce a configurable daily request ceiling (default 5 000) and log loudly on
  reaching it rather than continuing.

At ~2 000 calls/day the existing 5 000 ceiling retains its purpose: catching a
runaway loop, not throttling normal operation.

### 5.5 Robustness

**R-14** The program shall survive restart without losing active flights: state is
reconstructed from what is already on disk plus a fresh station poll, and missed
ticks are repaired per **R-17** (stated in §2, where the time window it depends on
is established).

**R-15** Any API failure shall be logged with its cause and retried with backoff.
A failed call shall never terminate the program or abandon a flight.

**R-16** Every write shall be atomic (write to a temporary file, then rename), so
a crash mid-write cannot corrupt a flight record.

**R-18** All timestamps shall be stored in **UTC**, ISO 8601, with the source
field named explicitly. Mixing local and UTC across this dataset would be fatal
to the analysis and hard to detect.

---

## 6. Output

### 6.1 Layout

```
data/
  <serial>_<launch-date>/
    meta.json          flight identity, lifecycle, burst point, last_heard
    predictions.jsonl  one line per (tick, rate)
```

There is no `telemetry.jsonl`. Per R-7 the track is re-fetched from §4.3 by
`serial` whenever the analysis wants it.

One directory per flight, so a flight can be copied or deleted whole. JSON Lines
because it is append-only, survives truncation, and streams. Uncompressed —
at this volume there is nothing to gain by compressing.

**Volume:** ~85 lines × ~140 B ≈ **12 kB per flight**, plus ~1 kB of `meta.json`.
Across 12 stations: **~10 MB/month, ~120 MB/year.**

### 6.2 `predictions.jsonl` record

```json
{"t":"2026-08-20T13:00:00Z","tb":9.3,"rate":3.0,
 "alt":22700,"lat":47.31,"lon":7.50,
 "plat":47.1873,"plon":7.7979,
 "vz_real":-16.55,"vz_pred":-12.30,
 "dataset":"2026-08-20T06:00:00Z","repaired":false}
```

| field | meaning |
|---|---|
| `t` | time of the Tawhiri call, UTC |
| `tb` | minutes since burst |
| `rate` | the swept `descent_rate` for this call |
| `alt`,`lat`,`lon` | sonde state at the moment of the call (R-11). `lat`/`lon` are recoverable from re-fetched telemetry, but are stored anyway: modelling the quantisation floor of §4.4 needs the exact input position that produced this prediction. |
| `plat`,`plon` | **predicted landing point** — the measurement |
| `vz_real` | observed descent rate, median over trailing 30 s |
| `vz_pred` | Tawhiri's descent rate at the same altitude |
| `dataset` | GFS dataset epoch, verbatim from the response's `request.dataset` (R-10) |
| `repaired` | true if issued after the fact (R-17) |

### 6.3 `meta.json`

Flight identity and lifecycle. Shall include `serial`, `type` (RS41 / iMet / …),
`station`, `launch_datetime`, `burst_datetime`, `burst_altitude`, burst lat/lon,
`last_heard` (R-4), and counts of frames seen and gaps observed.

> `type` and station metadata come from the station listing (§4.1) and exist
> nowhere else in the record. Whether the descent profile varies **by sonde type**
> is a question the statistics will want to ask, and this is the only place the
> answer is retained.

> **Measured — `vel_v` is not an independent measurement.** Across 3 141 descent
> frames of `W4214540`, reported `vel_v` and derived Δalt/Δt differ by a median of
> **−0.012 m/s** (mean −0.005, sd 0.62; |diff| p90 = 0.86). They are the same
> quantity: `vel_v` is the finite difference of GPS altitude. The iMet's missing
> `vel_v` therefore costs nothing — but neither can one be used to sanity-check
> the other, and a bad altitude fix corrupts both identically.

> **Measured — single-frame rates are unusable raw.** The 0.62 m/s sd on 1-second
> intervals is the noise floor. `vz_real` must be smoothed (R-10 specifies a 30 s
> trailing median). Frame cadence on `W4214540` was 1 s median, max gap 8 s, with
> **zero** intervals over 60 s.

> **Measured — an interval is only meaningful within one uploader's stream.**
> A radiosonde transmits **one packet per second**, so no genuine interval is
> shorter than that. Yet the merged telemetry contains intervals of 3 ms:
>
> ```
> 2026-08-20T16:30:08.997000Z  alt = 15079.3     (uploader A, ms precision)
> 2026-08-20T16:30:09.000Z     alt = 15072.6     (uploader B, whole second)
> ```
>
> These are two **distinct, consecutive** packets — the 10 m step is 0.77 s of
> real flight at 13 m/s — whose timestamps came from receivers that disagree on
> precision. Dozens of stations report one flight: `W3821271` had **26 uploaders**,
> and a single 1-minute live window for `W3960661` held frames from **22**.
>
> The decisive measurement: **every individual uploader had 0.0% sub-0.5 s
> intervals; the merged stream had 5.0%.** The artifact is created by merging, not
> by any receiver. Rates shall therefore be computed **within one uploader's
> stream** and never across two, with a 0.5 s minimum as a backstop.
>
> Frames from all uploaders are still merged for coverage, because no single
> station sees the whole flight: on `W3821271`, `NO_CALLSIGN` followed it down to
> 1 114 m while `WBGS-4` stopped at 5 019 m.
>
> Scale of the error, honestly: a 30 s trailing median already absorbs 5% bad
> intervals — on this flight merged and per-uploader medians agree to within
> 0.3 m/s, and the values actually recorded were sound. This requirement removes
> the dependence on that margin rather than correcting an observed fault.

> **Descent rate varies by more than 6× within a single descent** — `W4214540`
> fell at 30.8 m/s at 36 km and 5.2 m/s at 2 km. Any single "the descent rate of
> this flight" figure is meaningless unless the altitude it applies to is stated.
> This is why `vz_real` is stored per tick and never summarised.

---

## 7. What the dataset must be able to answer

Implementation is complete when the recorded data can answer all of these without
further collection:

1. For a given flight, **how far and in which direction the predicted landing
   point moves between consecutive ticks**, per swept rate, as a function of time
   since burst. Direction is essential, not decorative: it is what separates a
   real drift from the ~100–150 m quantisation floor (§4.4). Both distance and
   bearing are derived offline from consecutive `plat`/`plon` pairs — the collector
   stores the positions and computes neither.
2. **Which swept rate's prediction stops moving first**, and at what time after
   burst — the rate whose successive predictions agree is the rate that was right,
   and this is determinable in flight without ever observing a landing.
3. **How early** a slow or fast chute becomes distinguishable from a normal one.
   This requires normal flights as controls, so it must record everything, not
   only anomalies.
4. Whether **Tawhiri's modelled descent rate matches the sonde's actual** at the
   same altitude, across many flights and sonde types — the `vz_pred`/`vz_real`
   comparison. If it does not, creep has a structural cause that no `descent_rate`
   can correct, and that changes what the app should do.
5. What the **distribution** of implied sea-level descent rates looks like across
   many flights — which is what the plausible range (§1) should be set from.
6. How large a **single-tick correction** ever legitimately needs to be — which is
   what the step cap (§1) should be set from.
7. How much **accumulated fall** is required before a correction becomes stable —
   which is what the minimum-drop threshold (§1) should be set from.

Items 5, 6 and 7 each replace one of the three guessed constants in §1. Items 1–4
answer the question in §1 that the existing data cannot.

---

## 8. Non-requirements

The program shall **not**:

- decide anything about parachute behaviour, or fit any model. It records;
  conclusions come later, from statistics over many flights.
- discard data it judges uninteresting. The controls are the point.
- modify, upload to, or otherwise interact with SondeHub beyond reading.
- assume a flight is normal because nothing looks wrong. An earlier analysis
  identified a "partially opened parachute" that turned out to be a logging
  artifact — sparse samples across a gap inflating an apparent rate. Sampling
  gaps must be visible in the output, not smoothed away: `meta.json` records gap
  counts, and a tick with no telemetry behind it is written with a null `vz_real`
  rather than a stale one.
