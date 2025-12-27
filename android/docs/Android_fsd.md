# Android Functional Specification Document (FSD)

This document specifies the Android app that must match the implemented iOS BalloonHunter functionality. The iOS codebase is the source of truth; follow the behaviors below even if they differ from older FSDs.

Target: Android native (Kotlin, Jetpack, Google APIs only). No third-party SDKs beyond Android/Google/Jetpack libraries.
Exception: allow OpenStreetMap as an optional user-selectable map/routing backend.

---

## 1) Product Summary

BalloonHunter is a single-screen, map-centric app to track weather balloons in real time. Telemetry is received via BLE from a MySondyGo device. When BLE telemetry is missing, the app falls back to SondeHub APRS data. The app shows the live balloon position, historical track, predicted trajectory, and navigation route to the landing site. It also exposes device configuration via BLE and prediction parameters.

Key constraints from iOS implementation:
- Single main map screen with a compact data panel below.
- BLE is the authoritative data source when Type 1 telemetry is active.
- APRS is a fallback and also used to fill track gaps.
- Predictions run every 60 seconds only when the balloon is flying.
- Background behavior: BLE-only. No APRS polling, no predictions, no routing, no location updates.

---

## 2) Android Architecture (Best-in-class, Google-only)

### 2.1 Tech stack
- Kotlin, Coroutines, Flow/StateFlow
- Jetpack Compose for UI
- Single-activity architecture with Compose navigation
- Hilt for DI (Google)
- Room or DataStore for persistence (use DataStore for settings, Room or JSON for track/landing data)
- Google Maps SDK for map rendering (Option A)
- Google Play Services Location (FusedLocationProviderClient)
- Android Bluetooth LE APIs
- NotificationManager + notification channels
Optional (Option B): OpenStreetMap stack for map/routing (see Section 11.3).
Target SDK: latest at ship (2026 best practice). Min SDK: 26.

### 2.2 Module layout (recommended)
- app
- data
  - ble
  - aprs
  - prediction
  - routing
  - persistence
- domain
  - models
  - state machine
  - services
- presentation
  - Map screen
  - Settings screens

### 2.3 State ownership
- Each service exposes a StateFlow for its published state.
- MapPresenter equivalent subscribes to service flows and exposes UI state.
- The state machine is centralized in BalloonPositionService and drives service activation.

---

## 3) Core Models (Mirror iOS fields and types)

### 3.1 Enums
- TransportationMode: car, bike
- BalloonPhase: ascending, descendingAbove10k, descendingBelow10k, landed, unknown
- TelemetrySource: ble, aprs
- BLEConnectionState: notConnected, readyForCommands, dataReady
- DataState: startup, liveBLEFlying, liveBLELanded, waitingForAPRS, aprsFlying, aprsLanded, noTelemetry
- LandingPredictionSource: sondehub, manual

### 3.2 Data classes
- PositionData
  - sondeName: String
  - latitude, longitude, altitude: Double
  - verticalSpeed, horizontalSpeed: Double
  - heading: Double (always 0 from BLE/APRS)
  - temperature, humidity, pressure: Double (APRS only may supply; BLE uses 0)
  - timestamp: Date
  - apiCallTimestamp: Date? (APRS only)
  - burstKillerTime: Int
  - telemetrySource: TelemetrySource

- RadioChannelData
  - sondeName: String
  - timestamp: Date
  - telemetrySource: TelemetrySource
  - probeType: String
  - frequency: Double
  - softwareVersion: String
  - batteryVoltage: Double
  - batteryPercentage: Int
  - signalStrength: Int
  - buzmute: Boolean
  - afcFrequency: Int
  - burstKillerEnabled: Boolean
  - burstKillerTime: Int

- SettingsData (Type 3 only)
  - sondeName: String (unused, keep empty)
  - timestamp: Date
  - telemetrySource: TelemetrySource
  - oledSDA, oledSCL, oledRST, ledPin, RS41Bandwidth, M20Bandwidth, M10Bandwidth, PILOTBandwidth, DFMBandwidth: Int
  - frequencyCorrection: Int
  - batPin, batMin, batMax, batType: Int
  - lcdType, nameType, buzPin: Int
  - callSign: String
  - bluetoothStatus, lcdStatus, serialSpeed, serialPort, aprsName: Int

- LocationData
  - latitude, longitude, altitude: Double
  - horizontalAccuracy, verticalAccuracy: Double
  - heading: Double
  - timestamp: Date

- BalloonTrackPoint
  - latitude, longitude, altitude: Double
  - timestamp: Date
  - verticalSpeed, horizontalSpeed: Double

- BalloonMotionMetrics
  - rawHorizontalSpeedMS, rawVerticalSpeedMS: Double
  - smoothedHorizontalSpeedMS, smoothedVerticalSpeedMS: Double
  - adjustedDescentRateMS: Double?

- PredictionData
  - path: List<LatLng>?
  - burstPoint: LatLng?
  - landingPoint: LatLng?
  - landingTime: Date?
  - launchPoint: LatLng?
  - burstAltitude: Double?
  - flightTime: Double? (unused)
  - metadata: Map<String, Any>? (unused)
  - usedSmoothedDescentRate: Boolean

- LandingPredictionPoint
  - latitude, longitude: Double
  - predictedAt: Date
  - landingEta: Date?
  - source: LandingPredictionSource
  - distance(other): meters

- RouteData
  - coordinates: List<LatLng>
  - distance: Double (meters)
  - expectedTravelTime: Double (seconds)
  - transportType: TransportationMode

---

## 4) BLE (MySondyGo) Service

### 4.1 UUIDs
- Service UUID: 53797269-614D-6972-6B6F-44616C6D6F6E
- TX characteristic (write): 53797268-614D-6972-6B6F-44616C6D6F7E
- RX characteristic (notify): 53797267-614D-6972-6B6F-44616C6D6F8E

### 4.2 Scan and connect behavior
- Scan for peripherals advertising the UART service UUID.
- Prefer devices whose name contains "MySondy".
- On discovery, stop scanning and connect.
- On disconnect, immediately restart scanning.
- Scan timeout: 5 seconds. If not found, stop scan, wait 10 seconds, then retry (if still not connected).

### 4.3 Connection state logic
- On BLE connection, do not mark ready until first valid packet arrives.
- When first valid packet arrives: connectionState -> readyForCommands.
- When a Type 1 packet arrives: connectionState -> dataReady.
- When in dataReady and only non-Type-1 packets arrive, downgrade to readyForCommands if no Type 1 in last 10 seconds.
- Additional periodic staleness check every 3 seconds: if no Type 1 telemetry for >30 seconds, downgrade to readyForCommands.
- lastMessageTimestamp updates on every BLE packet.

### 4.4 Message framing
- The iOS implementation assumes each BLE notification is a complete message string.
- Messages are split by "/"; no explicit reassembly or buffer handling is used.

### 4.5 Packet parsing (mirror iOS mapping exactly)

Type 0: Device status
Format: 0/probeType/frequency/RSSI/batPercentage/batVoltage/buzmute/softwareVersion/o
- probeType: components[1]
- frequency: components[2]
- rssi: components[3] (normalize to negative if positive)
- batteryPercentage: components[4]
- batteryVoltage: components[5]
- buzmute: components[6] ("1" -> true)
- softwareVersion: components[7]
Behavior:
- Emit RadioChannelData only (no PositionData)
- Update radioSettings (probeType + frequency)
- Update AFC data with afcFrequency=0

Type 1: Probe telemetry (position)
Format: 1/probeType/frequency/sondeName/lat/lon/alt/hSpeed/vSpeed/RSSI/batPercentage/afcFrequency/burstKillerEnabled/burstKillerTime/batVoltage/buzmute/reserved1/reserved2/reserved3/softwareVersion/o
Indexes used:
- probeType [1], frequency [2], sondeName [3]
- latitude [4], longitude [5], altitude [6]
- horizontalSpeed [7], verticalSpeed [8]
- rssi [9], batteryPercentage [10]
- afcFrequency [11]
- burstKillerTime [13]
- batteryVoltage [14]
- buzmute [15]
- softwareVersion [19]
Validation:
- Reject if frequency <= 0, probeType empty, lat/lon invalid, or lat/lon == 0
Behavior:
- Emit PositionData and RadioChannelData
- Update radioSettings (probeType + frequency)
- Set lastTelemetryUpdateTime = now

Type 2: Partial telemetry (no position)
Format: 2/probeType/frequency/sondeName/RSSI/batPercentage/afcFrequency/batVoltage/buzmute/softwareVersion/o
Indexes used:
- probeType [1], frequency [2], sondeName [3]
- rssi [4], batteryPercentage [5]
- afcFrequency [6], batteryVoltage [7]
- buzmute [8], softwareVersion [9]
Behavior:
- Emit RadioChannelData only
- Update radioSettings
- Do NOT emit position

Type 3: Device configuration (note mapping matches iOS implementation)
Format: 3/probeType/frequency/oledSDA/oledSCL/oledRST/ledPin/RS41BW/M20BW/M10BW/PILOTBW/DFMBW/frequencyCorrection/callSign/batPin/batMin/batMax/batType/lcdType/nameType/buzPin/softwareVersion/o
Indexes used (iOS behavior):
- oledSDA [3], oledSCL [4], oledRST [5], ledPin [6]
- RS41BW [7], M20BW [8], M10BW [9], PILOTBW [10], DFMBW [11]
- frequencyCorrection [12]
- callSign [13]
- batPin [14], batMin [15], batMax [16], batType [17]
- lcdType [18], nameType [19], buzPin [20]
- softwareVersion [21]
Behavior:
- Emit SettingsData only
- Do NOT change radioSettings from Type 3

### 4.6 Radio settings conversion
- Frequency digits: 5 digits for XXX.XX (e.g., 403.50 -> [4,0,3,5,0])
- Validation:
  - digit0 must be 4
  - digit1 must be 0
  - digit2 0..6
  - digit3 0..9 (but if 406 then must be 0)
  - digit4 0..9 (but if 406.0 then must be 0)

### 4.7 AFC smoothing
- Maintain a history of last 10 afcFrequency values.
- Publish AFCData(currentFrequency, smoothedFrequency = average of history).

### 4.8 Commands
All commands must be sent as ASCII strings wrapped in o{...}o.
- Request status: o{?}o
- Set frequency: o{f=403.50/tipo=1}o
- Mute: o{mute=0|1}o
- Settings (individual): o{key=value}o

Device settings diff logic (used by Device Settings screen) uses these keys:
- oled_sda, oled_scl, oled_rst, led_pout, buz_pin
- battery, vBatMin, vBatMax, vBatType
- oled (lcdType), name (nameType)
- bt (bluetoothStatus), lcd (lcdStatus)
- serBaud (serialSpeed index), ser (serialPort)
- call (aprsName)

Note: These keys match the iOS implementation even if they differ from earlier docs.

---

## 5) APRS (SondeHub) Service

### 5.1 Endpoints
- Site endpoint: https://api.v2.sondehub.org/sondes/site/{stationId}
- Telemetry endpoint (gap fill): https://api.v2.sondehub.org/sondes/telemetry?serial={serial}&duration=3d

### 5.2 Station ID
- Stored as a string (default "06610").
- Updating station ID restarts polling if active.

### 5.3 Polling
- Start polling when state machine requires APRS.
- Immediate fetch, then a repeating timer.
- Cadence adjusts based on data age:
  - age <= 120s -> 15s
  - age <= 1800s -> 300s
  - age > 1800s -> 3600s
- Site endpoint timeout: 5 seconds.
- Telemetry endpoint timeout: 30 seconds.

### 5.4 Data selection
- Filter out ground test sondes:
  - If uploader_position available, compute distance between sonde and uploader.
  - If distance < 1000 m, ignore that sonde.
- Select the most recent sonde by timestamp.

### 5.5 APRS conversion to PositionData/RadioChannelData
- Use effectiveFrequency = tx_frequency ?? frequency ?? 0
- Frequency rounded to 2 decimals.
- Validate coordinates (finite, abs <= 90/180, not (0,0)).
- Telemetry timestamp parsed from ISO8601 (with and without fractional seconds).
- PositionData.telemetrySource = aprs
- RadioChannelData.telemetrySource = aprs
- SoftwareVersion = "APRS"
- Battery/signal/AFC/burstKiller are 0/false (not available).

### 5.6 APRS status
- aprsDataAvailable = true after successful conversion.
- aprsDataAvailable set to false when connectionStatus becomes failed.

### 5.7 Gap fill
- Fetch telemetry points from the telemetry endpoint (duration=3d).
- Deduplicate by rounding timestamps to the nearest second.
- Insert APRS points only if the second-slot is empty.
- Maintain chronological order.

---

## 6) State Machine (BalloonPositionService)

### 6.1 Inputs
- bleConnectionState.hasTelemetry
- aprsDataAvailable
- balloonPhase
- startupComplete flag

### 6.2 States
- startup
- liveBLEFlying
- liveBLELanded
- waitingForAPRS
- aprsFlying
- aprsLanded
- noTelemetry

### 6.3 Transitions (mirror iOS)
- startup: remain until startupComplete; then
  - if BLE telemetry and landed -> liveBLELanded
  - if BLE telemetry -> liveBLEFlying
  - if APRS data and landed -> aprsLanded
  - if APRS data -> aprsFlying
  - else noTelemetry
- liveBLEFlying/liveBLELanded:
  - if BLE telemetry lost -> waitingForAPRS
  - else liveBLEFlying/liveBLELanded based on balloonPhase
- waitingForAPRS:
  - if BLE telemetry returns -> liveBLEFlying/liveBLELanded
  - if APRS data arrives -> aprsFlying/aprsLanded
  - if >10s without APRS -> noTelemetry
- aprsFlying:
  - if BLE telemetry returns -> liveBLEFlying
  - if balloonPhase becomes landed -> aprsLanded
  - if APRS data missing -> noTelemetry
- aprsLanded:
  - if BLE telemetry returns -> liveBLELanded or liveBLEFlying
  - if balloonPhase not landed -> aprsFlying
  - if APRS data missing -> noTelemetry
- noTelemetry:
  - if BLE telemetry and landed -> liveBLELanded
  - if BLE telemetry -> liveBLEFlying
  - if APRS data and landed -> aprsLanded
  - if APRS data -> aprsFlying

### 6.4 State entry behavior
- startup/noTelemetry: enable APRS polling
- liveBLEFlying: stop APRS polling; trigger prediction once; predictions also driven by 60s timer
- liveBLELanded: stop APRS; set landing point to current position
- waitingForAPRS: start APRS polling
- aprsFlying: enable APRS; trigger prediction; fill track gaps
- aprsLanded: enable APRS; set landing point; fill track gaps

---

## 7) Balloon Phase and Landing Detection

### 7.1 Track-based landing detection (high priority)
- If trackBasedLandingDetected is true, balloonPhase = landed (always).

### 7.2 APRS age-based landing
- If telemetrySource is aprs and currentPosition.timestamp older than 120 seconds -> landed.

### 7.3 Net movement landing detection (BLE)
- Requires at least 5 track points.
- Use the last N points (N = min(20, available)).
- Compute net 3D displacement across window, divide by time window -> netSpeedMS.
- Landed if netSpeedMS < 0.83 m/s AND altitude < 3000 m.

### 7.4 BalloonPhase from vertical speed
- If verticalSpeed > 0 -> ascending
- If verticalSpeed < 0 -> descendingAbove10k or descendingBelow10k (threshold 10,000 m)
- Else -> unknown

---

## 8) Balloon Track Service

### 8.1 Track recording
- Record points only when state is NOT startup, waitingForAPRS, noTelemetry, or aprsLanded.
- Each point stores derived horizontal and vertical speeds when possible (based on previous point and timestamp).
- Slot-based insertion: only insert if the second-slot is empty.

### 8.2 Smoothed speeds
- Hampel filter window: 10
- Hampel k: 3.0
- Deadbands: horizontal < 0.2 m/s -> 0, vertical < 0.05 m/s -> 0
- EMA time constants: fast (3s), slow (25s horizontal, 30s vertical)
- smoothedHorizontalSpeed and smoothedVerticalSpeed use fast EMA.

### 8.3 Adjusted descent rate
- Use points from the last 60 seconds.
- Compute per-interval vertical rates, take median.
- Maintain a history of last 20 median rates and average -> adjustedDescentRate.
- If insufficient points, fallback to slow EMA vertical speed.

### 8.4 Track-based landing detection (gap or stationary)
- Minimum points: 10.
- Determine burst index (max altitude).
- Window size for 20-minute detection: max(10, 20min / avgPointInterval).
- Scenario A: telemetry gap > 20 minutes after burst -> landing at last point before gap; truncate track after it; send notification.
- Scenario B: stationary period after burst (lat/lon avg delta < 0.0001, altitude avg delta < 0.3) -> landing at that point; truncate track after it; send notification.

### 8.5 APRS gap fill
- Fetch telemetry data (duration=3d) for the current sonde.
- Insert only if second-slot is empty; preserve chronological order.
- After insertion, run track-based landing detection only if:
  - last packet age > 20 minutes (historical track), OR
  - forceDetection=true (foreground resume after background)

---

## 9) Prediction Service (Tawhiri via SondeHub)

### 9.1 Endpoint
https://api.v2.sondehub.org/tawhiri

### 9.2 Request parameters
- launch_latitude: position.latitude (4 decimals)
- launch_longitude: position.longitude (4 decimals)
- launch_datetime: now + 60s (ISO8601)
- ascent_rate: userSettings.ascentRate
- burst_altitude:
  - if verticalSpeed >= 0: max(userSettings.burstAltitude, currentAltitude + 100)
  - else: currentAltitude + 10
- descent_rate: effective descent rate (absolute)
- launch_altitude: currentAltitude
- profile=standard_profile
- format=json

### 9.3 Effective descent rate
- Use adjustedDescentRateMS only when balloonPhase == descendingBelow10k and adjustedDescentRateMS != 0.
- Otherwise use userSettings.descentRate.

### 9.4 Caching
- TTL 300 seconds
- Capacity 100 entries
- Key: sondeName + lat/lon rounded to 2 decimals + altitude rounded to 0 decimals + 5-minute time bucket

### 9.5 Scheduling
- Prediction timer runs every 60 seconds only in liveBLEFlying or aprsFlying.
- On entering flying states, trigger an immediate prediction.

### 9.6 Parsing
- Parse SondeHub response; extract ascent and descent trajectories.
- burstPoint = last point in ascent.
- landingPoint = last point in descent.
- landingTime parsed with fractional seconds if available.
- path = concatenation of all trajectory points.

### 9.7 Outputs
- PredictionData
- predictedLandingTimeString (HH:mm)
- remainingFlightTimeString (HH:mm, 00:00 if past)

---

## 10) Landing Point Tracking Service

- Stores landing history points, deduplicated if new point is within 25 m of last.
- On updateLandingPoint:
  - Set currentLandingPoint
  - Notify NavigationService for change alerts
  - Trigger route calculation
  - If source == prediction -> record in history
- Persist landing history immediately.

---

## 11) Routing

### 11.1 Route calculation (Google option)
- Use Google Directions API for actual routes.
- Prefer transportMode: car -> driving, bike -> bicycling (if supported by API).
- If route not available or API returns no route:
  - Try up to 10 random 500m destination shifts.
  - Then radial search at 300m, 600m, 1200m every 45 degrees.
  - If still no route, fallback to straight-line polyline and ETA using:
    - car speed 22.0 m/s
    - bike speed 4.2 m/s
- If bike mode and real route available, multiply ETA by 0.7.

### 11.2 Route updates
- Recalculate on transport mode change.
- Recalculate when user moved > 100m and > 60s since last route update.
- If user location unavailable, store destination and calculate when location arrives.

### 11.3 Optional OpenStreetMap backend (user selectable)
If the user selects the OSM option, replace Google Maps + Directions with an OSM-based stack:
- Map rendering: use an OSM map view (must be a permissive, stable Android library).
- Routing: use an open routing API (OSRM or GraphHopper) over HTTPS.
- Maintain identical UI/UX and routing fallbacks; if routing fails, use straight-line fallback.
- Note: this violates the Google-only constraint, so it is an explicit optional mode.

---

## 12) Location Service

- Uses FusedLocationProviderClient.
- Dual modes:
  - background mode (on-demand) for regular updates
  - precision mode for heading view (1-2s)
- Heading mode toggled from UI and switches to precision updates.
- requestCurrentLocation() used on startup and foreground resume.
- Calculates distanceToBalloon and isWithin200mOfBalloon using balloonDisplayPosition.

---

## 13) UI/UX

### 13.1 Main screen layout
- Top control strip (horizontal):
  - Settings button
  - Transport mode (car/bike segmented)
  - Show All button
  - Heading mode toggle
  - Mute toggle (visible only when BLE connected)
  - Navigation button (visible if landing point exists)
- Map area: ~70% height
- Data panel: ~30% height

### 13.2 Map overlays
- Balloon track: red polyline
- Prediction path: blue polyline (flying only)
- Route to landing: green polyline (when routeVisible)
- Landing history: purple polyline + purple dots
- Balloon marker: color by phase (green ascending, orange descendingAbove10k, red descendingBelow10k, purple landed)
- Burst marker: orange
- Landing marker: purple target
- User marker: runner icon (hidden in heading mode)

### 13.3 Camera behavior
- Show All fits all annotations, track, prediction, route, landing history.
- Heading mode: map follows user heading; interaction limited to zoom.
- Preserve zoom when toggling heading mode.
- Suspend camera updates while settings sheet is open.

### 13.4 Satellite toggle
- Toggle between normal and hybrid/satellite.

### 13.5 Distance overlay
- If balloon is landed, show distance-to-balloon at bottom overlay.

### 13.6 Sonde name mismatch banner
- If bleSerialName != aprsSerialName (both non-empty), show an orange banner.

---

## 14) Data Panel

Display grid values (placeholders in startup/noTelemetry):
- Row 1: Connection icon, Flight status icon, Probe type, Sonde name, Altitude
- Row 2: Frequency, Signal strength (dBm), Battery %
- Row 3: Vertical speed (m/s), Horizontal speed (km/h), Distance (km)
- Row 4: Flight time, Landing time, Arrival time
- Row 5: Descent rate (m/s) and Burst killer expiry time

Rules:
- Connection icon:
  - startup: gray antenna
  - liveBLE*: green antenna if BLE fresh, red if stale (>3s)
  - waitingForAPRS: red antenna if connected but no telemetry; red slash if not connected
  - aprs*: globe icon colored by APRS connection status (green connected, red failed, yellow connecting)
  - noTelemetry: red antenna or red slash depending on BLE state
- Flight status icons: target (landed), arrow up (ascending), arrow down (descending), question mark (unknown)
- Vertical speed uses smoothed metrics; color green if positive, red if negative.
- Descent rate shows 0.0 when not applicable; uses smoothedDescentRate if available else user setting.
- Burst killer time only available from BLE radio data (burstKillerTime). Display HH:mm or --:--.
- Arrival time is now + route ETA when route exists.

BLE icon flash:
- When new BLE message arrives and connectionState == dataReady, animate a brief scale flash.

---

## 15) Settings

### 15.1 Sonde Settings
- Probe type picker: RS41, M20, M10, PILOT, DFM
- Frequency digit picker (5 digits) with validation
- Save on dismiss: send BLE frequency command
- Revert button restores initial values

### 15.2 Device Settings
- Load on open:
  - Send o{?}o
  - Wait up to 5 seconds for response
  - If timeout, load cached settings if any
- Tabs: Pins, Battery, Radio, Other
- On close, compute diffs and send individual commands via BLE

### 15.3 Prediction Settings
- Burst altitude, ascent rate, descent rate, station ID
- Persist on dismiss

### 15.4 Tune AFC
- Show current and smoothed AFC values
- "Transfer" copies smoothed to new correction field
- Save sends o{freqofs=...}o and persists device settings

---

## 16) Notifications

- Navigation update: when landing point changes by >300m; notification opens Google Maps with new destination and transport mode.
- Track truncation: when track-based landing detection truncates the track (telemetry blackout or stationary).

Notification channels must be created on Android 8+.

---

## 17) Persistence

Persisted:
- User settings: burstAltitude, ascentRate, descentRate, stationId
- Sonde name (last active)
- Balloon track (list of BalloonTrackPoint)
- Landing history

Not persisted (ephemeral):
- Device settings (stored on device, cached in memory)
- Radio settings (from telemetry)

On app background/inactive:
- Save sonde name, track, and landing history.

---

## 18) CSV Telemetry Logging

- File name: telemetry_log.csv
- Location: app external files directory so Windows can access via USB MTP without any in-app export UI.
- Recommended path: /Android/data/com.balloonhunter.app/files/telemetry_log.csv
- Header: timestamp,sondeName,latitude,longitude,altitude,landingLat,landingLon
- Each PositionData append uses ISO8601 with fractional seconds.
- Skip sonde names starting with "DEV" (case-insensitive).

---

## 19) Startup and Foreground Resume

### 19.1 Startup sequence (max 15 seconds)
1) Load persisted data (sonde name, track, landing points)
2) Request current user location
3) Inject persisted data into services
4) Start BLE scanning and APRS polling
5) Wait for BLE/APRS answers (BLE: powered off or connected or scan timeout; APRS: data or error)
6) Mark startup complete and let state machine take over

### 19.2 Foreground resume
1) Request current user location
2) Trigger state machine evaluation
3) If previous state was liveBLEFlying or aprsFlying, run APRS gap fill with forceDetection=true
4) If state unchanged, re-apply state configuration

---

## 20) Background behavior

When app is backgrounded:
- BLE stays active (foreground service required on Android).
- Stop APRS polling, predictions, routing, and location updates.
- On foreground resume, re-enable as per state machine.

---

## 21) Permissions

- Bluetooth scan/connect (Android 12+)
- Fine location (required for BLE scan on older Android and for map user location)
- Notifications
- Internet
- Foreground service (BLE)
- Access to external files not required if you store in app external files dir (MTP access by user).

---

## 22) Testing Checklist

- BLE telemetry Type 0/1/2/3 parsing
- BLE connection state transitions and staleness thresholds
- APRS polling cadence changes based on data age
- State machine transitions in all telemetry combinations
- Prediction API requests and caching
- Route calculation fallbacks
- Track gap fill and truncation notifications
- Foreground resume flow
- Background BLE-only behavior
- Settings update commands and persistence
- CSV logging and file access

---

## 23) Open Questions (must be answered before implementation)

1) Google mode requires users to provide their own Google Maps + Directions API keys (billing-enabled). OSM mode requires no keys but uses third-party OSM tooling.

