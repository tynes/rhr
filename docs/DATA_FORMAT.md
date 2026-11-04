# Data format

## Conventions

- **Instants** are stored as integer milliseconds since 1970-01-01 UTC and exported as ISO 8601 UTC with
  milliseconds, e.g. `2026-10-31T08:29:00.123Z`. CSVs also include a `*_unix_ms` column for samples.
- **Sample timestamps** are when the iPhone *received* the Bluetooth notification. The standard Heart Rate
  Measurement packet carries no timestamp, and the strap chooses its own cadence (typically ~1/s).
- **Calendar days** (`day`, `yyyy-MM-dd`) are local dates in the time zone where the value was measured
  (resting measurements also store `time_zone`). Trends use calendar-day windows; missing days are left
  missing.
- **Units:** heart rate in beats per minute; RR intervals in milliseconds (sensor resolution 1/1024 s,
  so values like `976.5625` are exact), `;`-separated in one CSV field; coverage as a 0–1 fraction.
- **Free text** (notes, annotation text, device names and identifiers): a value starting with `=`, `+`, `-`,
  `@`, tab or carriage return is written with a leading `'`, so Excel, Numbers and Google Sheets show it as
  text instead of evaluating it as a formula. Strip that `'` if you parse these columns yourself.

## Files

| Export | Columns |
|---|---|
| `rhr-samples-*.csv` | session_id, timestamp_utc, timestamp_unix_ms, heart_rate_bpm, rr_intervals_ms, sensor_contact (`detected`/`notDetected`/`notSupported`), source_device |
| `rhr-sessions-*.csv` | session_id, kind (`freeform`/`resting`), status (`recording`/`completed`/`interrupted`), started_at_utc, ended_at_utc, duration_seconds, sample_count, device_identifier, device_name, notes |
| `rhr-resting-*.csv` | measurement_id, session_id, started_at_utc, day, time_zone, posture (`sitting`/`lyingDown`), valid, median_bpm, mean_bpm, min_bpm, max_bpm, sd_bpm, sample_count, coverage, largest_gap_seconds, flags, settle_seconds, window_seconds, notes |
| `rhr-annotations-*.csv` | annotation_id, day, kind, value, text, session_id, created_at_utc |
| `rhr-all-*.json` | Everything above plus imported WHOOP values and connection events, with a `conventions` block |

Annotation `value` meaning by kind: caffeine = servings, alcohol = drinks, sleep = hours (logged on the
morning after), exercise = intensity 1–5 (`text` = type), stress = level 1–5.

Resting `flags`: `noSamples`, `insufficientCoverage`, `tooFewSamples`, `stoppedEarly` make a result invalid;
`largeGap` (> 30 s) and `contactLost` are warnings.

## What is stored

Only samples with 25–250 BPM are stored (0 BPM is what straps typically send when off the wrist).
Nothing is interpolated. Gaps are derived from spacing between samples (> 5 s) and explained by
`connection_event` rows (connected, connection_lost, bluetooth_unavailable, restored, …).

## SQLite schema (v1)

`recording_session`, `heart_rate_sample` (unique on session_id + timestamp_ms, so retried writes never
duplicate), `resting_measurement`, `imported_rhr` (one row per source per day), `annotation`,
`connection_event`. See `Packages/RHRCore/Sources/HeartRateStore/AppDatabase.swift`.
