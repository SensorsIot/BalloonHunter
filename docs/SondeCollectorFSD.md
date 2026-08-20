# Functional Specification: Radiosonde Descent Collector

**Status:** draft for implementation
**Audience:** the agent implementing this program. You are not expected to have
seen the BalloonHunter app or this conversation.

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
guesses**, and to answer one question the existing data cannot:

> How early in a descent can a slow or partially-opened parachute be told apart
> from a normal one, and with what confidence?

The evidence available today is two flights and one control. Across those, the
corrected estimates for a slow chute and a normal one were **indistinguishable
5–10 minutes after burst** (3.46 vs 3.68 m/s) and separated only after roughly
20–25 minutes. That is not enough to set a threshold on.

---

## 2. What the program does

Runs unattended on a VM. Watches for radiosonde flights, records their telemetry,
and — while each one is descending — repeatedly asks Tawhiri where it will land
**using several different descent rates at once**.

After the sonde is down, its true landing position is known. Because several
rates were tried at every moment of the descent, the recording shows directly
**which descent rate would have predicted the truth**, at each altitude, at each
minute. That is the label the analysis needs and cannot be reconstructed later.

### Why predictions must be captured live

Telemetry can be replayed from SondeHub at any time; the descent profile is
recoverable whenever you like. **Tawhiri's wind forecasts are not.** They are
versioned and improve retrospectively, so asking Tawhiri next month what it would
have predicted yields an answer informed by winds nobody had at the time. That
answers the wrong question. The app can only ever act on the forecast available
while the balloon is in the air, so that is what must be captured.

---

## 3. Scope

**In scope**

- Sondes launched from or passing near Payerne, Switzerland (SondeHub station
  `06610`), which is the operator's hunting ground.
- The full flight: ascent, burst, descent, landing.
- Any sonde type the station launches (RS41 predominantly; also iMet, which
  reports no vertical velocity — see §6.3).

**Out of scope**

- Any interaction with the BalloonHunter iOS app. This program is standalone.
- Real-time alerting, dashboards, or a UI. It writes files.
- Analysis. It gathers; conclusions are drawn separately from what it wrote.

**Deliberately unresolved — ask the operator before implementing**

1. **Station scope.** Payerne only, or a radius covering neighbouring stations?
   More stations means faster data and more parachute variety, at higher API cost.
2. **Retention.** Full telemetry is roughly 9 MB per flight from SondeHub; Payerne
   launches twice daily, so about 0.5 GB per month. Keep everything, or downsample
   once a flight closes?
3. **Output destination.** Files on the VM to be pulled periodically, or pushed
   somewhere?

---

## 4. External interfaces

### 4.1 SondeHub — station listing

```
GET https://api.v2.sondehub.org/sondes/site/06610
```

Returns a JSON object keyed by **sonde serial**, each value carrying at minimum:
`serial`, `type`, `datetime` (ISO 8601), `lat`, `lon`, `alt`, `vel_h`, `vel_v`,
`frequency`, `tx_frequency`, `uploader_position`.

> **`vel_v` and `vel_h` are optional.** iMet sondes omit them. A decoder that
> requires them fails to parse the entire response — this exact bug hid three
> live sondes from the app.

### 4.2 SondeHub — flight telemetry

```
GET https://api.v2.sondehub.org/sonde/{serial}
```

Returns a JSON **array** of frames. Responses are **gzip-encoded regardless of
request headers** and must be decompressed explicitly; a naive UTF-8 decode fails
at byte 1. Expect 250 000–350 000 frames and roughly 9 MB per completed flight,
containing heavy duplication — deduplicate on `datetime`.

Frame fields include: `datetime`, `lat`, `lon`, `alt`, `frame`, `batt`,
`burst_timer`, `frequency`, `manufacturer`, `launch_site`.

> The outer key of the newer telemetry endpoint is the **serial**. Merging
> several serials into one flight is a real hazard — verify every frame belongs
> to the sonde being recorded.

### 4.3 Tawhiri — landing prediction

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
longitude, altitude}]}]` with stages `ascent` and `descent`.

**Verified behaviour — do not re-derive:** Tawhiri **models atmospheric density
itself**. Its `descent_rate` is a **sea-level terminal velocity**, not the rate a
sonde is observed falling at. Measured across releases from 3 000–30 000 m, its
flight time is 0.44–0.84 of the naive `altitude / rate`, implying a velocity scale
height near **15 500 m** above 12 km. Feeding it a rate observed at altitude
therefore over-states the descent, because it scales an already-scaled figure.

---

## 5. Requirements

### 5.1 Flight lifecycle

**R-1** The program shall poll the station listing at a configurable interval
(default 60 s) and treat each unseen serial as a new flight.

**R-2** A flight shall be considered **active** from first sighting until it is
closed by R-3.

**R-3** A flight shall be closed when **either**: no new telemetry frame has
appeared for a configurable timeout (default 30 min), **or** its altitude has
been below 1 000 m and changed by less than 50 m for 10 consecutive minutes.

**R-4** On closing a flight, the program shall record the **final resting
position** — the last frame's latitude, longitude, altitude and timestamp — as a
distinct field. This is the ground truth every prediction is scored against.

**R-5** The program shall handle **concurrent flights**. Payerne launches roughly
twice daily and flights last ~3 h, so overlap is normal.

### 5.2 Telemetry recording

**R-6** For each active flight, telemetry shall be fetched at a configurable
interval (default 30 s) and appended to that flight's record, deduplicated on
`datetime`.

**R-7** Every frame shall be stored **as received**, with no fields dropped. What
is discarded now cannot be recovered.

### 5.3 Prediction sweep — the core requirement

**R-8** While a flight is **descending** (altitude falling over the last three
samples), the program shall call Tawhiri at a configurable interval (default
120 s), **once per rate** in a configurable sweep set.

Default sweep: **2.0, 3.0, 4.0, 5.0, 7.0 m/s**, spanning the observed slow chute
at ~2 and a normal one at ~5. Consider adding 10.0 if the operator confirms
genuinely fast failures occur.

**R-9** While a flight is **ascending**, predictions shall be made at a longer
interval (default 600 s) with a single rate (default 5.0). Ascent is not the
subject of study, but a pre-burst baseline is cheap and useful.

**R-10** Every prediction shall be recorded with **its full request parameters,
the timestamp of the call, and its complete response trajectory**. A prediction
whose inputs were not recorded is not evidence.

**R-11** The sonde's actual altitude, latitude, longitude and timestamp **at the
moment of the call** shall be recorded alongside each prediction, so the analysis
never has to infer where the sonde was.

### 5.4 Being a good citizen

**R-12** SondeHub and Tawhiri are free community services. The program shall:
- send a descriptive `User-Agent` identifying the program and a contact address;
- serialise requests with a minimum spacing (default 1 s) rather than bursting;
- respect HTTP 429 and `Retry-After`, backing off exponentially;
- enforce a configurable daily request ceiling (default 5 000) and log loudly on
  reaching it rather than continuing.

Budget at defaults: ~40 descent ticks × 5 rates ≈ 200 Tawhiri calls per flight,
~400/day at two flights. Comfortably under the ceiling; the ceiling exists to
catch a runaway loop.

### 5.5 Robustness

**R-13** The program shall survive restart without losing active flights: state is
reconstructed from what is already on disk plus a fresh station poll.

**R-14** Any API failure shall be logged with its cause and retried with backoff.
A failed call shall never terminate the program or abandon a flight.

**R-15** Every write shall be atomic (write to a temporary file, then rename), so
a crash mid-write cannot corrupt a flight record.

**R-16** All timestamps shall be stored in **UTC**, ISO 8601, with the source
field named explicitly. Mixing local and UTC across this dataset would be fatal
to the analysis and hard to detect.

---

## 6. Output

### 6.1 Layout

```
data/
  <serial>_<launch-date>/
    meta.json          flight identity, lifecycle, final resting position
    telemetry.jsonl    one frame per line, as received, deduplicated
    predictions.jsonl  one prediction per line: request, response, sonde state
```

One directory per flight, so a flight can be copied or deleted whole.
JSON Lines because it is append-only, survives truncation, and streams.

### 6.2 `predictions.jsonl` record

Every line shall carry, at minimum:

```json
{
  "called_at": "2026-07-31T13:10:00Z",
  "sonde_state": {"lat": 47.31, "lon": 7.50, "alt": 28450.0, "datetime": "..."},
  "phase": "descent",
  "request": {"descent_rate": 3.0, "launch_altitude": 28450.0,
              "burst_altitude": 28460.0, "ascent_rate": 5.0, "...": "..."},
  "response": {"landing": {"lat": 47.80, "lon": 8.31, "datetime": "..."},
               "trajectory": [{"datetime": "...", "altitude": 28450.0,
                               "latitude": 47.31, "longitude": 7.50}]}
}
```

### 6.3 Derived fields — compute, never assume

The program **may** compute these into `meta.json` on closing a flight, but shall
always retain the raw data they came from:

- **Burst point**: index and altitude of maximum altitude.
- **Descent rate by altitude band**: median instantaneous rate per 1 km band.
  Compute from consecutive frames, discarding intervals over 60 s and rates
  outside 0.3–80 m/s.

> **Descent rate varies by more than 13× within a single descent** — one flight
> measured 30.9 m/s at 32 km and 2.3 m/s at 2 km. Any single "the descent rate of
> this flight" figure is meaningless unless the altitude it applies to is stated.

- **Best rate per prediction tick**: of the swept rates, the one whose predicted
  landing fell closest to the true resting position. **This is the label the
  whole exercise exists to produce.**

> A sonde reporting no vertical velocity is **undetermined, not landed**. Never
> let a missing `vel_v` collapse into an assumption of zero.

---

## 7. What the dataset must be able to answer

Implementation is complete when the recorded data can answer all of these without
further collection:

1. For a given flight, at each minute of descent, **which swept rate would have
   predicted the true landing** — and how far the others were wrong.
2. **How early** a slow or fast chute becomes distinguishable from a normal one,
   and with what separation. This requires normal flights as controls, so it must
   record everything, not only anomalies.
3. What the **distribution** of true sea-level descent rates looks like across
   many flights — which is what the plausible range should be set from.
4. How large a **single-tick correction** ever legitimately needs to be, which is
   what the step cap should be set from.
5. How much **accumulated fall** is required before the ratio between actual and
   predicted drop becomes stable, which is what the minimum-drop threshold should
   be set from.

Items 3, 4 and 5 each replace one of the three guessed constants in §1.

---

## 8. Non-requirements

The program shall **not**:

- decide anything about parachute behaviour. It records; conclusions come later.
- discard data it judges uninteresting. The controls are the point.
- modify, upload to, or otherwise interact with SondeHub beyond reading.
- assume a flight is normal because nothing looks wrong. An earlier analysis
  identified a "partially opened parachute" that turned out to be a logging
  artifact — sparse samples across a gap inflating an apparent rate. Sampling
  gaps must be visible in the output, not smoothed away.
