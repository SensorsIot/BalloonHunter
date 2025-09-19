



KU7T2A-RJ4BUC-ZCFU8E-YNBSU8

# Functional Specifications Document (FSD) for the Balloon Hunter App

## Intro

This document outlines requirements for an iOS application designed to assist a person in hunting and recovering weather balloons. The app's design is centered around a single-screen, map-based interface that provides all critical information in real-time as they pursue a balloon.

The balloon carries a sonde that transmits its position signal. This signal is received by a device, called “MySondyGo”. This device transmits the received telemetry data via BLE to our app. So, sonde and balloon are used interchangeable.

# Arcitecture

## File Structure

### BalloonHunterApp.swift:

The main entry point of the application. It initializes and injects the core services          (AppServices, ServiceCoordinator) into the SwiftUI environment and manages the startup UI flow.

###  AppServices.swift:

A dependency injection container that creates and holds instances of the core services  like PersistenceService, BLECommunicationService, and currentLocationService.

### ServiceCoordinator.swift:

The central architectural component that coordinates all services, manages  
         application state, and handles the main business logic that was originally intended for the Policy layer in the FSD.

### CoordinatorServices.swift:

An extension to ServiceCoordinator that specifically contains the detailed 8-step  
         startup sequence logic, keeping the main ServiceCoordinator file cleaner.

### Services.swift:

A large file containing the implementation for many of the application's services and data models, including CurrentLocationService, BalloonPositionService, BalloonTrackService, PredictionService, RouteCalculationService, and PersistenceService.

### BLEService.swift:

Contains the BLECommunicationService, which is responsible for all Bluetooth Low Energy  communication, including device scanning, connection, and parsing incoming data packets from the MySondyGo device.

### TrackingMapView.swift:

The main view of the app. It renders the map, all overlays (balloon track, prediction, route), and the top row of control buttons.

### DataPanelView.swift:

A SwiftUI view that displays the two tables of telemetry and calculated data at the bottom of the main screen.

### SettingsView.swift:

Contains the UI for all settings, including the main "Sonde Settings" and the tabbed "Device Settings" sheet.

### PredictionCache.swift:

An actor that provides a thread-safe, in-memory cache for prediction data to avoid redundant API calls.

### RoutingCache.swift:

An actor that provides a thread-safe, in-memory cache for calculated routes to avoid redundant route calculations.

## Architecture 

We want true separation of concerns with views handling only presentation logic and services managing all business  operations.

 The app shall use a centralized coordinator pattern. The ServiceCoordinator class is the heart of this architecture.


### Key components and roles:

####    \`AppServices\` (Dependency Container):

This class acts as a simple dependency injection (DI) container. It is  responsible for creating and owning the instances of the foundational services when the app starts.

## Service Coordinator\` (The Central Hub):

This is the most critical component in the architecture. It serves two  
      primary functions:  
State Manager: It acts as the single source of truth for the application's state. It holds all the data needed for the UI in its @Published properties (e.g., balloonTelemetry, annotations, userRoute).  
Orchestrator: It contains the business logic that subscribes to events from the various services and decides what to do. For example, it listens for new telemetry data and decides whether to trigger a new prediction or route calculation.

####    Services (Data Producers and Workers):

Each service has a distinct responsibility:

* BLE CommunicationService: Manages all aspects of Bluetooth communication.  

* CurrentLocationService: Provides the user's GPS location.  

* BalloonTrackService: Manages the history of the balloon's flight path.  

* PredictionService & RouteCalculationService: Perform on-demand calculations then called by the ServiceCoordinator.  

* PersistenceService: Handles saving and loading data.

  ####    Views (UI Layer):

The SwiftUI views (like TrackingMapView and DataPanelView) are the presentation layer. They are designed to be "dumb" consumers of data. They use @EnvironmentObject to observe the ServiceCoordinator and automatically update whenever its @Published properties change. User interactions (like button taps) are forwarded as simple method calls to the ServiceCoordinator.

### Data Flow

  The data flow is straightforward and centralized:

1. Data In: Services like BLECommunicationService and CurrentLocationService receive data from external sources (the  BLE device, GPS).  

2. Coordination: These services publish their data using Combine. The ServiceCoordinator subscribes to these publishers.  

3. Logic & State Update: When the ServiceCoordinator receives new data, it runs its business logic (e.g., checks if  a new prediction is needed) and updates its own @Published state properties.  

4. UI Update: Because the SwiftUI views are observing the ServiceCoordinator, they automatically re-render to display the new state.

   2. ## Services

      1. ### BLE Communication Service

Purpose: Manages Bluetooth communication with MySondyGo devices

####   Input Triggers:

  \- Bluetooth state changes (powered on/off)  
  \- Device discovery events  
  \- Incoming BLE data packets  
  \- User commands (get parameters, set frequency, etc.)

####   Data it Consumes:

  \- Raw BLE message strings (Type 0,1,2,3 packets)  
  \- User command requests  
  \- Bluetooth peripheral data

####   Data it Publishes:

  \- @Published var telemetryAvailabilityState: Bool \- Whether telemetry is available  
  \- @Published var latestTelemetry: TelemetryData? \- Latest parsed telemetry  
  \- @Published var deviceSettings: DeviceSettings \- MySondyGo device configuration  
  \- @Published var connectionStatus: ConnectionStatus \- .connected, .disconnected, .connecting  
  \- @Published var lastMessageType: String? \- "0", "1", "2", "3"  
  \- PassthroughSubject\<TelemetryData, Never\>() \- Real-time telemetry stream  
  \- @Published var lastTelemetryUpdateTime: Date? \- Last update timestamp  
  \- @Published var isReadyForCommands: Bool \- Can send commands to device

####   Example Data:

  TelemetryData(  
      sondeName: "V4210129",  
      probeType: "RS41",  
      frequency: 404.500,  
      latitude: 46.9043,  
      longitude: 7.3100,  
      altitude: 1151.0, // meters  
      verticalSpeed: 153.0, // m/s  
      horizontalSpeed: 25.3, // km/h  
      signalStrength: \-90 // dBm

1. Device Discovery and Connection  
   * The service actively scans for nearby Bluetooth Low Energy (BLE) devices.  
   * It will only attempt to connect to devices whose name includes “MySondyGo”.  
   * At any time, the service will maintain a connection to at most one “MySondyGo” device. If a connection is lost, it will attempt to reconnect automatically.  
   * UART\_SERVICE\_UUID \= "53797269-614D-6972-6B6F-44616C6D6F6E"  
   * UART\_RX\_CHARACTERISTIC\_UUID \= "53797267-614D-6972-6B6F-44616C6D6F8E"  
   * UART\_TX\_CHARACTERISTIC\_UUID \= "53797268-614D-6972-6B6F-44616C6D6F7E"

2. Receiving Data from the Balloon  

* When a connection to a device is established, the device begins transmitting data packets using the Serial BLE protocol as described in the Appendix.  
* The service is responsible for receiving, buffering, and assembling these packets as they arrive.

3. Packet Parsing and Data Extraction  

* The service parses each incoming BLE packet according to the structure and definitions specified in the Appendix.  

* All packets are parsed and the content made available to other parts of the app in real time.  

* Type 1 Outliers with lat: \=0/lon=0 positions shall be skipped right after parsing and not be passed on.

  Reliability and Error Handling

* If the BLE connection is dropped or interrupted for any reason, the service will attempt to reconnect and resume regular operation automatically.  

* All parsing errors or malformed packets will be skipped to maintain stability, and attempts will be made to process subsequent packets.

  2. ### Current Location Service

  Purpose: Tracks iPhone's GPS location and heading

####   Input Triggers:

  \- Location permission changes  
  \- GPS location updates from iOS  
  \- Heading/compass changes  
  \- Proximity mode changes (balloon distance)

####   Data it Consumes:

  \- iOS CLLocation updates  
  \- CLHeading updates  
  \- Balloon position (for proximity calculations)

####   Data it Publishes:

  \- @Published var locationData: LocationData? \- Current iPhone location  
  \- @Published var isLocationPermissionGranted: Bool \- Permission status

####   Example Data:

  LocationData(  
      latitude: 47.4746668, // degrees  
      longitude: 7.7673036, // degrees    
      altitude: 456.2, // meters  
      accuracy: 5.0, // meters  
      heading: 245.3, // degrees  
      timestamp: Date()

####    Description

Two-Mode GPS Configuration  
  🎯 CLOSE MODE (\<100m to balloon):  
  \- kCLLocationAccuracyBest \- Highest GPS precision  
  \- distanceFilter \= kCLDistanceFilterNone \- No movement threshold  
  \- Time-based filtering: Max 1 update per second  
  📡 FAR MODE (\>100m to balloon):  
  \- kCLLocationAccuracyNearestTenMeters \- Reasonable precision  
  \- distanceFilter \= 5.0 \- Only update on 5+ meter movement  
  \- No additional time filtering needed

3. ### Persistence Service

Purpose: Saves/loads data to UserDefaults. During development, and because user defaults are cleared when a new version is compiled, persistence uses the file system for storage. Ihis part has ot be encapsulated that it can easily be changed after develoment

####   Input Triggers:

  \- App startup (load data)  
  \- App backgrounding (save data)  
  \- Settings changes  
  \- Track updates  
  \- Device setting updates

####   Data it Consumes:

  \- User settings (burst altitude, descent rates)  
  \- Device settings (MySondyGo configuration)  
  \- Balloon tracks (by sonde name)  
  \- Landing points (by sonde name)

####   Data it Publishes:

  \- @Published var userSettings: UserSettings \- Prediction parameters  
  \- @Published var deviceSettings: DeviceSettings? \- MySondyGo config  
  \- Persistence completion events

####   Example Data:

  UserSettings(  
      burstAltitude: 30000.0, // meters  
      ascentRate: 5.0, // m/s  
      descentRate: 5.0 // m/s  
  )  
  DeviceSettings(  
      callsign: "HB9BLA",  
      frequency: 404.500, // MHz  
      power: 10, // dBm  
      bandwidth: 1,  
      spreadingFactor: 7  
  )

The service handles these types of data:

* Forecast Settings: It stores specific forecast parameters— burstAltitude (the altitude where the balloon is expected to burst), ascentRate (the rate at which the balloon rises), and descentRate (the rate at which the sonde falls back to Earth). These settings are kept so users don't have to re-enter them each time they open the app. They are stored in a simple key-value store.  
* Landing Point: Coordinates of the landing point are persisted together with the sonde name. It always persists if  the landing point is updated.  
* Balloon track: All balloon track data is stored together with a time stamp. Historic track data is persisted.

### Balloon Track Service

    Purpose: Maintains historical balloon flight path

####   Input Triggers:

  \- New telemetry data arrival  
  \- Sonde name changes (new balloon)  
  \- App lifecycle events (save/load)

####   Data it Consumes:

  \- TelemetryData for track points  
  \- Persistence service for historical tracks

####   Data it Publishes:

  \- @Published var currentBalloonTrack: \[BalloonTrackPoint\] \- Flight path history  
  \- @Published var currentBalloonName: String? \- Active sonde identifier  
  \- @Published var currentEffectiveDescentRate: Double? \- Calculated m/s  
  \- PassthroughSubject\<Void, Never\>() \- Track update notifications  
  \- @Published var isBalloonFlying: Bool \- Flight status  
  \- @Published var isBalloonLanded: Bool \- Landing detection  
  \- @Published var landingPosition: CLLocationCoordinate2D? \- Landing coordinates

####   Example Data:

  BalloonTrackPoint(  
      latitude: 46.9043,  
      longitude: 7.3100,  
      altitude: 1151.0, // meters  
      verticalSpeed: 153.0, // m/s  
      horizontalSpeed: 25.3, // km/h  
      timestamp: Date()  
  )

At startup, it shall read the persisted historic track data from persistence service (including sonde name) and store it in the current track

 Telemetry data is cleaned and prepared for presentation and decision:

* Derived speeds: “Compute horizontal speed via Haversine/Δt and vertical speed via Δalt/Δt from track points; use these for all smoothing, detection, and descent calculations.”  

* Prefilter \+ smoothing: “Apply Hampel filter (window 10, k=3) per stream and deadbands (v\_h \< 0.2 m/s, |v\_v| \< 0.05 m/s), then EMA with τ=10s for both horizontal and vertical speeds. Publish smoothed values.”  

* Adjusted descent rate: “Per-update: 60 s robust estimate using the median of interval vertical speeds; maintain a 20-value moving average and publish adjustedDescentRate.”  

* Landed detection: *"GPS accuracy-aware statistical confidence-based detection with 75% confidence threshold requiring minimum 3 data points. Accounts for poor GPS altitude accuracy (±10-15m) with 12m tolerance vs 3-5m horizontal accuracy. Confidence weighting: 40% horizontal position, 20% altitude, 30% speed stability, 10% sample size. Uses average speeds instead of maximum for more stable detection. Hysteresis clearing thresholds: altitude spread (10s) > 5.0m, radius95 (10s) > 20.0m, or smoothed horizontal speed > 6.0 km/h."*  

* Persistence: “Append new track points, fire updates, and persist every 10 samples.”

  \- Under ServiceCoordinator:  
      \- “Consumes BalloonTrackService’s adjustedDescentRate, smoothed speeds, and isBalloonLanded; decides when to trigger predictions and to recalc  
  routes; no motion calculations here.”

When the balloon position changes, the current track shall be extended with a new position. As soon as a new sonde Name is received, the entire current track and all persisted data are deleted, and a new track starts.

Before the app closes, or every 10 new telemetry points, the current track data shall be persisted (including the current sonde name).

This service provides a “balloon flying” and a “balloon landed” signal (or a flight status signal) to other applications.

*GPS accuracy-aware statistical confidence-based landing detection has replaced the simple fixed-threshold approach. The system accounts for real-world GPS limitations where altitude accuracy (±10-15m) is 2-3x worse than horizontal accuracy (±3-5m). The weighted confidence calculation combines:*
*- Altitude stability (20% weight) - Standard deviation with 12m tolerance for GPS altitude noise*
*- Position stability (40% weight) - Maximum drift distance, prioritized due to superior horizontal GPS accuracy*
*- Speed stability (30% weight) - Average (not maximum) speeds for more stable detection*
*- Sample size confidence (10% weight) - More data points increase confidence*

*Landing decision requires 75% confidence threshold (reduced from 80% for better responsiveness) and minimum 3 data points, enabling immediate detection when persistent track data is available while maintaining accuracy through proper statistical analysis that accounts for GPS technology limitations.*

Adjusted descend rate: This value is calculated every time a new telemetry arrives.

Descent Rate Calculation:  
  \- Takes current telemetry (altitude \+ timestamp) as "now"  
  \- Finds reference point from \~60 seconds ago in track history  
  \- Calculates: descent\_rate \= (current\_altitude \- historical\_altitude) / actual\_time\_difference  
    
  Then 20-Value Smoothing:  
  \- Each of these precisely-calculated descent rates goes into a buffer  
  \- Average the last 20 such calculations for the final adjusted descent rate. If less than 20 values are available, it uses the available number.

4. ### Prediction Service

Purpose: Single service handling both Sondehub API calls AND automatic prediction scheduling

####   Input Triggers:

  \- Timer-based: 60-second automatic intervals when running  
  \- Manual: User taps on balloon annotation  
  \- Startup: First telemetry received after app launch  
  \- API requests: External calls for prediction data

####   Data it Consumes:

  \- Current telemetry data (TelemetryData)  
  \- User settings (burst altitude, ascent/descent rates)  
  \- Atmospheric model parameters from Sondehub  
  \- Cache keys for deduplication  
  \- ServiceCoordinator state for smoothed descent rates

####   Data it Publishes:

  \- @Published var isRunning: Bool \- Automatic prediction status  
  \- @Published var hasValidPrediction: Bool \- Prediction available  
  \- @Published var lastPredictionTime: Date? \- Last successful prediction  
  \- @Published var predictionStatus: String \- Current status messages  
  \- @Published var latestPrediction: PredictionData? \- Most recent prediction results  
\- landing time  
  \- Service health events and API responses

The Sondehub balloon path prediction API ([https://github.com/projecthorus/tawhiri/](https://github.com/projecthorus/tawhiri/)) is used to predict:

* The balloon path  
* The burst point (Balloon Burst)  
* The landing point

* The landing time

The API call has to be non-blocking with a timeout and provide a flag for a valid/nonvalid prediction that is published.

It parses the JSON file and extracts the path, the burst point, and the landing point and time.

1. #### Key parameters for the prediction API call:

The api expects a date-time in the future, the burst altitude,  and the current altitude (launch altitude).

* Burst Altitude: During ascent, the default is 35000m (can be changed in settings). When the balloon is descending, the burstAltitude parameter to be sent to the API is then automatically set to the current altitude plus 10 meters. The persisted burst altitude in the settings remains unchanged.  

* Ascending Speed: Can be changed in settings, default is 5m/s.  

* Descending Speed: Can be changed in settings, default is 5m/s. It is replaced by the adjusted descent speed if the balloon is below 10000m altitude  

* Time: the actual time+1 minute

  ### Route Calculation Service

  Purpose: Calculates driving/cycling routes to landing point

####   Input Triggers:

  \- New landing point available  
  \- User location changes (significant movement)  
  \- Transport mode changes (car ↔ bike)  
  \- Route recalculation requests

####   Data it Consumes:

  \- User location (LocationData)  
  \- Landing point coordinates  
  \- Transport mode (.car or .bike)

####   Data it Publishes:

  \- RouteData \- Apple Maps route information  
\- “valid/nonvalid” route

####   Example Data:

  RouteData(  
      route: MKRoute, // Apple Maps route object  
      distance: 15420.0, // meters  
      expectedTravelTime: 1260.0, // seconds (21 minutes)  
      transportType: .car,  
      polyline: MKPolyline, // Route path for map display  
      instructions: \["Turn right on...", "Continue for 5km..."\]  
  )

The route from the current location (the location of the iPhone) to the predicted landing point is calculated by calling Apple Maps. Two modes of transport are selectable (car or bicycle). The track is shown in a map overlay. The predicted arrival time at the landing point is shown in the data panel.

A Transport Mode selector (car or bicycle) decides how to plan the route. If a new transport mode is selected, the existing route has to be erased.

Use request.transportType \= .cycling for the transport mode “ bicycle”. Reduce the calculated travel time by 30% for the bicycle.

Publishes 

#### 

#### Read landing point from clipboard

If the user is too far from the balloon, the landing point information comes from [Radiosondy.info](http://Radiosondy.info). The user copies an openstreetmap link into the clipboard. The app can read it from there with a button press. A new landing position can be parsed from a URL in the clipboard.
Example: [https://www.openstreetmap.org/directions?route=47.4738%2C7.75929%3B47.4987%2C7.667\#](https://www.openstreetmap.org/directions?route=47.4738%2C7.75929%3B47.4987%2C7.667#)
This landing point is (lat: [47.4987, lon: 7.667](https://www.openstreetmap.org/directions?route=47.4738%2C7.75929%3B47.4987%2C7.667#)).

*When a landing point is successfully parsed from the clipboard, the balloon is automatically set as landed. This triggers the landing mode UI which hides prediction paths, user routes, and runner icons while displaying the distance overlay for recovery operations.*

###  Service Coordinator

  Purpose: Central coordinator orchestrating all services

####   Input Triggers:

  \- Telemetry updates from multiple sources  
  \- Location updates  
  \- User interactions  
  \- Startup sequence events

####   Data it Consumes:

  \- All service outputs  
  \- User interface events

####   Data it Publishes:

  \- Map state (annotations, regions, overlays)  
  \- Coordinated application state  
  \- UI update triggers  
  \- Smoothed/calculated derivatives (descent rates, etc.)

####   Example Coordinated Data:

  // Map region encompassing all important points  
  MKCoordinateRegion(  
      center: CLLocationCoordinate2D(lat: 46.8800, lon: 7.3300),  
      span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)  
  )  
  // Smoothed descent rate (20-value average)  
  smoothedDescentRate: \-12.3 // m/s (negative \= descending)

## 

## Startup

1. Service Initialization: Services are initialized and logo page presentation (logo has to be presented as early as possible).   
2. Initial Map: After calling location service, the tracking map (including button row and data panel)  shows the user's position (from location service) with a zoom of 25km.  
3. Connect Device: The BLE communication service connects to the device. If no connection can be established, the app waits max 5 seconds for a connection. If no connection is available the no tracking flag is set. The BLE service is a non-blocking process that runs separately. Maybe a device is later connected.  
4. Publish Telemetry: With an established connection, after receiving and decoding the first BLE package, the BLE service publishes if telemetry is available.  
5. Read Settings: A command to read settings variables from MySondyGo is issued and the resulting settings are stored locally  
6. Read Persistence: Next, the following data shall be read from persistence:  
   * Prediction parameters  
   * Historic track data  
   * Landing point (if available)  
7. Landing point determination: With this information, a valid landing point shall be determined.The priorities for that process are:
   * Prio 1: If telemetry is received and islanded is active, the current balloon position is the landing point
   * Prio 2: If the balloon is still in flight(telemetry available), the predicted landing position is the landing point
   * Prio 3: If priority 1 and 2 do not apply, the landing point shall be read and parsed from clipboard (as described below) *- this automatically sets the balloon as landed*
   * Prio 4: If no valid coordinates can be parsed from the clipboard, the persisted landing point is used
   * Otherwise: If all above fail, no landing point is available.  
8. Final Map displayed: Next, the map + data panel is displayed. It uses the maximum zoom level to show the following annotations:  

* The user position  
* The landing position   
* If a balloon is flying, the route and predicted path

If no landing point is available: The map  shows the user's position (from location service) with a zoom of 25km.  

9: End of Setup:

# Tracking View

No calculations or business logic in views. Search for an appropriate service to place and publish them.

1. ### Buttons Row

A row for Buttons is placed above the map. It is fixed and covers the entire width of the screen. It contains (in the sequence of appearance):

* Settings  

* Mode of transportation: The transport mode (car or bicycle) shall be used to calculate the route and the predicted arrival time. Every time the mode is changed, a new calculation has to be done. Use icons to save horizontal space.  

* Prediction on/off. It toggles if the balloon predicted path is displayed.  

* If a landing point is available, The  button “All” is shown.  It maximizes  the zoom level so that all overlays (user location, balloon track, balloon landing point) are visible (showAnnotations())  

* A button “Free/Heading”: It toggles between the two camera positions:  

  * “Heading” where the map centers the position of the iPhone and aligns the map direction to meet its heading. The user can only zoom freely.  
  * “Free” where the user can zoom and pan freely.  

* The zoom level stays the same if switched between the two modes.  

* Buzzer mute: Buzzer mute: On a button press, the buzzer shall be muted or unmuted by the mute BLE command (o{mute=setMute}o). The buzzer button shall indicate the current mute state.

  2. #### Map

The map starts below the button row, and occupying approximately 70% of the vertical space.

4. ## Map Overlays

No calculations or business logic in views. Search for an appropriate service to place and publish them.

The overlays must remain accurately positioned and correctly cropped within the displayed map area during all interactions. They should be updated independently and drawn as soon as available and when changed.

* User Position: The iPhone's current position is continuously displayed and updated on the map, represented by a runner.  
* Balloon Live Position: If Telemetry is available, the balloon's real-time position is displayed using a balloon marker(Balloon.fill). Its colour shall be green while ascending and red while descending.  
* Balloon Track: The map overlay shall show the current balloon track as a thin red line. At startup, this array was populated with the historic track data. New telemetry points are appended to the array as they are received. The array is automatically cleared and reset by the persistence service if a different sonde name is received (new sonde). It is updated when a new point is added to the track. The track should appear on the map when it is available.  
* Balloon Predicted Path: The complete predicted flight path from the Sondehub API is displayed as a thick blue line. While the balloon is ascending, a distinct marker indicates the predicted burst location. The burst location shall only be visible when the balloon is ascending. The display of this path is controlled by the button “Prediction on/off”. The path should appear on the map when it is available.  
* Landing point: Shall be visible if a valid landing point is available  
* Planned Route from User to Landing Point: The recommended route from the user's current location to the predicted landing point is retrieved from Apple Maps and displayed on the map as a green overlay path. The route should appear on the map when it is available.

A new route calculation and presentation is triggered:

* After a new track prediction is received, and the predicted landing point is moved  
  * Every minute, when the user moves.   
  * When the transport mode is changed

It is not shown if the distance between the balloon and the iPhone is less than 100m.

1. #### Data Panel

No calculations or business logic in views. Search for an appropriate service to place and publish them.

This panel covers the full width of the display and the full height left by the map. It displays the following fields (font sizes adjusted to ensure all data fits within the view without a title):

* Connected: An icon that indicates if a RadioSondyGo is connected via BLE (green), or not (red).  
* Sonde Identification: Sonde type, number, and frequency.  
* Altitude: From telemetry in meters  
* Speeds: Horizontal speed in km/h and vertical speed in m/s. Vertical speed: Green indicates ascending, and Red indicates descending. Smoothing (last 5 ) for both values.  
* Signal & Battery: Signal strength of the balloon and the battery status of RadioSondyGo in percentage.  
* Time Estimates: Predicted balloon landing time (from prediction service) and user arrival time (from routing service), both displayed in wall clock time for the current time zone. These times are updated with each new prediction or route calculation.  
* Remaining Balloon Flight Time: Time in hours:minutes from now to the predicted landing time.  
* Distance: The distance of the calculated route in kilometers (from route calculation). The distance is updated with each new route calculation.

* Landed: A “target” icon is shown when the balloon is landed

* Adjusted descend rate: It is calculated by the balloon track service

The data panel should get a red frame around if no telemetry data is received for the last 3 seconds

Layout:

Two tables, one below the other. All fonts the same

Table 1: 4 columns

| Column 1  | Column2      | Column 3   | Column 4  | Column 5 |
| :-------- | :----------- | :--------- | :-------- | :------- |
| Connected | Flight State | Sonde Type | sondeName | Altitude |

Table 2: 3 columns

| Column 1       | Column 2         | Column 3     |
| :------------- | :--------------- | :----------- |
| Frequency      | Signal Strength  | Battery %    |
| Vertical speed | Horizontal speed | Distance     |
| Flight time    | Landing time     | Arrival time |

Text in Columns: left aligned  
• "V: ... m/s" for vertical speed  
• "H: ... km/h" for horizontal speed  
• " dB" for RSSI  
• " Batt%" for battery percentage  
• "Arrival: ..." for arrival time  
• "Flight: ..." for flight time  
• "Landing: ..." for landing time  
• "Dist: ... km" for distance

Temporarily add a row below in table 2 and include the calculated descent rate

2. # Settings

   1. ## Settings Views

No calculations or business logic in views. Search for an appropriate service to place and publish them.

1. ### Sonde Settings Window (SondeSettings)

In long range state, triggered by a swipe-up in the data panel. In final approach state, triggered by a swipe-up in the map.. 

When opened, this window will display the currently configured sonde type and frequency, allowing the user to change them. If no valid data is available, a message is displayed instead (Sonde not connected). The frequency input has to be done without keyboard. All digits with the exception of the first have to be selectable independently.   
A "Save"  that triggers the update function for these settings is triggered when we leave the window. A BLE message to set the sonde type and its frequency “o{f=frequency/tipo=probeType}o” according to the MySondyGo specs has to be sent. A restore button resets the values to the values present when we enter the screen.   
It should expose a button to call the “tune” function and a button to select the “Devicesettings”.

5.2.1 Available sonde types (enum)

1 RS41

2 M20

3 M10

4 PILOT

5 DFM

The human readable text (e.g. RS41) should be used in the display. However, the single number (e.g. 1\) has to be transferred in the command

2. ### Device Settings (DeviceSettings)

Triggered by a button in the button row.

It opens a new window with five tabs: Pins, Battery, Radio, Prediction, and Others.

It uses the data loaded from RadioSondyGo and changes it. Therefore, we use the following process:

We use a key-value store. The process shall be as follows:

* When this screen is called, the app requests the current settings from MySondyGo.  

* MySondyGo responds with a Type 3 configuration message.  

* The app's BLE service parses this message and stores the settings in a key-value store (device settings).  

* This data is then used for the settings views.  

* If a user modifies a setting, the change is first applied to the “device settings”. This provides immediate feedback in the UI.  

* When a settings view is left, a BLE command with the changed parameters is then sent to the MySondyGo device to update it.

  3. ### Tab Structure & Contents in Settings

Each tab contains logically grouped settings:

1. #### Pins Tab

* oled\_sda (oledSDA)  

* oled\_scl (oledSCL)  

* oled\_rst (oledRST)  

* led\_pout (ledPin)  

* buz\_pin (buzPin)  

* lcd (lcdType)

  2. #### Battery Tab

* battery (batPin)  

* vBatMin (batMin)  

* vBatMax (batMax)  

* vBatType (batType)  

  * 0: Linear  
    1: Sigmoidal  
    2: Asigmoidal

    3. #### Radio Tab

* myCall (callSign)  

* rs41.rxbw (RS41Bandwidth)  

* m20.rxbw (M20Bandwidth)  

* m10.rxbw (M10Bandwidth)  

* pilot.rxbw (PILOTBandwidth)  

* dfm.rxbw (DFMBandwidth)

  4. #### Others Tab

* lcdOn (lcdStatus)  

* blu (bluetoothStatus)  

* baud (serialSpeed)  

* com (serialPort)  

* aprsName (aprsName / nameType)

  5. #### Prediction Tab

(These values are stored permanently on the iPhone via PersistenceService and are never transmitted to the device)

* burstAltitude  

* ascentRate  

* descentRate

  4. ### Tune Function

The "TUNE" function in MySondyGo is a calibration process designed to compensate for frequency shifts of the receiver. These shifts can be several kilohertz (KHz) and impact reception quality. The tune view shows a smoothened (20)  AFC value (freqofs). If we press the “Transfer” button (which is located right to the live updated field), the actual average value is copied to the input field. A “Save” button placed right to the input field stores the actual value of the input field is stored using the setFreqCorrection command. The view stays open to check the effect.

3. # Debugging

Debugging should be according the services. It should contain

* From where the trigger came (one line)  
* What was executed (one line)   
* What was delivered (one line per structure)

4. # Appendix: 

   1. ## Messages from RadioSondyGo

      1. ### Type 0 (No probe received)

* Format: 0/probeType/frequency/RSSI/batPercentage/batVoltage/buzmute/softwareVersion/o  

* Example: 0/RS41/403.500/117.5/100/4274/0/3.10/o  

* Field Count: 7 fields  

* Values:  

  * probeType: e.g., RS41  

  * frequency: e.g., 403.500 (MHz)  

  * RSSI: e.g., \-90 (dBm)  

  * batPercentage: e.g., 100 (%)  

  * batVoltage: e.g., 4000 (mV)  

  * buzmute: e.g., 0 (0 \= off, 1 \= on)  

  * softwareVersion: e.g., 3.10

    2. ### Type 1 (Probe telemetry)

* Format: 1/probeType/frequency/sondeName/latitude/longitude/altitude/HorizontalSpeed/verticalSpeed/RSSI/batPercentage/afcFrequency/burstKillerEnabled/burstKillerTime/batVoltage/buzmute/reserved1/reserved2/reserved3/softwareVersion/o  

* Example: 1/RS41/403.500/V4210150/47.38/8.54/500/10/2/117.5/100/0/0/0/4274/0/0/0/0/3.10/o (Example values for dynamic fields added for clarity)  

* Field Count: 20 fields  

* Variable names:  

  * probeType: e.g., RS41  

  * frequency: e.g., 403.500 (MHz)  

  * sondeName: e.g., V4210150  

  * latitude: (dynamic) e.g., 47.38 (degrees)  

  * longitude: (dynamic) e.g., 8.54 (degrees)  

  * altitude: (dynamic) e.g., 500 (meters)  

  * horizontalSpeed: (dynamic) e.g., 10 (m/s)  

  * verticalSpeed: (dynamic) e.g., 2 (m/s)  

  * RSSI: e.g., \-90 (dBm)  

  * batPercentage: e.g., 100 (%)  

  * afcFrequency: e.g., 0  

  * burstKillerEnabled: e.g., 0 (0 \= disabled, 1 \= enabled)  

  * burstKillerTime: e.g., 0 (seconds)  

  * batVoltage: e.g., 4000 (mV)  

  * buzmute: e.g., 0 (0 \= off, 1 \= on)  

  * reserved1: e.g., 0  

  * reserved2: e.g., 0  

  * reserved3: e.g., 0  

  * softwareVersion: e.g., 3.10

    3. ### Type 2 (Name only, coordinates are not available)

* Corrected Format: 2/probeType/frequency/sondeName/RSSI/batPercentage/afcFrequency/batVoltage/buzmute/softwareVersion/o  

* Example: 2/RS41/403.500/V4210150/117.5/100/0/4274/0/3.10/o  

* Field Count: 10 fields  

* Variable names:  

  * probeType: e.g., RS41  

  * frequency: e.g., 403.500 (MHz)  

  * sondeName: e.g., V4210150  

  * RSSI: e.g., \-90 (dBm)  

  * batPercentage: e.g., 100 (%)  

  * afcFrequency: e.g., 0  

  * batVoltage: e.g., 4000 (mV)  

  * buzmute: e.g., 0 (0 \= off, 1 \= on)  

  * softwareVersion: e.g., 3.10

    4. ### Type 3 (Configuration)

* Format: 3/probeType/frequency/oledSDA/oledSCL/oledRST/ledPin/RS41Bandwidth/M20Bandwidth/M10Bandwidth/PILOTBandwidth/DFMBandwidth/callSign/frequencyCorrection/batPin/batMin/batMax/batType/lcdType/nameType/buzPin/softwareVersion/o  

* Example: 3/RS41/404.600/21/22/16/25/1/7/7/7/6/MYCALL/0/35/2950/4180/1/0/0/0/3.10/o  

* Field Count: 21 fields  

* Variable names:  

  * probeType: e.g., RS41  

  * frequency: e.g., 404.600 (MHz)  

  * oledSDA: e.g., 21 (GPIO pin number)  

  * oledSCL: e.g., 22 (GPIO pin number)  

  * oledRST: e.g., 16 (GPIO pin number)  

  * ledPin: e.g., 25 (GPIO pin number)  

  * RS41Bandwidth: e.g., 1 (kHz)  

  * M20Bandwidth: e.g., 7 (kHz)  

  * M10Bandwidth: e.g., 7 (kHz)  

  * PILOTBandwidth: e.g., 7 (kHz)  

  * DFMBandwidth: e.g., 6 (kHz)  

  * callSign: e.g., MYCALL  

  * frequencyCorrection: e.g., 0 (Hz)  

  * batPin: e.g., 35 (GPIO pin number)  

  * batMin: e.g., 2950 (mV)  

  * batMax: e.g., 4180 (mV)  

  * batType: e.g., 1 (0:Linear, 1:Sigmoidal, 2:Asigmoidal)  

  * lcdType: e.g., 0 (0:SSD1306\_128X64, 1:SH1106\_128X64)  

  * nameType: e.g., 0  

  * buzPin: e.g., 0 (GPIO pin number)  

  * softwareVersion: e.g., 3.10

    5. ### Data Types for messages

       1. #### Type 0 message: Device Basic Info and Status

* 0: packet type (String) \- "0"  

* 1: probeType (String)  

* 2: frequency (Double)  

* 3: RSSI (Double)  

* 4: batPercentage (Int)  

* 5: batVoltage (Int)  

* 6: buzmute (Bool, 0 \= off, 1 \= on)  

* 7: softwareVersion (String)

  2. #### Type 1 message: Probe Telemetry

* 0: packet type (Int) \- "1"  

* 1: probeType (String)  

* 2: frequency (Double)  

* 3: sondeName (String)  

* 4: latitude (Double)  

* 5: longitude (Double)  

* 6: altitude (Double)  

* 7: horizontalSpeed (Double)  

* 8: verticalSpeed (Double)  

* 9: RSSI (Double)  

* 10: batPercentage (Int)  

* 11: afcFrequency (Int)  

* 12: burstKillerEnabled (Bool, 0 \= disabled, 1 \= enabled)  

* 13: burstKillerTime (Int)  

* 14: batVoltage (Int)  

* 15: buzmute (Bool, 0 \= off, 1 \= on)  

* 16: reserved1 (Int)  

* 17: reserved2 (Int)  

* 18: reserved3 (Int)  

* 19: softwareVersion (String)

  3. #### Type 2 message: Name Only

* 0: packet type (Int) \- "2"  

* 1: probeType (String)  

* 2: frequency (Double)  

* 3: sondeName (String)  

* 4: RSSI (Double)  

* 5: batPercentage (Int)  

* 6: afcFrequency (Int)  

* 7: batVoltage (Int)  

* 8: buzmute (Bool, 0 \= off, 1 \= on)  

* 9: softwareVersion (String)

  4. #### Type 3 message: Configuration

* 0: packet type (Int) \- "3"  

* 1: probeType (String)  

* 2: frequency (Double)  

* 3: oledSDA (Int)  

* 4: oledSCL (Int)  

* 5: oledRST (Int)  

* 6: ledPin (Int)  

* 7: RS41Bandwidth (Int)  

* 8: M20Bandwidth (Int)  

* 9: M10Bandwidth (Int)  

* 10: PILOTBandwidth (Int)  

* 11: DFMBandwidth (Int)  

* 12: callSign (String)  

* 13: frequencyCorrection (Int)  

* 14: batPin (Int)  

* 15: batMin (Int)  

* 16: batMax (Int)  

* 17: batType (Int)  

* 18: lcdType (Int)  

* 19: nameType (Int)  

* 20: buzPin (Int)  

* 21: softwareVersion (String)

  2. ## RadioSondyGo Commands

All commands sent to the RadioSondyGo device must be enclosed within o{...}o delimiters. You can send multiple settings in one command string, separated by /, or send them individually.

1. ### Settings Command

This command is used to configure various aspects of the RadioSondyGo device. All settings are stored for future use.

* Syntax: o{setting1=value1/setting2=value2/...}o  
* Examples:  
  * o{lcd=0/blu=0}o (Sets LCD driver to SSD1306 and turns Bluetooth off)  
  * o{f=404.600/tipo=1}o (Sets frequency to 404.600 MHz and probe type to RS41)  
  * o{myCall=MYCALL}o (Sets the call sign displayed to MYCALL)

Available Settings:

| Variable Name | Description                                                  | Default Value | Reboot Required |
| :------------ | :----------------------------------------------------------- | :------------ | :-------------- |
| lcd           | Sets the LCD driver: 0 for SSD1306\_128X64, 1 for SH1106\_128X64. | 0             | Yes             |
| lcdOn         | Turns the LCD on or off: 0 for Off, 1 for On.                | 1             | Yes             |
| oled\_sda     | Sets the SDA OLED Pin.                                       | 21            | Yes             |
| oled\_scl     | Sets the SCL OLED Pin.                                       | 22            | Yes             |
| oled\_rst     | Sets the RST OLED Pin.                                       | 16            | Yes             |
| led\_pout     | Sets the onboard LED Pin; 0 switches it off.                 | 25            | Yes             |
| buz\_pin      | Sets the buzzer Pin: 0 for no buzzer installed, otherwise specify the pin. | 0             | Yes             |
| myCall        | Sets the call shown on the display (max 8 characters). Set empty to hide. | MYCALL        | No              |
| blu           | Turns BLE (Bluetooth Low Energy) on or off: 0 for off, 1 for on. | 1             | Yes             |
| baud          | Sets the Serial Baud Rate: 0 (4800), 1 (9600), ..., 5 (115200). | 1             | Yes             |
| com           | Sets the Serial Port: 0 for tx pin 1 – rx pin 3 – USB, 1 for tx pin 12 – rx pin 2 (3.3V logic). | 0             | Yes             |
| rs41.rxbw     | Sets the RS41 Rx Bandwidth (see bandwidth table below).      | 4             | No              |
| m20.rxbw      | Sets the M20 Rx Bandwidth (see bandwidth table below).       | 7             | No              |
| m10.rxbw      | Sets the M10 Rx Bandwidth (see bandwidth table below).       | 7             | No              |
| pilot.rxbw    | Sets the PILOT Rx Bandwidth (see bandwidth table below).     | 7             | No              |
| dfm.rxbw      | Sets the DFM Rx Bandwidth (see bandwidth table below).       | 6             | No              |
| aprsName      | Sets the Serial or APRS name: 0 for Serial, 1 for APRS NAME. | 0             | No              |
| freqofs       | Sets the frequency correction.                               | 0             | No              |
| battery       | Sets the battery measurement Pin; 0 means no battery and hides the icon. | 35            | Yes             |
| vBatMin       | Sets the low battery value (in mV).                          | 2950          | No              |
| vBatMax       | Sets the battery full value (in mV).                         | 4180          | No              |
| vBatType      | Sets the battery discharge type: 0 for Linear, 1 for Sigmoidal, 2 for Asigmoidal. | 1             | No              |

2. ### Frequency Command (sent separately)

This command sets the receiving frequency and the type of radiosonde probe to listen for.

* Syntax: o{f=frequency/tipo=probeType}o  
* Example: o{f=404.35/tipo=1}o (Sets frequency to 404.35 MHz and probe type to RS41)

Available Sonde Types (enum):

* 1: RS41  

* 2: M20  

* 3: M10  

* 4: PILOT  

* 5: DFM

  3. ### Mute Command

This command controls the device's buzzer.

* Syntax: o{mute=setMute}o  

* Variable:  

  * setMute: 0 for off, 1 for on.  

* Example: o{mute=0}o (Turns the buzzer off)

  4. ### Request Status Command

This command requests the current status and configuration of the RadioSondyGo device.

* Syntax: o{?}o

  3. ## Bandwidth Table (enum):

| Value | Bandwidth (kHz) |
| :---- | :-------------- |
| 0     | 2.6             |
| 1     | 3.1             |
| 2     | 3.9             |
| 3     | 5.2             |
| 4     | 6.3             |
| 5     | 7.8             |
| 6     | 10.4            |
| 7     | 12.5            |
| 8     | 15.6            |
| 9     | 20.8            |
| 10    | 25.0            |
| 11    | 31.3            |
| 12    | 41.7            |
| 13    | 50.0            |
| 14    | 62.5            |
| 15    | 83.3            |
| 16    | 100.0           |
| 17    | 125.0           |
| 18    | 166.7           |
| 19    | 200.0           |

  4. ## Sample Response of the Sondehub API

{"metadata":{"complete\_datetime":"2025-08-26T22:03:03.430276Z","start\_datetime":"2025-08-26T22:03:03.307369Z"},"prediction":\[{"stage":"ascent","trajectory":\[{"altitude":847.0,"datetime":"2025-08-26T19:17:53Z","latitude":46.9046,"longitude":7.3112},{"altitude":1147.0,"datetime":"2025-08-26T19:18:53Z","latitude":46.90578839571984,"longitude":7.31464191069996},{"altitude":1447.0,"datetime":"2025-08-26T19:19:53Z","latitude":46.90738178436716,"longitude":7.31981095948984}{"altitude":10788.959899190435,"datetime":"2025-08-26T21:31:43.15625Z","latitude":47.02026733468673,"longitude":8.263008170483552},{"altitude":10256.937248646722,"datetime":"2025-08-26T21:32:43.15625Z","latitude":47.021786505448404,"longitude":8.28923951226291},{"altitude":9741.995036947832,"datetime":"2025-08-26T21:33:43.15625Z","latitude":47.02396145555836,"longitude":8.307239397517654},{"altitude":9242.839596842607,"datetime":"2025-08-26T21:34:43.15625Z","latitude":47.02613722448047,"longitude":8.322760393386368},{"altitude":8758.326844518546,"datetime":"2025-08-26T21:35:43.15625Z","latitude":47.028111647104396,"longitude":8.337707401779058},{"altitude":8287.43950854397,"datetime":"2025-08-26T21:36:43.15625Z","latitude":47.02974696093491,"longitude":8.352131412681159},{"altitude":7829.268592765354,"datetime":"2025-08-26T21:37:43.15625Z","latitude":47.0311409286152,"longitude":8.366009058541602},{"altitude":7382.998154071957,"datetime":"2025-08-26T21:38:43.15625Z","latitude":47.03235907618386,"longitude":8.379331881008719},{"altitude":6947.892701971685,"datetime":"2025-08-26T21:39:43.15625Z","latitude":47.03359996475082,"longitude":8.392157697045668},{"altitude":6523.28669130534,"datetime":"2025-08-26T21:40:43.15625Z","latitude":47.03520896935295,"longitude":8.404651470370947},{"altitude":6108.575700515145,"datetime":"2025-08-26T21:41:43.15625Z","latitude":47.037258694172024,"longitude":8.41695136310459},{"altitude":5703.208978139213,"datetime":"2025-08-26T21:42:43.15625Z","latitude":47.03928925553843,"longitude":8.428578406952507},{"altitude":5306.683108216105,"datetime":"2025-08-26T21:43:43.15625Z","latitude":47.04106403634041,"longitude":8.438958391369948},{"altitude":4918.53659705615,"datetime":"2025-08-26T21:44:43.15625Z","latitude":47.042834816940626,"longitude":8.447836532591719},{"altitude":4538.345223619866,"datetime":"2025-08-26T21:45:43.15625Z","latitude":47.04492666691228,"longitude":8.45520179874688},{"altitude":4165.7180265847755,"datetime":"2025-08-26T21:46:43.15625Z","latitude":47.04787297223529,"longitude":8.461030067123232},{"altitude":3800.2938252874983,"datetime":"2025-08-26T21:47:43.15625Z","latitude":47.05161301867342,"longitude":8.46540917482723},{"altitude":3441.7381907151316,"datetime":"2025-08-26T21:48:43.15625Z","latitude":47.0550365019147,"longitude":8.468771619167265},{"altitude":3089.7407977836633,"datetime":"2025-08-26T21:49:43.15625Z","latitude":47.05752477756667,"longitude":8.471863409068922},{"altitude":2744.0131021741126,"datetime":"2025-08-26T21:50:43.15625Z","latitude":47.059177735790925,"longitude":8.475280034829108},{"altitude":2404.286294670708,"datetime":"2025-08-26T21:51:43.15625Z","latitude":47.06015824553558,"longitude":8.479056798727747},{"altitude":2070.309493769621,"datetime":"2025-08-26T21:52:43.15625Z","latitude":47.06067439933653,"longitude":8.483039337670583},{"altitude":1741.8481436915101,"datetime":"2025-08-26T21:53:43.15625Z","latitude":47.06084732342465,"longitude":8.48702038862245},{"altitude":1418.6825901367554,"datetime":"2025-08-26T21:54:43.15625Z","latitude":47.06087288110848,"longitude":8.490506330028142},{"altitude":1113.0316455477905,"datetime":"2025-08-26T21:55:40.8125Z","latitude":47.06098256896306,"longitude":8.492911202660144}\]}\],"request":{"ascent\_rate":5.0,"burst\_altitude":35000.0,"dataset":"2025-08-26T12:00:00Z","descent\_rate":5.0,"format":"json","launch\_altitude":847.0,"launch\_datetime":"2025-08-26T19:17:53Z","launch\_latitude":46.9046,"launch\_longitude":7.3112,"profile":"standard\_profile","version":1},"warnings":{}}

5. ## Prediction Service API (Sondehub)

   1. ### API structure

* Endpoint: The single endpoint for all requests is   
* [https://api.v2.sondehub.org/tawhiri](https://api.v2.sondehub.org/tawhiri)  
* Profiles: The API supports different flight profiles. The one detailed here is the Standard Profile, referred to as `standard_profile`. This profile is the default and is used for predicting a full flight path including ascent, burst, and descent to the ground.

---

2. ### Request Parameters

All requests to the API for the Standard Profile must include the following parameters in the query string.

1. #### General Parameters

| Parameter          | Required | Default Value                | Description                                                  |
| :----------------- | :------- | :--------------------------- | :----------------------------------------------------------- |
| `profile`          | optional | `standard_profile`           | Set to `standard_profile` to use this prediction model (this is the default). |
| `launch_latitude`  | required | \-                           | Launch latitude in decimal degrees (-90.0 to 90.0).          |
| `launch_longitude` | required | \-                           | Launch longitude in decimal degrees (0.0 to 360.0).          |
| `launch_datetime`  | required | \-                           | Time and date of launch, formatted as a RFC3339 timestamp.   |
| `launch_altitude`  | optional | Elevation at launch location | Elevation of the launch location in meters above sea level.  |

Standard Profile Specific Parameters

| Parameter        | Required | Default Value | Description                                                  |
| :--------------- | :------- | :------------ | :----------------------------------------------------------- |
| `ascent_rate`    | required | \-            | The balloon's ascent rate in meters per second. Must be greater than 0.0. |
| `burst_altitude` | required | \-            | The altitude at which the balloon is expected to burst, in meters above sea level. Must be greater than `launch_altitude`. |
| `descent_rate`   | required | \-            | The descent rate of the payload under a parachute, in meters per second. Must be greater than 0.0. |

3. ###  Input Data Structure

The parser must be designed to accept a single JSON object with the following top-level keys and data types:

* `metadata`: An object containing processing timestamps.  
* `prediction`: An array of objects, each representing a flight stage (e.g., "ascent", "descent").  
* `request`: An object containing the initial flight parameters.  
* `warnings`: An optional object for any warnings.

The most critical data is within the `prediction` array. Each element of this array is an object with a `stage` key (string) and a `trajectory` key (array). Each element of the `trajectory` array is an object with the following structure:

* `altitude`: Number (meters)  

* `datetime`: String (ISO 8601 format)  

* `latitude`: Number (degrees)  

* `longitude`: Number (degrees)

  ---

  4. ### Parsing Logic and Extraction

The parser should perform the following actions:

1. #### General Information Extraction

* Launch Details: Extract the `launch_latitude`, `launch_longitude`, `launch_datetime`, `ascent_rate`, and `descent_rate` directly from the top-level `request` object.

  2. #### Trajectory Processing

* The parser must iterate through the `prediction` array to identify the `ascent` and `descent` stages.  

* For each stage, the entire `trajectory` array should be captured and stored.

  3. #### Burst Point Identification

* The burst point is defined as the last data point in the `ascent` trajectory.  

* The parser must extract and store the `altitude`, `datetime`, `latitude`, and `longitude` of this final ascent point.

  4. #### Landing Point Identification

* The landing point is defined as the last data point in the `descent` trajectory.  

* The parser must extract and store the `altitude`, `datetime`, `latitude`, and `longitude` of this final descent point.

  5. #### Error Response

Error responses contain two fragments: `error` and `metadata`. The `error` fragment includes a `type` and a `description`. The API can return the following error types:

* `RequestException` (HTTP 400 Bad Request): Returned if the request is invalid (e.g., missing a required parameter).  
* `InvalidDatasetException` (HTTP 404 Not Found): Returned if the requested dataset does not exist.  
* `PredictionException` (HTTP 500 Internal Server Error): Returned if the predictor's solver encounters an exception.  
* `InternalException` (HTTP 500 Internal Server Error): Returned when a general internal error occurs.  
* `NotYetImplementedException` (HTTP 501 Not Implemented): Returned if the requested functionality is not yet available.

For a balloon launched from a specific latitude and longitude, at a particular time, and with defined ascent/descent rates and burst altitude, the API call would look like this:

`https://api.v2.sondehub.org/tawhiri/?launch_latitude=50.0&launch_longitude=0.01&launch_datetime=2014-08-19T23:00:00Z&ascent_rate=5.0&burst_altitude=30000.0&descent_rate=10.0`

`https://api.v2.sondehub.org/tawhiri/?launch_latitude=46.9046&launch_longitude=7.3112&launch_datetime=2025-08-26T19:17:53Z&ascent_rate=5.0&burst_altitude=35000.0&descent_rate=5.0&launch_altitude=847.0`

6. ## Arduino (only as a reference, not to be used)

BLEAdvertising \*pAdvertising \= BLEDevice::getAdvertising();  
    pAdvertising-\>addServiceUUID(SERVICE\_UUID);  
    pAdvertising-\>setScanResponse(true);  
    pAdvertising-\>setMinPreferred(0x06);  
    pAdvertising-\>setMinPreferred(0x12);  
    pAdvertising-\>setMinInterval(160);  
    pAdvertising-\>setMaxInterval(170);  
    BLEDevice::startAdvertising();