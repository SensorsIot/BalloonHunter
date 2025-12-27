# SondeHub API Reference for BalloonHunter

This document describes the exact SondeHub API endpoints used by the BalloonHunter app.

## Base URL

```
https://api.v2.sondehub.org
```

---

## Management Summary

BalloonHunter uses four SondeHub API endpoints to provide real-time balloon tracking and landing prediction:

| Endpoint | App Feature | When Called | Data Retrieved |
|----------|-------------|-------------|----------------|
| `/sondes/site/{station_id}` | **Auto-detect active sonde** | At startup and every 15-60s during tracking | Latest position of sondes from Payerne station |
| `/sondes/telemetry?serial=X` | **Track history & gap filling** | When BLE signal lost, on app resume, or for user-specified sondes (≤3 days old) | Complete flight track (up to 11,000 points) |
| `/sonde/{serial}` | **Historical sonde lookup** | When user enters a sonde >3 days old at startup | Full flight history for any sonde ever recorded |
| `/tawhiri` | **Landing prediction** | Every 60s while balloon is flying | Predicted flight path and landing coordinates |

### Typical User Scenarios

1. **Normal Tracking (with MySondyGo BLE device)**
   - App polls `/sondes/site/06610` to detect which sonde is currently flying from Payerne
   - BLE provides real-time position updates; APRS is backup
   - `/tawhiri` predicts landing location every 60 seconds

2. **APRS-Only Tracking (no BLE device)**
   - App polls `/sondes/site/06610` for live position updates
   - `/sondes/telemetry` fills in the complete flight track
   - `/tawhiri` predicts landing location

3. **Track a Specific Sonde (user override at startup)**
   - User enters sonde serial (e.g., "V3240680") in startup popup
   - For recent sondes (≤3 days): Uses `/sondes/telemetry?serial=X`
   - For old sondes (>3 days): Downloads from `/sonde/{serial}` and extracts last position
   - Shows landing location and calculates driving route

4. **App Backgrounded During Flight**
   - On resume, `/sondes/telemetry` fetches all missed track points
   - State machine re-evaluates if balloon has landed

---

## 1. Site Sondes Endpoint

**Purpose**: Get current/recent sondes launched from a specific weather station.

### Request

```
GET /sondes/site/{station_id}
```

**Example**:
```
GET https://api.v2.sondehub.org/sondes/site/06610
```

**Headers**:
```
Accept: application/json
User-Agent: BalloonHunter iOS App
```

**Parameters**:
| Parameter | Type | Description |
|-----------|------|-------------|
| station_id | Path | WMO station ID (e.g., "06610" for Payerne, Switzerland) |

### Response

**Content-Type**: `application/json`

**Structure**: Dictionary with sonde serial numbers as keys

```json
{
  "V3240531": {
    "serial": "V3240531",
    "type": "RS41",
    "frequency": 403.50,
    "tx_frequency": null,
    "datetime": "2025-12-11T13:09:26.000Z",
    "lat": 46.82376,
    "lon": 7.95904,
    "alt": 13203,
    "vel_h": 11.6,
    "vel_v": -15.1,
    "temp": -52.3,
    "humidity": 45.2,
    "pressure": 178.5,
    "uploader_position": "46.8131,6.9435"
  },
  "V4220779": {
    "serial": "V4220779",
    "type": "RS41",
    "frequency": 403.50,
    "tx_frequency": null,
    "datetime": "2025-12-11T01:50:24.000Z",
    "lat": 46.68710,
    "lon": 8.37381,
    "alt": 2843,
    "vel_h": 2.3,
    "vel_v": -3.9,
    "temp": null,
    "humidity": null,
    "pressure": null,
    "uploader_position": null
  }
}
```

**Response Fields**:
| Field | Type | Description |
|-------|------|-------------|
| serial | String | Sonde serial number (unique identifier) |
| type | String | Sonde type (RS41, M20, M10, PILOT, DFM) |
| frequency | Double? | Configured frequency in MHz |
| tx_frequency | Double? | Actual transmit frequency in MHz (if different) |
| datetime | String | ISO 8601 timestamp of last telemetry |
| lat | Double | Latitude in decimal degrees |
| lon | Double | Longitude in decimal degrees |
| alt | Double | Altitude in meters above sea level |
| vel_h | Double | Horizontal velocity in m/s |
| vel_v | Double | Vertical velocity in m/s (negative = descending) |
| temp | Double? | Temperature in Celsius |
| humidity | Double? | Relative humidity in percent |
| pressure | Double? | Atmospheric pressure in hPa |
| uploader_position | String? | Uploader location as "lat,lon" string |

**App Usage**:
- Polled every 15-60 seconds depending on data freshness
- Filters out ground test sondes (< 1km from uploader)
- Selects the sonde with the most recent timestamp

---

## 2. Sonde Telemetry Endpoint

**Purpose**: Fetch complete telemetry history for a specific sonde to fill track gaps.

### Request

```
GET /sondes/telemetry?serial={serial}&duration={duration}
```

**Example**:
```
GET https://api.v2.sondehub.org/sondes/telemetry?serial=V3240531&duration=3d
```

**Headers**:
```
Accept: application/json
Accept-Encoding: gzip, deflate
User-Agent: BalloonHunter iOS App
```

**Parameters**:
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| serial | Query | Required | Sonde serial number |
| duration | Query | "3d" | How far back to fetch (e.g., "3h", "1d", "3d") |

### Response

**Content-Type**: `application/json`

**Structure**: Nested dictionary - `{ serial: { timestamp: telemetry_point } }`

```json
{
  "V3240531": {
    "2025-12-11T12:00:00.000Z": {
      "serial": "V3240531",
      "datetime": "2025-12-11T12:00:00.000Z",
      "lat": 46.81234,
      "lon": 7.12345,
      "alt": 5000,
      "vel_v": 5.2,
      "vel_h": 8.3
    },
    "2025-12-11T12:00:01.000Z": {
      "serial": "V3240531",
      "datetime": "2025-12-11T12:00:01.000Z",
      "lat": 46.81240,
      "lon": 7.12350,
      "alt": 5005,
      "vel_v": 5.1,
      "vel_h": 8.4
    }
  }
}
```

**Response Fields** (per telemetry point):
| Field | Type | Description |
|-------|------|-------------|
| serial | String? | Sonde serial number |
| datetime | String? | ISO 8601 timestamp |
| lat | Double? | Latitude in decimal degrees |
| lon | Double? | Longitude in decimal degrees |
| alt | Double? | Altitude in meters above sea level |
| vel_v | Double? | Vertical velocity in m/s |
| vel_h | Double? | Horizontal velocity in m/s |

**Performance Notes**:
- Response size: ~9.6 MB uncompressed (685 KB gzipped) for 10,000 points
- Response time: ~9 seconds (server processing)
- Timeout: 30 seconds recommended

**App Usage**:
- Called to fill gaps in BLE track when APRS fallback activates
- Filters out points that already exist in local track (by timestamp)
- Called on foreground resume if in flying state

---

## 3. Tawhiri Prediction Endpoint

**Purpose**: Calculate predicted flight path and landing location.

### Request

```
GET /tawhiri?{parameters}
```

**Example**:
```
GET https://api.v2.sondehub.org/tawhiri/?launch_latitude=46.8238&launch_longitude=7.9590&launch_datetime=2025-12-11T13:10:49Z&ascent_rate=5.00&burst_altitude=13213.0&descent_rate=5.00&launch_altitude=13203.0&profile=standard_profile&format=json
```

**Headers**: None required (standard HTTP)

**Parameters**:
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| launch_latitude | Double | Yes | Current/launch latitude (-90.0 to 90.0) |
| launch_longitude | Double | Yes | Current/launch longitude (-180.0 to 180.0) |
| launch_datetime | String | Yes | RFC3339/ISO8601 timestamp |
| launch_altitude | Double | No | Current altitude in meters |
| ascent_rate | Double | Yes | Ascent rate in m/s (> 0) |
| burst_altitude | Double | Yes | Expected burst altitude in meters (> launch_altitude) |
| descent_rate | Double | Yes | Descent rate under parachute in m/s (> 0) |
| profile | String | No | "standard_profile" (default) |
| format | String | No | "json" (default) |

**Burst Altitude Logic**:
- Ascending balloon: Use configured burst altitude (or current + 100m if below)
- Descending balloon: Use current altitude + 10m (already burst)

### Response

**Content-Type**: `application/json`

```json
{
  "metadata": {
    "complete_datetime": "2025-12-11T13:09:49.592763Z",
    "start_datetime": "2025-12-11T13:09:49.590379Z"
  },
  "prediction": [
    {
      "stage": "ascent",
      "trajectory": [
        {
          "altitude": 13203.2,
          "datetime": "2025-12-11T13:10:49Z",
          "latitude": 46.8238,
          "longitude": 7.959
        },
        {
          "altitude": 13214.91875,
          "datetime": "2025-12-11T13:10:51.34375Z",
          "latitude": 46.82381961617401,
          "longitude": 7.959411918417216
        }
      ]
    },
    {
      "stage": "descent",
      "trajectory": [
        {
          "altitude": 13214.91875,
          "datetime": "2025-12-11T13:10:51.34375Z",
          "latitude": 46.82381961617401,
          "longitude": 7.959411918417216
        },
        {
          "altitude": 500.0,
          "datetime": "2025-12-11T13:40:32.125Z",
          "latitude": 46.84056642051999,
          "longitude": 8.151055054572952
        }
      ]
    }
  ],
  "request": {
    "ascent_rate": 5.0,
    "burst_altitude": 13213.0,
    "dataset": "2025-12-11T12:00:00Z",
    "descent_rate": 5.0,
    "format": "json",
    "launch_altitude": 13203.0,
    "launch_datetime": "2025-12-11T13:10:49Z",
    "launch_latitude": 46.8238,
    "launch_longitude": 7.959,
    "profile": "standard_profile",
    "version": 1
  },
  "warnings": {}
}
```

**Response Structure**:
| Field | Type | Description |
|-------|------|-------------|
| metadata | Object | Processing timestamps |
| prediction | Array | Flight stages with trajectories |
| prediction[].stage | String | "ascent" or "descent" |
| prediction[].trajectory | Array | Array of trajectory points |
| prediction[].trajectory[].altitude | Double | Altitude in meters |
| prediction[].trajectory[].datetime | String | ISO 8601 timestamp |
| prediction[].trajectory[].latitude | Double | Latitude in decimal degrees |
| prediction[].trajectory[].longitude | Double | Longitude in decimal degrees |
| request | Object | Echo of request parameters |
| warnings | Object | Any warnings from the predictor |

**Key Derived Values**:
- **Burst Point**: Last point in "ascent" trajectory
- **Landing Point**: Last point in "descent" trajectory
- **Landing Time**: datetime of last descent point

**Error Responses**:
| HTTP Code | Error Type | Description |
|-----------|------------|-------------|
| 400 | RequestException | Invalid request parameters |
| 404 | InvalidDatasetException | Wind data not available |
| 500 | PredictionException | Predictor solver error |
| 500 | InternalException | General server error |
| 501 | NotYetImplementedException | Feature not available |

**App Usage**:
- Called every 60 seconds during flying states
- Results cached by position/altitude key
- Used to draw prediction path and landing marker on map

---

## Common Station IDs

| Station ID | Location | Country |
|------------|----------|---------|
| 06610 | Payerne | Switzerland |
| 10868 | Munich | Germany |
| 10393 | Lindenberg | Germany |
| 11035 | Vienna | Austria |

---

## Rate Limiting

SondeHub does not currently enforce strict rate limits, but the app implements:
- Site endpoint: 15-60 second polling interval (adaptive)
- Telemetry endpoint: On-demand only (gap filling)
- Prediction endpoint: 60 second timer during flight

---

## 4. Sonde History Endpoint

**Purpose**: Fetch complete flight history for any sonde ever recorded in SondeHub (no time limit).

### Request

```
GET /sonde/{serial}
```

**Example**:
```
GET https://api.v2.sondehub.org/sonde/V3240680
```

**Headers**:
```
Accept: application/json
Accept-Encoding: gzip, deflate
User-Agent: BalloonHunter iOS App
```

**Parameters**:
| Parameter | Type | Description |
|-----------|------|-------------|
| serial | Path | Sonde serial number |

### Response

**Content-Type**: `application/json`

**Structure**: Array of telemetry points (oldest first)

```json
[
  {
    "serial": "V3240680",
    "datetime": "2025-09-04T22:42:17.990000Z",
    "lat": 46.81253,
    "lon": 6.94328,
    "alt": 543.78893,
    "vel_v": -1.6927,
    "vel_h": 1.99283,
    "frequency": 403.501525,
    "type": "RS41",
    "subtype": "RS41-SG",
    "batt": 3.0,
    "temp": 16.8,
    "humidity": 79.9
  },
  ...
  {
    "serial": "V3240680",
    "datetime": "2025-09-05T09:34:06.999000Z",
    "lat": 47.49872,
    "lon": 7.66713,
    "alt": 672.04698,
    "vel_v": 0.28249,
    "vel_h": 0.02826
  }
]
```

**Performance Notes**:
- Response size: Can be very large (100-500 MB) for full flight history
- Data is sorted oldest-first
- To get landing position, extract the **last** record from the array
- Compression (`Accept-Encoding: gzip`) reduces transfer size significantly

**App Usage**:
- Only used when user specifies a sonde older than 3 days at startup
- Downloads full response, extracts last 5KB to parse final record
- Provides landing position for historical sonde recovery

**Limitations**:
- No duration/limit parameters available
- Must download entire history to get latest position
- Not suitable for polling (use `/sondes/site` or `/sondes/telemetry` instead)

---

## Data Retention

- **`/sondes/telemetry`**: Approximately **3 days**
- **`/sonde/{serial}`**: **Unlimited** (all historical data preserved)
