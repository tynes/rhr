# RHR Monitor — live heart rate & resting HR for WHOOP MG

A small, native, open-source iOS app that reads live heart rate from a WHOOP MG (or WHOOP 5.0, or any
standard Bluetooth heart rate strap), records it on the phone, and helps you track your resting heart rate
over time against the things you do (caffeine, alcohol, sleep, exercise, stress…).

- **No account, no server, no internet, no WHOOP API keys.** Everything stays in a local SQLite database.
- **Read-only Bluetooth.** The app only subscribes to the standard Heart Rate Measurement characteristic.
  It never pairs, never writes to the strap and never touches WHOOP's own protocol, so the official
  WHOOP app keeps working.
- **Honest data.** Missing samples are never filled in. Gaps are shaded on charts, listed per session and
  used to flag unreliable resting measurements.

> Not affiliated with WHOOP. Not a medical device.

## Status

| Area | State |
|---|---|
| Core logic (BLE packet parsing, recording, gap detection, resting-HR math, trends, correlations, CSV/JSON export, WHOOP CSV import) | Implemented, **76 automated tests passing** (Linux; CI also runs them on macOS) |
| iOS app (SwiftUI, CoreBluetooth, Swift Charts, GRDB) | Implemented. CI builds it for simulator and device on a macOS runner (see `.github/workflows/ci.yml`) |
| **Real WHOOP MG hardware** | **Not yet tested.** See [docs/HARDWARE_TESTING.md](docs/HARDWARE_TESTING.md) for the checklist to run on your phone |

What the hardware claim rests on: the NOOP project documents that WHOOP 5.0/MG straps expose the standard
Bluetooth Heart Rate service (`0x180D` / `0x2A37`), that it works without bonding, and that WHOOP's
"Heart Rate Broadcast" setting makes the strap advertise as a standard heart rate sensor. This app uses
exactly that public profile. Until you run the checklist, treat device compatibility as expected, not proven.

## Features

**Live** — big BPM readout that greys out and says so when the reading is more than 5 s old; live
scrolling chart (1 min / 5 min / 15 min / whole session) that updates as notifications arrive, with a
pause button to scroll back and press-and-hold to inspect values; connection state
(disconnected → scanning → connecting → connected → reconnecting); Start/Stop Recording; elapsed time,
sample count and last sample time; **Keep Screen Awake** toggle (default off) with an optional dim overlay.

**Resting** — guided 5-minute measurement, sitting or lying down. Minutes 0–2 are a settling period;
the result is the **median of minutes 3–5**, plus mean, min, max and standard deviation. The measurement
is flagged as not reliable if less than 80 % (configurable) of the last 3 minutes has data, if there are
too few samples, or if it was stopped early.

**Trends** — 7 / 30 / 90 days, 1 year, all time. Plots your 5-minute measurements, and optionally imported
WHOOP overnight RHR, as separate series (never merged). 7- and 28-day calendar-window averages,
30-day change, linear trend, deviation from your 28-day baseline, day-to-day consistency, weekly and
monthly averages. Tap a day to see values, sources and notes.

**Annotations & patterns** — one-tap logging for caffeine, alcohol, travel and illness; a short form for
sleep, exercise (type + intensity), stress (1–5) and notes. "Patterns" compares next-morning resting HR
after days with vs. without each behavior, and sleep hours vs. same-morning RHR, with sample sizes, an
approximate 95 % interval and plain-language caveats. Days with nothing logged are treated as unknown,
not as "didn't happen".

**History** — every recording with chart, stats, gap list, connection events, notes, CSV export, delete.

**Settings** — device picker, reconnect/forget, Bluetooth diagnostics (notification rate, RR availability,
malformed packets, event log), resting coverage threshold, export (samples / sessions / resting / annotations
as CSV, everything as JSON) via the iOS share sheet, WHOOP CSV import, delete all data, and a
**simulated heart rate** mode for trying the app without a strap (samples are labelled "Simulated").

## Build and install on your iPhone

You need a Mac with **Xcode 16 or newer**, an iPhone on **iOS 17 or newer**, and an Apple ID (a free one works).

1. Clone the repo and open `RHRMonitor.xcodeproj` in Xcode. Xcode resolves the one dependency
   (GRDB.swift) automatically — wait for "Resolving packages" to finish.
2. Select the **RHRMonitor** project in the navigator → target **RHRMonitor** → **Signing & Capabilities**:
   - **Team:** choose your Apple ID (Xcode › Settings › Accounts to add one).
   - **Bundle Identifier:** change `com.example.rhrmonitor` to something unique, e.g. `com.yourname.rhrmonitor`.
   - Leave "Automatically manage signing" on. The **Background Modes → Uses Bluetooth LE accessories**
     capability comes from `Info.plist` (`UIBackgroundModes = bluetooth-central`); no extra entitlement is needed.
3. Plug in your iPhone (or pair it over Wi-Fi), unlock it, and tap **Trust**. On iOS 16+ enable
   **Settings › Privacy & Security › Developer Mode** and restart when asked.
4. Choose your iPhone as the run destination and press **Run** (⌘R).
5. With a free Apple ID the first launch is blocked until you open **Settings › General › VPN & Device
   Management**, tap your developer certificate and **Trust** it. Free-account builds expire after 7 days —
   just run again from Xcode. A paid developer account lasts a year and allows TestFlight.

The iOS Simulator has no Bluetooth; use **Settings › Testing › Simulated heart rate** there.

## Connect your WHOOP

1. In the **official WHOOP app**, open your device settings and turn on **Heart Rate Broadcast**
   (WHOOP's feature for sharing heart rate with gym equipment and bike computers). Keep the strap on your wrist.
2. In RHR Monitor, tap **Find device** (Live tab or Settings). Allow Bluetooth when iOS asks — the app only
   asks at this point.
3. Pick your strap. A strap already held by the WHOOP app on this phone shows as **"Connected to iPhone"**;
   iOS shares that link, so you don't need to disconnect the WHOOP app.
4. The Live screen should show your heart rate within a few seconds. If it says the device "isn't sharing
   heart rate", Heart Rate Broadcast is off.

The app remembers the strap and reconnects automatically (also in the background). It never initiates
pairing; if iOS ever shows a pairing prompt while connecting, choose **Cancel** and please report it.

## Recording, background and Keep Screen Awake

- **Start Recording** saves every reading (batched, written at least every 2 s; immediately when the app is in
  the background). Stopping marks the session completed. If the app is killed mid-recording, the next launch
  resumes the session if iOS relaunched the app within 30 minutes (e.g. for a Bluetooth event) — the outage
  shows as a gap — or otherwise closes it as *interrupted* at the last saved sample.
- **Background collection is best-effort.** The app declares `bluetooth-central` background mode and uses
  CoreBluetooth state restoration, so iOS can wake it for notifications and reconnects. iOS can still suspend
  or terminate it, and force-quitting from the app switcher stops background delivery. No audio or other
  workaround is used to stay alive. Measure your own phone's behaviour with the checklist.
- **Keep Screen Awake** (off by default, resets to off at launch) disables auto-lock only while heart rate is
  being monitored, the app is in the foreground and the Live or Resting tab is visible. It is released when you
  leave those tabs, background the app, disconnect, or turn it off, and it is tracked per window so one window
  closing never re-enables auto-lock for another. It does not stop manual locking, Bluetooth drop-outs or iOS
  interruptions. **Dim display** puts a dark overlay over the screen for long sessions; it doesn't improve
  collection reliability.

For the success scenario (leave the phone showing the graph for a long session): connect, enable Keep Screen
Awake, Start Recording, optionally Dim, plug the phone in. Afterwards open **History** to inspect the session.

## Architecture

```
WHOOP MG ──BLE 0x180D/0x2A37──▶ HeartRateBLEManager (CoreBluetooth, main queue, read-only)
                                        │ HeartRateMeasurementParser (bytes → BPM, contact, RR)
                                        ▼
                               RecordingCoordinator ──▶ RecordingEngine (batching) ──▶ AppDatabase (GRDB/SQLite)
                                        │                                                   │
                                        ▼                                                   ▼
                          LiveBuffer → ChartDownsampler → Swift Charts       RestingHRCalculator / TrendCalculator /
                                                                             CorrelationAnalyzer / CSV & JSON export
```

```
Packages/RHRCore/                 Swift package — no UIKit/CoreBluetooth, builds and tests on macOS and Linux
  Sources/HeartRateKit/           parser, models, ConnectionMachine (reconnect policy), RecordingEngine,
                                  GapDetector, ChartDownsampler, RestingHRCalculator, TrendCalculator,
                                  CorrelationAnalyzer, CSV/JSON export, WHOOP CSV import, mock generator
  Sources/HeartRateStore/         GRDB schema, migrations, repositories
  Tests/                          76 XCTest cases
RHRMonitor/                       iOS app (SwiftUI)
  App/          AppDelegate + AppModel (composition root, session recovery), settings
  Bluetooth/    HeartRateBLEManager
  Recording/    RecordingCoordinator, RestingSessionController, MockHeartRateSource
  System/       KeepAwakeController, ExportService
  UI/, Components/  screens and reusable views
RHRMonitor.xcodeproj              Xcode 16 project (folder-synchronized: new files in RHRMonitor/ are picked up)
```

Bluetooth, recording and storage are owned by `AppModel`, created by the app delegate at launch (also for
background relaunches). Views only observe state, so switching screens never affects collection.

## Tests

```bash
# macOS (with Xcode installed)
cd Packages/RHRCore && swift test

# Linux (Swift 6 toolchain) — builds a snapshot-enabled SQLite for GRDB first
./scripts/test-linux.sh
```

Covered: 8/16-bit BPM, sensor-contact bits, energy expended, RR conversion (1/1024 s → ms), malformed and
truncated packets, 0 BPM; recording batching, retry after write failure, duplicate suppression, session
recovery; connection state machine (reconnect, back-off, Bluetooth off/on, missing service); keep-awake
arbitration; resting-HR median/coverage/flags including irregular sampling; gaps and chart segmentation;
calendar-day/time-zone/DST handling; moving averages, trend, baseline, weekly/monthly; correlation logic
with small samples and unlogged days; CSV/JSON round trips; database migrations, idempotent inserts,
a 30-minute 1 Hz recording, cascade deletes, export reproducing stored rows.

Not covered by automated tests: anything needing a real phone or strap — see the hardware checklist.

## Data and privacy

- Database: `Application Support/RHRMonitor/rhr.sqlite`, file protection
  *complete until first unlock* (encrypted while the phone is locked after a restart, but writable by
  background Bluetooth collection while locked).
- No analytics, telemetry or third-party SDKs. The only dependency is GRDB.swift (MIT).
- Export formats, units and time-zone rules: [docs/DATA_FORMAT.md](docs/DATA_FORMAT.md).
- Settings › Data › Delete all data removes everything (and vacuums the database).

## Design decisions

- **New small app rather than a NOOP fork (option B).** NOOP is a large multi-platform app (macOS, iOS,
  Android, watch) that bonds to WHOOP's proprietary protocol. This project needs only the public heart rate
  profile, which keeps the official WHOOP bond intact and the code small. NOOP is also licensed
  PolyForm Noncommercial, so **no NOOP code is copied**; only documented protocol facts are used
  (see [docs/ATTRIBUTION.md](docs/ATTRIBUTION.md)).
- **Swift 5 language mode** with minimal concurrency checking in the app target; all Bluetooth, timer and
  storage work runs on the main thread (CoreBluetooth is created with the main queue).
- **Timestamps** are when the phone received each notification, stored as UTC milliseconds.

## Not in this MVP

Apple Health import (the data model already has an `appleHealth` source), the WHOOP developer API, HRV
from RR intervals, AI summaries and any sync. RR intervals are already stored when the strap sends them.

## License

MIT — see [LICENSE](LICENSE).
