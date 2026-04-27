# did-i-snore-last-night.app

Records you while you sleep, throws away the silence, and shows you a timeline
of the noises you actually made — snores, sleep-talk, toots, coughs, the cat
knocking something over at 3 AM. Runs on Android and iOS, on-device, no
network. The morning question "did I snore?" gets a real answer with audio.

> **Status:** v1 in development. Nothing ships yet.

## Privacy

This app records you while you are unconscious. That is a serious thing, so
the privacy stance is the load-bearing design decision, not a footer item:

- **No network permission.** On Android the `INTERNET` permission is omitted
  from the manifest entirely — the OS will not let the app open a socket even
  if some dependency tries to.
- **No cloud.** No accounts, no sync, no analytics, no crash reporters.
- **No third-party SDKs that phone home.** Audited at every dependency add.
- **Audio stays in the app sandbox.** Deletable per-event or all-at-once.
- **Sharing is explicit.** Files only leave the app via the OS share sheet,
  one event at a time, when you tap "share."

iOS has no hard manifest-level network block, so the equivalent guarantee
there is "we don't write any networking code and we don't add any SDK that
does."

While recording, iOS shows the orange dot in the status bar and Android shows
a persistent notification. Both are unavoidable OS-level mic indicators —
they're a feature, not a bug.

## Setup (read before the first night)

Accuracy depends on physical setup more than on code:

- **Plug the phone in.** 8 hours of mic + on-device classification drains a
  battery and runs the phone hot. Treat this as a wired-only app.
- **Place the phone within ~1 m**, screen-down, on a hard surface. Soft
  surfaces (pillow, duvet) muffle the mic.
- **Run the 30 s calibration on first use** in a quiet bedroom. The app
  samples the noise floor and sets the gate threshold from it. Re-run from
  settings after moving rooms or switching phones.
- **One phone per person.** The mic can't tell who made a sound, so two
  people in the same room means each runs the app on their own phone on their
  own bedside table. Shared noises (cat, sirens) will show up on both
  timelines.

## How it works

```
mic stream  ──→  energy gate (RMS, hysteresis, ≥300 ms hold)
                      │
                      ├── below threshold → drop
                      │
                      └── above threshold → event window
                                                │
                                                ▼
                                        YAMNet classifier
                                        (0.96 s frames, averaged)
                                                │
                                                ▼
                                        .opus clip + SQLite row
```

The event window starts with the last 2 s from an always-on ring buffer
(pre-roll), continues until the gate closes, and captures 1 s of tail.
Adjacent events less than 4 s apart are merged into one row.

A few decisions worth calling out:

- **Permissive amplitude gate, not a speech VAD.** WebRTC VAD and Silero VAD
  are trained on speech; snoring is rhythmic non-speech and gets gated out.
  The RMS-with-hysteresis gate keeps everything noisy and lets the classifier
  disambiguate snore vs talk vs cough.
- **2 s pre-roll** lets the gate fire conservatively without clipping the
  start of an event — when the gate opens, the lead-in is already in hand.
- **4 s event merge.** Snoring is rhythmic; without merging, every breath
  cycle would be its own row.
- **Calibrated threshold.** Set at first-run calibration and re-estimated
  each night from the quietest minute of the session. No universal magic
  number — different rooms, mics, and phone positions all need different
  thresholds.

## Labels

YAMNet exposes 521 AudioSet classes. The app renders a curated subset;
everything else collapses into `Other`:

```
Snoring, Speech, Cough, Sneeze, Snort, Belch,
Fart, Throat clearing, Hiccup, Whisper,
Cat, Dog, Other
```

The full per-class confidence map is still stored in `labels_json`, so the
whitelist can change later without re-classifying old events.

**Display label precedence (UI):** `user_label` if set, else `top_label` if
its confidence ≥ 0.4, else `Other`.

## Stack

| Layer            | Choice                                                         |
| ---------------- | -------------------------------------------------------------- |
| App framework    | Flutter (Android + iOS, single codebase)                       |
| Audio capture    | `record` (lighter than `flutter_sound`, cleaner iOS background)|
| Codec            | Opus, 24 kbps mono 16 kHz                                      |
| Classifier       | YAMNet via `tflite_flutter` (~4 MB model)                      |
| Event metadata   | SQLite via `drift`                                             |
| Audio files      | App-private storage (`getApplicationDocumentsDirectory`)       |

## Architecture

Components:

- **RecorderService** — owns the mic. Foreground service on Android with
  `foregroundServiceType="microphone"`; background audio session on iOS with
  `UIBackgroundModes: ["audio"]`. Survives screen lock.
- **Calibrator** — 30 s first-run noise-floor sample + per-night refinement
  from the quietest minute. Persists per-device.
- **Gate** — RMS hysteresis (open at `T_high`, close at `T_low`, ≥300 ms
  hold), threshold supplied by `Calibrator`. Owns the 2 s pre-roll ring
  buffer.
- **EventWriter** — encodes Opus, names files (`YYYY-MM-DD/HH-MM-SS.opus`),
  merges events whose gaps are < 4 s.
- **Classifier** — wraps the YAMNet TFLite model, runs on 0.96 s frames,
  averages per-class confidence over the event window, maps to the curated
  label set.
- **EventRepo** — SQLite. One row per event.
- **Janitor** — periodic background pass. Hard-deletes soft-deleted rows and
  their files; auto-deletes unstarred events older than the retention window.
- **TimelineUi** — events for the most recent night plus a date picker for
  older nights. Tap → play with a waveform; swipe → delete; long press →
  label / star.

### Data model

```sql
events (
  id           INTEGER PRIMARY KEY,
  started_at   INTEGER NOT NULL,    -- epoch ms
  ended_at     INTEGER NOT NULL,
  duration_ms  INTEGER NOT NULL,
  top_label    TEXT,                -- from the curated set
  labels_json  TEXT,                -- full per-class confidence map
  audio_path   TEXT NOT NULL,       -- relative to app docs dir
  starred      INTEGER NOT NULL DEFAULT 0,
  user_label   TEXT,                -- manual override
  deleted_at   INTEGER              -- soft delete; janitor removes file
);

CREATE INDEX events_started_at_idx ON events(started_at);
CREATE INDEX events_deleted_at_idx ON events(deleted_at);
```

**Retention:** janitor deletes unstarred events with `started_at` older than
14 days. Starred events are kept indefinitely. Window is configurable in
settings.

**Storage budget:** at 24 kbps Opus, an event-only night is roughly 20–30 MB.
The default 14-day window keeps the app under ~500 MB.

Soft-delete + cleanup pass means "delete" in the UI is instant and the actual
file removal happens on the janitor's sweep — easier to undo, less I/O on
the recording hot path.

### Platform specifics

**Android**

- `RECORD_AUDIO`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`
- Persistent notification while recording (required by the OS, also serves as
  a visible "yes, the mic is on" indicator)
- Battery-optimization-exempt prompt on first run. OEMs (Samsung, Xiaomi)
  layer additional restrictions on top — workarounds documented as we hit
  them
- No `INTERNET` permission

**iOS**

- `NSMicrophoneUsageDescription` in `Info.plist`
- `UIBackgroundModes: ["audio"]`
- Keep `AVAudioSession` active continuously; iOS suspends apps that don't
- Orange status-bar dot will be visible all night — expected
- Distribution: TestFlight (90-day rotation) for the partner, Xcode sideload
  for self

## Roadmap

**v1 — ship the loop**

- Start/stop recording, runs through the night
- First-run 30 s calibration + per-night threshold refinement
- Energy-gated event extraction with 2 s pre-roll, 4 s event merge
- YAMNet classification mapped to the curated label set
- Morning timeline: list, play, delete, star, manual relabel
- 14-day retention janitor
- Local-only, no network permission

**v2 — make the data useful**

- Multi-night stats ("you snored 47% of last night, +12% over last week")
- Per-night summary with peak loudness, total snore time, event count
- Custom user-defined labels

**Later — maybe**

- Auto-stop heuristics (no events for N hours → recording probably ended)
- Fine-tuning YAMNet on your own labeled events
- Export a night as a single archive (JSON manifest + clips)

## Build & run

> Setup instructions land here once the Flutter project is scaffolded. Will
> cover: Flutter SDK version, `flutter pub get`, running on a connected
> device, and the iOS provisioning steps for installing on the partner's
> phone.

## License

MIT. (Open to changing this — flag it if you'd rather keep it
source-available-but-unlicensed for personal use only.)
