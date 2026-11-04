# Attribution

- **NOOP** (https://github.com/ryanbr/noop, PolyForm Noncommercial 1.0.0). Used as research only; no code
  was copied. Facts taken from its documentation (which states protocol facts may be reused freely):
  WHOOP 5.0/MG and WHOOP 4.0 expose the standard Heart Rate service `0x180D` / `0x2A37` and it works
  without bonding; the WHOOP 5/MG vendor service UUID `fd4b0001-cce1-4033-93ce-002d5875f58a` and WHOOP 4.0
  `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` (used here only to recognise a strap already connected to the
  phone); the observation that a strap reconnected by iOS stops advertising, so it must be found with
  `retrieveConnectedPeripherals`; and the snapshot-enabled SQLite recipe for running GRDB tests on Linux.
- **Bluetooth SIG Heart Rate Service 1.0** — packet format implemented in `HeartRateMeasurementParser`.
- **GRDB.swift** (MIT) — SQLite access.

WHOOP is a trademark of WHOOP, Inc. This project is not affiliated with or endorsed by WHOOP.
