# ovoz architecture

How the package is built, why, and how it differs from the first plan
(`audio-package-plan_1.md`, which stays as the record of what was intended).
What Mutolaa needs from it, and how Mutolaa adopts it, is in
`mutolaa-requirements.md`.

**Status (2026-10-05):** iOS engine working and tested end to end. Android
not started. Package name `ovoz` is a working name.

---

## 1. The shape

```
┌─ App ─────────────────────────────────────────────────────────────────┐
│  AudioPlayer (any number)                AudioSession (one per app)    │  public Dart API
│   queue · order · shuffle/loop · next/previous/jump · streams · events │  lib/src/audio_player.dart …
└───────────────┬───────────────────────────────────┬────────────────────┘
                │ PlayerEngine                      │ SessionEngine        core engine contract
                │ (mechanism, no playlist)          │                      lib/src/engine/
┌───────────────▼───────────────────────────────────▼────────────────────┐
│  DarwinPlayerEngine · DarwinSessionEngine   — the only Dart code that   │  lib/src/platform/darwin/
│  knows ffigen and Objective-C                (FakePlayerEngine in tests) │
└───────────────┬───────────────────────────────────▲────────────────────┘
   synchronous  │ calls and reads (FFI)              │ listener protocols, asynchronous
┌───────────────▼───────────────────────────────────┴────────────────────┐
│  OvozPlayer      AVQueuePlayer · two-item window · state machine        │  ios/ovoz/Sources/ovoz/
│  LoadedItem      AVURLAsset (+ AVURLAssetHTTPHeaderFieldsKey) → item    │
│  DecryptingResourceLoader → ByteSource (File | Http) → AesCtrCipher     │
│  OvozSessionManager (AVAudioSession)   NowPlayingCenter (MediaPlayer)   │
└─────────────────────────────────────────────────────────────────────────┘
```

### From the brief to the build

The brief: a **core engine** that does the real work but none of the
high-level things (next, previous, position streams), and **another class**
that offers those to the app. That is the shape built, with four
refinements:

1. **The core is per player, plus one app-wide session**, not one engine
   object. Mutolaa runs a book player and two quote-editor players at once,
   and the iOS audio session is process-wide; one object owning both would
   tangle them. `PlayerEngine` is the core for one stream, `SessionEngine` for
   the session.
2. **The playlist lives in Dart; native keeps a two-item window.** The plan
   had native own the playlist (D-03, D-04, PL-03). Native now only knows the
   current item and the one Dart cued after it. That is enough for gapless
   transitions and for advancing with the screen off (AVQueuePlayer moves into
   the cued item by itself), while order, shuffle, loop, "previous" and queue
   edits are written once — for iOS and, later, Android — and unit-tested
   against a fake engine. AVQueuePlayer cannot go backwards anyway, so an iOS
   playlist would have been hand-written in Swift in any case, and again in
   Kotlin.
3. **Lock-screen and headset commands go through Dart.** The native side
   receives them (so they work in the background) and hands them to the
   owning `AudioPlayer`, which applies them through its own methods. App rules
   — Mutolaa's quote-flow hold, its advertisement — therefore apply to a
   headset click exactly as to a button in the app. `MediaControls.onCommand`
   lets the app intercept any command.
4. **The engine contract is transport-agnostic.** `PlayerEngine` speaks Dart
   types only. FFI is one implementation; a jnigen or Pigeon Android engine
   is another; `FakePlayerEngine` is a third, which is what makes the queue and
   player logic testable without a device.

---

## 2. Decisions

Confirmed (✓) or changed (Δ) against the plan.

| ID | Decision | |
|---|---|---|
| D-02 | Dart ↔ Swift through ffigen + `package:objective_c`, `@objc` Swift classes, no method channels. **Proved in a spike before building on it:** synchronous calls from Dart run on the main thread; a Dart-implemented listener receives callbacks from any thread. | ✓ |
| D-03 / D-04 / PL-03 | Native owns players, decryption, session and lock screen, but **not the playlist**: a two-item window (current + cued). See §1.2. | Δ |
| — | **HTTP headers through `AVURLAssetHTTPHeaderFieldsKey`**, not through the resource loader. The plan routed headers through a custom-scheme resource loader, which cannot serve HLS: AVFoundation never asks a resource loader for segments. Mutolaa streams HLS with a bearer token, so this was a blocker. The key is what Flutter's `video_player` uses. | Δ |
| D-05 / D-06 | AES-CTR in memory through `AVAssetResourceLoaderDelegate`; pluggable byte sources (file, HTTP ranges) and cipher. | ✓ |
| ENC-02 / D-12 | **Answered:** Mutolaa's files are AES-128-CTR with the IV passed separately (no header), and the IV is a full 128-bit big-endian counter. Proved by a cross-implementation test against the same `encrypt` calls Mutolaa makes, including the counter carry. | ✓ |
| — | The keystream is built from AES-ECB of counters we compute, not CommonCrypto's CTR mode, so the counter arithmetic cannot differ from the encryptor's. | new |
| ENC-07 | Wrong key → `decryption` error, from the format signature of the first decrypted bytes, within milliseconds. | ✓ |
| ENC-06 | Keys are copied once into an engine-owned buffer, zeroed on release (`SecureBytes`), never logged. | ✓ |
| D-07 / EVT-03 | Position, buffered position and duration are synchronous reads; Dart polls them only while a stream is listened to. | ✓ |
| D-08 | CocoaPods **and** Swift Package Manager, both run against the integration tests. The ffigen trampolines are their own SwiftPM target (a target cannot mix Swift and Objective-C). | ✓ |
| D-09 | iOS 15: Mutolaa's target, and Xcode 27's minimum. | ✓ |
| D-10 | Needs merged UI/platform threads (Flutter ≥ 3.29 default on iOS). Built and tested on Flutter 3.44.4; `objective_c` 9.5 needs Dart ≥ 3.10. | ✓ |
| D-11 | `ovoz`, working name. | open |
| D-15 / BG-02 | One owner of the lock screen; the last player to enable media controls takes it (explicit transfer). | ✓ |
| SES-04 | `pauseAndResume` honours the system's `shouldResume`. Mutolaa resumes regardless today: a team decision. | Δ? |
| SES-05 | The session is activated on first play, never deactivated unless `deactivateWhenIdle` (deactivating can make the system forget the now-playing app). | ✓ |
| BG-04 | `MPNowPlayingInfoCenter.playbackState` is set explicitly; without it MediaRemote reported the app paused while it played. | new |
| PL-05 / PL-06 | `previousRestartThreshold` (zero = always previous); `maxSkipsOnError` (zero = stop, like Mutolaa's fork). A failed item is retried by `play()`. | ✓ |
| — | `play()` returns immediately (just_audio's completes when playback ends). `stop()` keeps queue and position. `ItemCompleted` is sent once per natural end, never for skips. | new |

---

## 3. The native engine

**`OvozPlayer`** owns one `AVQueuePlayer`. `setItem` replaces its contents;
`setNextItem` cues one item behind the current one. `actionAtItemEnd` is
`.advance` only while something is cued and `pauseAtItemEnd` is off, so the
player never runs past its window and the last item stays loaded at its end
(seek back or replay work). State is computed, not tracked: item status,
`timeControlStatus` (only `.toMinimizeStalls` counts as buffering, so a play
never flashes a spinner), a pending start position, the end flag. It is
emitted only when it changes. Start positions are applied once the item can
seek, and playback is held back until then, so an item never sounds from the
wrong place.

Events: `onItemStarted`, `onItemEnded` (deduplicated across the race between
the end notification and the queue's advance), `onDurationChanged`, `onError`
(the resource loader's diagnosis wins over AVFoundation's generic "cannot
open"), `onStateChanged`, `onRemoteCommand`.

**`DecryptingResourceLoader`** prepares once per item: total length, IV (given
or from the header), and the signature check. Then it serves each
AVFoundation request by reading the matching ciphertext from its
`ByteSource` in 256 KB chunks and decrypting it on the way through, yielding
the queue between chunks so cancellations (seeks) take effect at once. It
owns the requests it accepted: AVFoundation does not keep them alive.

**`HttpByteSource`** probes with a ranged GET, requires `206` and an
uncompressed body (anything else is `rangeNotSupported`), sends the app's
headers with every request, and resumes dropped transfers twice with backoff.

**`OvozSessionManager`** applies the app's configuration lazily, activates the
session before the first play, and turns interruptions and unplugged
headphones into the configured behaviour for every player.

**`NowPlayingCenter`** publishes metadata, elapsed time, rate and queue
position for the owning player, registers the enabled remote commands, loads
artwork (`https:`, `file:`, `asset:`), and forwards commands to the owner.

---

## 4. Threads and lifetimes

- Dart calls arrive on the main thread (merged threads); every public engine
  method asserts it in debug builds (IO-01). Calls from background isolates
  are unsupported (IO-02).
- AVFoundation callbacks hop to the main thread before touching state.
  Resource loading runs on one serial queue per item, byte-source callbacks
  included, so the loader needs no locks.
- Native → Dart events are posted to the isolate (asynchronous). The Dart
  adapter ignores events that arrive after `dispose`.
- The native player holds its listener; the listener's closures hold the Dart
  adapter only weakly, so no reference cycle spans the two garbage
  collectors. A `Finalizer` disposes a native player whose `AudioPlayer` was
  dropped without `dispose` (IO-03).

---

## 5. Building the bindings

`tool/generate_bindings.sh`:

1. `swiftc` writes the Objective-C header for every engine file except
   `OvozPlugin.swift` (the only file that imports Flutter):
   `ios/ovoz/Sources/ovoz_ffi/include/ovoz_objc_api.h`.
2. ffigen (`tool/ffigen.dart`) reads it and writes
   `lib/src/platform/darwin/ovoz_bindings.g.dart` plus the Objective-C
   trampolines Dart callbacks need, `ios/ovoz/Sources/ovoz_ffi/ovoz_bindings.g.m`.

Both outputs are committed. Run the script after changing any `@objc`
declaration. The Swift classes are found by name in the Objective-C runtime;
`OvozPlugin.register` names them so the linker keeps them. A release build was
checked: the stripped framework still exports the trampolines and classes.

---

## 6. Tests

| Level | What | Run | Count |
|---|---|---|---|
| Cross-implementation | OpenSSL test vectors decrypt with Mutolaa's own PointyCastle code, whole and at 200 random offsets; counter carry; AES-256 + IV in header | `flutter test test/cross_implementation_test.dart` | 5 |
| Native, macOS | cipher (500 random ranges), file and HTTP byte sources (ranges, auth, 200-instead-of-206, compression, dropped connections), resource loader with AVFoundation (load, wrong key, HTTP), AVPlayer playback + exact seek to the end | `cd ios/native_tests && swift test` | 19 |
| Dart unit | queue order/shuffle/loop; player against `FakePlayerEngine`: loading, interruption of loads, failures and retry, advancing, loop one/all, pause at item end, navigation, stop/resume, queue edits, skip on error, media commands, streams | `flutter test` | 35 |
| On device (simulator) | the real engine through the public API: encrypted MP3/AAC, exact seeks, initial positions, gapless advance with exactly-once completion, pause at item end, clip loop, next/previous/jump, stop/resume, wrong key, missing file, simultaneous players, encrypted HTTP streaming with a bearer token, header-only streaming, refused requests | `cd example && flutter test integration_test -d <id>` | 15 |

Checked by hand on the simulator: the demo screens; the lock screen and
Dynamic Island show title, artist and artwork; MediaRemote receives all
enabled commands, duration, elapsed time and the playing state; chapters
advance with the screen locked.

**Still needs a real device:** pressing lock-screen and headset buttons, a
phone-call interruption under each policy, Bluetooth and AirPlay route
changes, 60+ minutes with the screen off, memory over long sessions
(Instruments), and a release build running.

---

## 7. Next

1. **Device checklist** above, then adopt in Mutolaa behind `PlayerBackend`
   on iOS (`mutolaa-requirements.md` §4).
2. **Android engine** behind the same `PlayerEngine`: Media3 ExoPlayer with a
   two-item window (`setMediaItems` of current + next), an AES-CTR
   `DataSource`, and a `MediaSessionService` owning the media-controls player.
   jnigen (as planned) keeps calls synchronous; Pigeon is the lower-risk
   option if jnigen fights Media3's service model. The Dart queue and all its
   tests carry over unchanged.
3. Smaller items: a "stalled" engine event from `AVPlayerItemPlaybackStalled`;
   recovery after media-services reset; an opt-in precise-duration flag for
   VBR MP3 without a Xing header; an on-demand key provider; a ciphertext
   disk cache for remote encrypted files; Opus/Ogg (needs a decoder);
   CarPlay.
