# ovoz architecture

How the package is built, why, and how it differs from the first plan
(`audio-package-plan_1.md`, which stays as the record of what was intended).
What Mutolaa needs from it, and how Mutolaa adopts it, is in
`mutolaa-requirements.md`.

**Status (2026-10-08):** iOS and Android engines working and tested end to
end, behind one Dart API. Package name `ovoz` is a working name.

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
│  AndroidPlayerEngine · AndroidSessionEngine — the only Dart code that   │  lib/src/platform/android/
│  knows jnigen and Java                                                  │
└───────────────┬───────────────────────────────────▲────────────────────┘
   synchronous  │ calls and reads (FFI / JNI)        │ listeners, asynchronous
┌───────────────▼───────────────────────────────────┴────────────────────┐
│ iOS                                                                     │  ios/ovoz/Sources/ovoz/
│  OvozPlayer      AVQueuePlayer · two-item window · state machine        │
│  LoadedItem      AVURLAsset (+ AVURLAssetHTTPHeaderFieldsKey) → item    │
│  DecryptingResourceLoader → ByteSource (File | Http) → AesCtrCipher     │
│  OvozSessionManager (AVAudioSession)   NowPlayingCenter (MediaPlayer)   │
├─────────────────────────────────────────────────────────────────────────┤
│ Android                                                                 │  android/src/main/kotlin/uz/sayma/ovoz/
│  OvozPlayer      ExoPlayer · two-item playlist · state machine          │
│  LoadedItem      MediaItem (+ clip) → MediaSource (progressive | HLS)   │
│  AesCtrDataSource → File | Asset | DefaultHttpDataSource → AesCtrCipher │
│  SessionManager (audio focus)    MediaControls → MediaSession (Media3)  │
│  NetworkMonitor                  OvozPlaybackService (foreground)       │
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
   edits are written once — for iOS and Android — and unit-tested
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
   types only. FFI to Swift is one implementation, JNI to Kotlin another, and
   `FakePlayerEngine` a third, which is what makes the queue and player logic
   testable without a device. Both native engines exchange the same numbers
   (enum indices and bit sets, `NativeCodec`).

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
| — | Local encrypted files are read on demand (`isEntireLengthAvailableOnDemand`): a 300 MB chapter costs no more memory than a plain file. See §5. | new |
| IO-03 | A player lives until `dispose()`, referenced or not; dropped players are not finalized (that let a player be collected mid-load). See §4. | Δ |
| D-07 / EVT-03 | Position, buffered position and duration are synchronous reads; Dart polls them only while a stream is listened to. | ✓ |
| D-08 | CocoaPods **and** Swift Package Manager, both run against the integration tests. The ffigen trampolines are their own SwiftPM target (a target cannot mix Swift and Objective-C). | ✓ |
| D-09 | iOS 15: Mutolaa's target, and Xcode 27's minimum. | ✓ |
| D-10 | Needs merged UI/platform threads (Flutter ≥ 3.29 default on iOS). Built and tested on Flutter 3.44.4; `objective_c` 9.5 needs Dart ≥ 3.10. | ✓ |
| D-11 | `ovoz`, working name. | open |
| D-15 / BG-02 | One owner of the lock screen; the last player to enable media controls takes it (explicit transfer). | ✓ |
| SES-04 | `pauseAndResume` honours the system's `shouldResume`. Mutolaa resumes regardless today: a team decision. Only players that would be heard are paused and resumed: one whose queue has ended stays ended (it was replayed before 0.1.0-dev.5). | Δ? |
| SES-05 | The session is activated on first play, never deactivated unless `deactivateWhenIdle` (deactivating can make the system forget the now-playing app). | ✓ |
| BG-04 | `MPNowPlayingInfoCenter.playbackState` is set explicitly; without it MediaRemote reported the app paused while it played. | new |
| PL-05 / PL-06 | `previousRestartThreshold` (zero = always previous); `maxSkipsOnError` (zero = stop, like Mutolaa's fork). A failed item is retried by `play()`. | ✓ |
| — | `play()` returns immediately (just_audio's completes when playback ends). `stop()` keeps queue and position. `ItemCompleted` is sent once per natural end, never for skips. | new |
| — | **Stalls are the Dart player's call**, under an opt-in `StallPolicy`. It times a wait from the states the engine already reports: loading or buffering (on iOS, AVPlayer waiting `.toMinimizeStalls`) while playing or while a `setSource` waits. Then it reloads the item once in a new instance (new connections; a waiting `setSource` follows it), and gives up with a `network` `ItemFailed`. Idle neither starts nor ends a wait: the engine reports idle for a moment whenever it replaces an item (the `timeControlStatus` observer runs inside `removeAllItems`), which at first restarted the clock on every reconnect; `FakePlayerEngine` now does the same. Without a policy a quiet connection waits for the platform: for an encrypted stream, URLSession's 60 s timeout, retried twice. | new |
| — | **The network is a fact the engine reports** (`NWPathMonitor`, shared by all players: `isNetworkAvailable` and `onNetworkChanged`); what to do about it is the policy's. Offline, waits are not timed and never given up on. The network coming back or changing interface reloads a waiting item at once (and makes the next wait reload at once, the old connections being suspect). A `network` failure of the current item becomes a wait: the player keeps the position, reports itself playing and buffering while the engine's item is dead, and loads the item again after `reconnectAfter` (at most 2 s), or when the network returns. `fail()` now reports the error before the state it causes: stopping playback fires the `timeControlStatus` observer at once, and Dart must still see that playback was wanted. Giving up pauses the engine rather than stopping it: the item stays current, so the lock screen shows it paused instead of going blank, and `play()` loads it again; the player reports it idle meanwhile. A failed item keeps where it failed (`failedAt`, its pending start if it never got there), which `positionMs` reports: dropping the pending start first made a chapter that failed on its way to minute 25 resume at zero. | new |
| D-19 | **Android plays on Media3 1.11 ExoPlayer** (chosen with the team, 2026-10-08), not the legacy ExoPlayer 2.19.1: that one has been frozen since 2023, and it is the library Mutolaa's just_audio fork pins (2.18.7), so Gradle would have forced one version on both. Media3 also brings `media3-session`, which runs the foreground service and the notification. Needs minSdk 23 and compileSdk 36. | new |
| D-20 | **Dart ↔ Kotlin through jnigen 1.0.1 + `package:jni` 1.1** (chosen with the team), not Pigeon: synchronous calls on the platform thread, as with ffigen (merged threads are the default on Android since Flutter 3.29; ExoPlayer requires its own thread, which is that one). Listener methods are implemented in Dart as listeners (`$async`): `package:jni` posts them to the isolate even from the same thread, the delivery iOS has. The bindings cover the engine's public API only (five classes); internals are `internal` and `@JvmSynthetic`, so jnigen does not see them. | new |
| — | **The two-item window is ExoPlayer's playlist**: the current item at index 0, the cued one at 1. ExoPlayer advances into the cue gaplessly by itself, and the item just left is removed at once. A cue that arrives after the current item ended is moved into at once (and played, if playback is still wanted), as AVQueuePlayer does; with pause at item end on, the player stays at the end, as on iOS. An integration test pins this down on both platforms. | new |
| — | **Pause at item end** is ExoPlayer's `pauseAtEndOfMediaItems`, set only while something is cued; at the pause the cued item becomes current, paused at its start, as on iOS. With nothing cued the last item ends normally (completed). | new |
| — | **A cued item that cannot load is reported before it is reached.** Media3 raises playback errors only for the item playing; a load error of the cued item that will never be retried arrives through `AnalyticsListener.onLoadError` with the item's media id, and is reported then, the cue dropped (`wasCanceled` alone is not enough: ExoPlayer also cancels a load it restarts later, on streams of unknown length). A network failure keeps being retried, and fails the item once it is current, where a `StallPolicy` takes over. | new |
| — | **Retries**: a failed load is retried twice, after 0.5 and 1 s (the iOS HTTP source's numbers); a load that made progress starts counting again. The engine's own diagnoses and 4xx answers (except 408 and 429) are never retried. | new |
| — | **Decryption is a Media3 `DataSource`** wrapping the file, asset or HTTP source, with the iOS cipher's counter arithmetic (AES-ECB keystream of counters we compute). The item's length, IV and wrong-key check are prepared once and shared by every source ExoPlayer opens; a failure the engine diagnosed is kept, a network failure is not. Remote reads are always closed ranges and must come back as 206, uncompressed, starting where asked (`rangeNotSupported` otherwise): stricter than Media3, which would skip bytes after a 200, but the same contract as iOS. | new |
| ENC-06 | On Android the key reaches Kotlin in a Java array written element by element (no temporary native buffer), is copied into `SecureBytes` and the array zeroed; the engine's copy is zeroed when the item leaves the window. Each cipher's copy inside the crypto provider is freed with the cipher. | ✓ |
| — | **Audio focus is held by the app, not by players** (`SessionManager`): Android tracks focus per request, so two players asking on their own would take it from each other. Players play with `handleAudioFocus` off; the session requests focus at the first play and turns its loss into the `InterruptionPolicy`. Presets map to Android audio attributes and focus types (`effectiveAndroidAudio`); `androidAudio` overrides them (SES-03). A transient loss pauses and resumes; a lasting one pauses for good; `none` pauses nothing, since Android silences no one by itself. Every request uses one listener (Android tells requests apart by it, so two of the app's own would take focus from each other), focus is not requested again while held, and during a transient loss the request stays registered, to hear focus come back, while the app counts as not holding it: a play during a call is refused, as on iOS. Where the system does not duck the app itself (before Android 8), ovoz lowers every player's volume. Only players that would be heard are paused and resumed: one whose queue has ended stays ended. Focus is given back when the last Flutter engine goes. | new |
| — | **Lock screen and notification through a stand-in player.** The media session wraps a Media3 `SimpleBasePlayer` that shows the owner's item and state and forwards every command to the owner's Dart listener (the `NowPlayingCenter` model). Skip buttons take the back and forward places, as on iOS. A failed or given-up item is shown paused, still there; stopping or releasing the controls takes the notification away. | new |
| D-16 | The app declares `OvozPlaybackService` and the foreground-service permissions; the plugin's manifest declares `ACCESS_NETWORK_STATE`, which its network monitor needs (Media3's add it too, and `WAKE_LOCK`). While a player owns the controls, a `MediaController` keeps the service connected; when the last owner goes, the service is stopped (`pauseAllPlayersAndStopSelf`), which Media3 leaves to the app. | ✓ |
| — | **Players end with the last Flutter engine.** When Android destroys the app's activity with its engine, nothing could cue the next item or answer a command, so every player is disposed. Apps that keep playing after the activity is gone keep the engine alive (as audio_service's `AudioServiceActivity`, which Mutolaa uses, does). | new |
| — | **The Android network monitor** is the default-network callback of `ConnectivityManager`, reporting a change of availability or of interface (a move from Wi-Fi to cellular arrives as a short loss followed by the new network, which the policy treats as a switch). | new |

---

## 3. The native engines

### iOS

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
For local files it declares the content available on demand
(`isEntireLengthAvailableOnDemand`, iOS 16+), so AVFoundation reads 64 KB
just before playing it, as from a plain file, instead of prefetching; see §5.

**`HttpByteSource`** probes with a ranged GET, requires `206` and an
uncompressed body (anything else is `rangeNotSupported`), sends the app's
headers with every request, and resumes dropped transfers twice with backoff.

**`OvozSessionManager`** applies the app's configuration lazily, activates the
session before the first play, and turns interruptions and unplugged
headphones into the configured behaviour for every player.

**`NowPlayingCenter`** publishes metadata, elapsed time, rate and queue
position for the owning player, registers the enabled remote commands, loads
artwork (`https:`, `file:`, `asset:`), and forwards commands to the owner.

### Android

**`OvozPlayer`** owns one ExoPlayer on the main looper. `setItem` replaces
its playlist with the item's media source at the start position;
`setNextItem` adds the cued item behind it, and drops a previous cue. When
ExoPlayer advances into the cue (a transition of reason `AUTO`), the item
just finished is reported ended and removed, so the playlist is always the
current item and its cue. State is computed, as on iOS: `loading` until the
item has been ready once, `buffering` only while playback is wanted (so a
seek while paused shows no spinner), `completed` when the last item has
ended. ExoPlayer applies start positions itself and plays nothing before
them. A failure is reported before the idle state it causes, and the item
keeps where it failed (`failedAt`, its start position if it never got there).
Replacing an item stops ExoPlayer first: it prepares only from idle, and an
error of the old item still on its way from the playback thread would
otherwise reach the new one, which would never load.

**`LoadedItem`** builds the media source: `file:` and Flutter assets
(`asset:///flutter_assets/…`, found through Flutter's lookup) through Media3's
`DefaultDataSource`, `http(s):` through `DefaultHttpDataSource` with the app's
headers, and progressive or HLS by the URL. A missing file or asset fails at
once. MP3 and ADTS files without a seek table seek by bitrate.

**`AesCtrDataSource`** wraps the item's source. The first open prepares the
item (length, IV, signature check) through `EncryptedResource`, shared by
every source ExoPlayer opens for it; each open then reads the matching
ciphertext range and decrypts it in place as ExoPlayer reads, on
ExoPlayer's loading thread.

**`SessionManager`** holds audio focus for the app, sets every player's
audio attributes, and turns focus changes, unplugged headphones and output
devices into the configured behaviour and session events.

**`MediaControls`** owns the media session and the stand-in player it shows,
and connects to `OvozPlaybackService` while a player owns the controls.
Artwork loads through Media3's bitmap loader (`https:`, `file:`, Flutter
assets).

**`NetworkMonitor`** watches the default network and tells every player when
it goes away, comes back or changes interface.

---

## 4. Threads and lifetimes

- Dart calls arrive on the main thread (merged threads); every public engine
  method asserts it in debug builds (IO-01). Calls from background isolates
  are unsupported (IO-02). On Android the check is in release builds too,
  with a message that names merged threads: ExoPlayer refuses calls from
  any other thread anyway.
- AVFoundation callbacks hop to the main thread before touching state.
  Resource loading runs on one serial queue per item, byte-source callbacks
  included, so the loader needs no locks. On Android, ExoPlayer calls its
  listeners on the main looper; its loading threads run the decrypting
  source, whose shared per-item state is synchronized.
- Native → Dart events are posted to the isolate (asynchronous). The Dart
  adapter ignores events that arrive after `dispose`. With jnigen, listener
  methods are posted even when Java calls them on the isolate's own thread.
- **A player lives until `dispose()`** (IO-03), whether or not the app still
  references it, as in other audio plugins: the Dart adapters are held in a
  registry from creation to `dispose`. An earlier version held them only
  weakly and finalized dropped players, and a player whose only reference was
  an async function awaiting its own load could be garbage-collected
  mid-load: the load never completed. An integration test pins this down.
  The flip side: a player that is never disposed is never freed.
- On Android, the players end with the last Flutter engine (`OvozPlugin` is
  told when the engine detaches): see the decisions above.

---

## 5. Memory

Nothing is loaded whole. The Dart queue holds descriptors (a few hundred
bytes each); natively only the current item and the one cued after it are
open, and a finished item is released as the player moves on.

Within an item, AVFoundation decides how much to read ahead. Measured with a
300 MB, 6-hour encrypted MP3 (2026-10-05):

| | macOS process footprint | iOS app footprint (idle app: ~126 MB) |
|---|---|---|
| Plain local file (AVFoundation reads it itself) | 10 MB | — |
| Encrypted, before on-demand loading | 43 MB, 74 MB peaks | 163 MB, 175 MB peak on a seek |
| Encrypted, on demand (current) | 11 MB | 126–131 MB with three such chapters queued, through two chapter changes and a seek to 2 h 30 m |

Without on-demand loading, AVFoundation treats the loader's custom scheme
like a network stream: it asks for everything to the end of the file and
keeps 30–50 MB of what it receives, whatever the file's size; seeks repeat
that. `preferredForwardBufferDuration` did not change it, and answering in
smaller pieces did not either (AVFoundation simply asks again). Declaring
the content available on demand did: AVFoundation then reads what it is about
to play, 64 KB at a time, about 128 KB for 1.5 s of audio
(`testReadsALocalFileOnDemand`).

Encrypted HTTP sources keep the prefetch, because on demand every 64 KB would
cost a round trip; their memory is that of any progressive download. On
iOS 15, local files prefetch too (the API is iOS 16+): bounded, not
growing.

On Android, ExoPlayer buffers by duration, not by file: about 50 s of
compressed audio ahead (its default), whatever the source, encrypted or
not, local or remote. A 300 MB chapter costs what a 3 MB one does; the iOS
problem above does not arise.

---

## 6. Building the bindings

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

`tool/generate_bindings.sh android`:

1. The example app's Gradle build compiles the Kotlin engine
   (`:ovoz:compileDebugKotlin`).
2. jnigen (`tool/jnigen.dart`) reads the class files of the five public
   classes and writes `lib/src/platform/android/ovoz_bindings.g.dart`.

The output is committed. jnigen turns `setX` methods with one argument into
Dart setters (`nextItem =`, `speed =`). The Kotlin classes are compiled
without `javaParameters`, so the generated parameters are named `i`, `j`,
`z`: jnigen 1.0.1 copies the name Kotlin gives property setters' parameters,
`<set-?>`, into invalid Dart. The plugin's R8 rules keep the five classes and
their members by name; a release build was checked.

The plugin's Gradle file applies the Kotlin plugin only when nothing else
does: Flutter 3.44+ applies it to plugins itself, AGP 9 can compile Kotlin on
its own, and Flutter 3.38–3.43 leave it to the plugin. Builds were checked
with AGP 9.0.1 and Kotlin 2.3.20 (Flutter's template) and with AGP 8.13,
Kotlin 2.2.20 and Gradle 8.14.3 (Mutolaa's). Android Lint runs clean
(`:ovoz:lintDebug`); it caught the one call above `minSdk` 23, the
default-network callback (API 24), which Android 6.0 replaces by reading the
active network on any network's change.

---

## 7. Tests

| Level | What | Run | Count |
|---|---|---|---|
| Cross-implementation | OpenSSL test vectors decrypt with Mutolaa's own PointyCastle code, whole and at 200 random offsets; counter carry; AES-256 + IV in header | `flutter test test/cross_implementation_test.dart` | 5 |
| Native, macOS | cipher (500 random ranges), file and HTTP byte sources (ranges, auth, 200-instead-of-206, compression, dropped connections), resource loader with AVFoundation (load, wrong key, HTTP, on-demand reading of a 16 MB file), AVPlayer playback + exact seek to the end | `cd ios/native_tests && swift test` | 20 |
| Dart unit | queue order/shuffle/loop; player against `FakePlayerEngine`: loading, interruption of loads, failures and retry, advancing, loop one/all, pause at item end, navigation, stop/resume, queue edits, skip on error, stalls (reconnect, give up, a load retried, recovery and pause ending a wait), the network (offline waits, its return, a switch, dropped connections retried or given up on, pausing a wait), media commands, streams; Android audio derived from the session presets | `flutter test` | 49 |
| Kotlin, JVM | cipher against the same vectors (500 random ranges, counter carry, AES-256 + IV in header, bad lengths, a released key), format signatures | `cd example/android && ./gradlew :ovoz:testDebugUnitTest` | 7 |
| Kotlin, on Android | the decrypting source over files and over HTTP (ranges with a bearer token, 200 instead of 206, compression, another range than asked, a refused request), the IV in the header, a wrong key failing at once and every time, ExoPlayer playing and seeking within 100 ms inside an encrypted file | `cd example/android && ./gradlew :ovoz:connectedDebugAndroidTest` | 9 |
| On device (simulator, emulator) | the real engine through the public API, the same tests on both platforms: encrypted MP3/AAC, exact seeks, initial positions, gapless advance with exactly-once completion, pause at item end, clip loop, next/previous/jump, stop/resume, wrong key, missing file, simultaneous players, encrypted HTTP streaming with a bearer token, header-only streaming, refused requests, a player kept alive only by its own pending load, a server that goes quiet (retried, then given up on; or coming back), a server that is down (tried again until it is back, keeping its start position), a failed load keeping the position it was to start at, an item added after the queue completed playing at once; on iOS, interruptions and route changes as AVAudioSession posts them (pause and resume, an ended queue staying ended, every route-change reason) | `cd example && flutter test integration_test -d <id>` | 24 (21 on Android) |

Checked by hand on the simulator: the demo screens; the lock screen and
Dynamic Island show title, artist and artwork; MediaRemote receives all
enabled commands, duration, elapsed time and the playing state; chapters
advance with the screen locked.

Checked by hand on an Android 16 emulator (API 36): the demo screens; the
media session shows title, artist, album, artwork, the playing state and the
skip buttons; next and pause from media keys and skip from the notification
go through Dart; the service runs in the foreground while playing; chapters
advance with the app in the background and the screen off; disposing the
player removes the notification; an incoming call pauses and its end resumes
(`pauseAndResume`, speech focus); unplugged headphones pause; the network
monitor reports Wi-Fi going away, coming back and moving to cellular; Apple's
HLS test stream plays.

**Still needs a real device:** pressing lock-screen and headset buttons, a
phone-call interruption under each policy, Bluetooth and AirPlay route
changes, the network going away, coming back and moving from Wi-Fi to
cellular while streaming (screen on and locked), 60+ minutes with the screen
off, memory over long sessions (Instruments), and a release build running.
On Android the same, plus a phone that limits background work (Samsung,
Xiaomi), Android Auto, and an app whose engine outlives its activity.

---

## 8. Next

1. **Device checklist** above, then adopt in Mutolaa behind `PlayerBackend`,
   iOS first, then Android (`mutolaa-requirements.md` §4).
2. Smaller items: recovery after media-services reset; an opt-in
   precise-duration flag for VBR MP3 without a Xing header; an on-demand key
   provider; a ciphertext disk cache for remote encrypted files; Opus/Ogg
   (needs a decoder); CarPlay.
