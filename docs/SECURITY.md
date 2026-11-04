# Security and privacy review

Audit of the whole repository (iOS app, `RHRCore` package, CI and scripts) done before installing on a
personal iPhone. Findings are listed with what was changed. Remaining tech debt is listed at the end.

## Threat model

The app reads heart rate over Bluetooth and stores it locally. What could plausibly go wrong:

- **A nearby Bluetooth device** advertising a crafted name, or flooding fake advertisements.
- **A file you import** (WHOOP CSV) that is damaged or deliberately malformed.
- **Exported files** opened in a spreadsheet, or left behind on the phone.
- **Someone holding your unlocked phone**, or looking at the app switcher.
- **Deleted data** remaining recoverable on disk.
- **Supply chain:** the one third-party library and the CI pipeline.

Out of scope: a jailbroken or already-compromised phone, and the WHOOP strap's own firmware.

## What was already sound

- **No network code at all.** No `URLSession`, web views, analytics or third-party SDKs; nothing leaves the
  phone except exports you share yourself.
- **Minimal permissions and entitlements:** Bluetooth plus the `bluetooth-central` background mode. No custom
  URL schemes or other entry points another app could call.
- **Read-only Bluetooth.** The app subscribes to the standard Heart Rate Measurement characteristic and never
  writes to the strap or pairs with it. You pick the device yourself; nothing connects automatically to an
  unknown device.
- **Packet parser is bounds-checked.** Every read is length-checked, and BPM outside 25–250 is dropped.
- **SQL is parameterized everywhere** (the only interpolated SQL uses a fixed list of table names).
- **Data Protection** is *complete until first user authentication*: encrypted after a reboot until you
  unlock, while still letting background collection write while the phone is locked. That is the right
  trade-off for this app.

## Fixed in this review

| # | Severity | Issue | Fix |
|---|---|---|---|
| 1 | High | **"Delete all data" left deleted rows readable on disk.** Notes and readings stayed in the SQLite write-ahead log (`rhr.sqlite-wal`) after vacuum. Verified with a test that searches the raw files. | `PRAGMA secure_delete = ON` for every connection, and the WAL is truncated after the vacuum. Test: `testDeleteAllLeavesNoTraceOnDisk`. |
| 2 | Medium | **CSV formula injection.** Exports wrote notes and Bluetooth device names as-is. A value like `=HYPERLINK(...)` (which any nearby device can advertise as its name) would run as a formula when the CSV is opened in Excel, Numbers or Google Sheets. | Free-text columns starting with `= + - @`, tab or CR get a leading `'` (`CSVExporter.text`). Documented in `DATA_FORMAT.md`. |
| 3 | Medium | **Import accepted absurd values.** `inf` and 9999 BPM were stored. A date like `0001-01-01` made the "All time" trend loop over ~740,000 days on every redraw, freezing the app. | Import requires finite BPM in 25–250 and dates from 2000-01-01 to one day after the import. Files over 10 MB are refused before being read. |
| 4 | Medium | **Exported health data piled up** in the app's temporary folder; it was only removed by "Delete all data". | Exports are deleted when the share sheet closes and at every launch. |
| 5 | Medium | **No protection on screen.** Heart rate was visible in the app switcher, and anyone holding the unlocked phone could open the app. | A privacy cover hides content whenever the app isn't active. Optional **Face ID / Touch ID / passcode lock** (Settings › Privacy). Turning the lock off requires authenticating. Collection keeps running while locked. |
| 6 | Low | **Untrusted Bluetooth names** were shown and stored unfiltered (newlines, right-to-left override characters that make text read backwards, unlimited length). | `DeviceName.sanitize` strips control and invisible formatting characters and caps names at 64 characters. |
| 7 | Low | **Unbounded scan list.** A device spamming fake advertisements could grow the device list without limit. | The list is capped at 50 devices and reset on each scan. |
| 8 | Low | **State restoration adopted any peripheral.** After a background relaunch it fell back to the first restored device even if it wasn't the saved one, e.g. one you had told it to forget. | Only the saved device is restored. |
| 9 | Low | **Floating dependency.** GRDB was `from: "7.0.0"` and the lockfile was gitignored, so each machine could resolve a different version. It actually did: Swift 6.0 picks 7.8.0, newer Xcode picks 7.12.0, released 3 days before this review. | Pinned to exactly 7.8.0. `Package.resolved` is committed with the commit hash, for both SwiftPM and Xcode. |
| 10 | Low | **CI token and actions.** Workflows ran with default token permissions, `actions/checkout` was referenced by a movable tag, and git credentials were persisted. | `permissions: contents: read`, checkout pinned to a commit SHA, `persist-credentials: false`, job timeouts. The SQLite download is verified as a whole zip before extraction. |
| 11 | Low | "Delete all data" left per-session posture keys in `UserDefaults`. | Cleared as part of delete-all. |
| 12 | Info | No privacy manifest. | Added `PrivacyInfo.xcprivacy`: no tracking, no collected data, `UserDefaults` reason `CA92.1`. |

## Known limitations

- **The iOS app target has never been compiled by Xcode** (it was written on Linux, and CI runners never
  started). The core package builds and its 82 tests pass, but the app code, including this review's changes,
  may need small compile fixes on first build. This is the biggest risk, and it's a reliability risk more
  than a security one.
- The privacy cover sits under sheets presented on top of the main screen (share sheet, annotation editor).
  Those show no heart rate data.
- Data is included in your iPhone backups, like any app data. iCloud backups are encrypted; with Advanced
  Data Protection, end-to-end.
- Any device can claim to be a heart rate sensor. A spoofed device can only feed you fake readings after you
  choose it yourself.

## Remaining tech debt (not fixed here)

- **Export builds everything in memory.** `AppDatabase.exportBundle` loads every sample, and the CSV/JSON is
  built as one string. At 1 Hz that's ~2.6 M samples a month, so after months of recording an export can run
  out of memory and crash. Stream rows to the file instead.
- **Main-thread work.** `RecordingCoordinator.resume` and `RestingSessionController.finish` read samples
  synchronously. `TrendsView` and `SessionDetailView` recompute statistics inside `body` on every render.
  Move these off the main thread or cache them.
- **Concurrency checking is off.** The app uses Swift 5 mode with `SWIFT_STRICT_CONCURRENCY = minimal`.
  `AppModel`, `RecordingCoordinator` and `HeartRateBLEManager` are main-thread-only by convention, not
  marked `@MainActor`, and `AppDatabase` is `@unchecked Sendable`. Adding `@MainActor` and raising the
  checking level would let the compiler enforce this.
- **Errors swallowed with `try?`** in the UI (saving notes, deleting a session, saving annotations, logging
  events). A failed write is invisible to the user.
- **Leaky boundaries.** `RestingSessionController` reaches into `recorder.database`. Connection event kinds
  are free-form strings rather than an enum. `fetchSamples` and `fetchSamplesAsync` duplicate each other.
- **Silent fallbacks on corrupt rows.** Row mapping turns an unreadable day into 1970-01-01 and an unknown
  posture into "sitting", which hides corruption instead of reporting it.
- If Application Support is unavailable, `AppModel.databaseURL` falls back to the temporary directory, which
  iOS may purge.
