# Hardware validation checklist (WHOOP MG + iPhone)

Nothing in this repository has been run against a physical WHOOP yet. Automated tests cover parsing,
recording, storage and analytics; they cannot prove that a given strap/firmware/iOS combination works.
Run these on your own phone and note the results (iOS version, WHOOP firmware from the WHOOP app, date).

Tip: **Settings › Diagnostics** shows notification count, mean/max interval, RR availability, malformed
packets, the last raw packet and a Bluetooth event log for every step below.

## Phase 1 — live monitor

| # | Step | Expected |
|---|---|---|
| 1 | WHOOP app: turn on Heart Rate Broadcast. RHR Monitor: Find device | Strap listed (tag "WHOOP", and/or "Heart rate", or "Connected to iPhone"). Bluetooth permission prompt appears only now |
| 2 | Tap the strap | Status goes Connecting → Connected; BPM appears within ~5 s. **No pairing prompt** |
| 3 | Walk up stairs / hold breath | BPM and chart change without touching the screen |
| 4 | Diagnostics | Mean interval ≈ 1 s (record the actual value); note whether RR intervals are present; malformed packets = 0 |
| 5 | Settings › Disconnect, then Connect | Disconnects, then reconnects and resumes |
| 6 | Walk out of range ~1 min, come back | Reconnecting → Connected automatically; the BPM greys out while stale; the chart shows a shaded gap |
| 7 | Turn Bluetooth off in Control Center, then on | "Bluetooth unavailable" banner, then automatic reconnect |
| 8 | Keep Screen Awake ON, connected, leave phone on Live for longer than your auto-lock time | Screen stays on |
| 9 | Switch to Trends tab, or toggle OFF | Screen auto-locks normally again |
| 10 | Open the WHOOP app, sync, check live HR there | **WHOOP app still works normally** while RHR Monitor is connected, and after it disconnects |
| 11 | Turn Heart Rate Broadcast OFF and reconnect | Either data keeps flowing (record that!) or the app says the device isn't sharing heart rate / no readings arrive |

## Phase 2 — reliable collection

| # | Step | Expected |
|---|---|---|
| 12 | Record 30 min in the foreground (Keep Screen Awake on), switching tabs now and then | History shows ~1 sample/s for 30 min, no gaps other than real ones |
| 13 | During a recording, move out of range for 1–2 min | Session detail lists a gap of matching length and `connection_lost` / `connected` events |
| 14 | Export samples CSV, open in Numbers/Excel | Row count equals the session's sample count; timestamps in UTC |
| 15 | Record, then lock the phone for 10 / 30 / 60 min | **Measure and write down** how much data arrived while locked (History gaps). Expected: usually continuous, but not guaranteed |
| 16 | Record, then swipe the app away in the app switcher, reopen after 1 min | Session resumed with a gap (relaunch within 30 min), or closed as Interrupted if later |
| 17 | Reboot the phone while a recording is active, unlock, open app | Session closed as Interrupted (or resumed if within 30 min); no crash |

## Phase 3 — resting HR

| # | Step | Expected |
|---|---|---|
| 18 | Resting tab → Sitting → Measure; sit still 5 min | Countdown Settling → Measuring → result with median, coverage ≥ 95 %, Valid |
| 19 | Repeat but take the strap off for 1 min during minutes 3–5 | Result flagged "Not reliable" (coverage) |
| 20 | Quit and reopen the app | Measurements still in History and Trends |

Please file results (including failures) as an issue so the README status can be updated with evidence.
