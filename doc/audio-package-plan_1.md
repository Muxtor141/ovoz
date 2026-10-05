# FFI Audio Player for Flutter — Build Plan

**Scope of v1:** iOS only, plain and AES-CTR encrypted audio, local files and remote streaming.
**Later:** Android (Media3 + jnigen) behind the same Dart API.

Status markers: **LOCKED** = decided, **PENDING** = needs a decision before or during the phase that uses it.

---

## 1. Goals and principles

### Goals
- A just_audio-style player where **Dart talks to native directly** through generated FFI bindings (no MethodChannels).
- **Native owns everything that must survive the background**: player, playlist window, decryption, audio session, lock-screen controls. Dart is a remote control and observer.
- **Encryption is optional per source.** Plain and encrypted sources can be mixed in one playlist.
- Encrypted audio is decrypted **in memory inside the player pipeline**: no localhost proxy, no decrypted temp files, no ATS exceptions.

### General-purpose by design
The package is not built around one app. It provides general building blocks, and our own product will pick from the use cases they enable (section 2).

- **P-01 Primitives over use-case features.** Expose players, sources, playlists, session and background as independent building blocks. Nothing like "audiobook mode" is hardcoded in the native core.
- **P-02 Presets are shortcuts, not modes.** Every preset expands into a plain config the app can inspect and change.
- **P-03 Every default is overridable.** Session handling, interruption behavior, preloading, previous-track threshold, error skipping, polling rate.
- **P-04 Features are opt-in.** Encryption, background playback, lock-screen controls and session management stay off or neutral until the app enables them.
- **P-05 Escape hatches.** The app can take over the audio session completely and still get correct player state.
- **P-06 Extensible internals.** Byte sources and ciphers sit behind internal interfaces, so new source types or encryption schemes can be added without touching the player.

---

## 2. Supported use cases

These profiles check the design for generality. Each must be possible with the public API alone. The example app gets one demo screen per profile.

| ID | Use case | Building blocks used | v1 |
|---|---|---|---|
| USE-01 | Music player | Playlist, gapless, shuffle/loop, background, Now Playing, `music` session | Yes |
| USE-02 | Audiobooks / lessons (protected content) | Encrypted local + remote sources, speed with pitch correction, `speech` session, background | Yes |
| USE-03 | Podcast / radio streaming | Remote URLs with headers, HLS, buffering state, background | Yes |
| USE-04 | Language learning / practice | Clips (start/end), loop one, speed, seek precision, foreground only | Yes |
| USE-05 | UI sounds / SFX | Several lightweight players, `ambient` session (mix with other apps), no background | Yes (standard latency; low-latency engine is later) |
| USE-06 | Ambient / sleep sounds | Seamless looping, multiple simultaneous players (layers), per-player volume, background | Yes |
| USE-07 | Mixed: background music + SFX in one app | One background-enabled player plus foreground-only players under one session | Yes |
| USE-08 | Visualizers / analysis / DSP | PCM access, zero-copy buffers | Later (v2) |

---

## 3. Scope

### In v1
- Sources: local file, asset, remote URL (with optional headers, HLS), encrypted local file, encrypted remote file.
- Playback: play, pause, stop, seek, volume, speed (with pitch correction choice), clips (start/end), position/duration/buffered.
- Playlist: native-managed window, next/previous, seek to index, loop off/one/all, shuffle, insert/remove/move.
- Multiple player instances at the same time.
- App-wide audio session API with presets and full custom config.
- Opt-in background playback, Now Playing and lock-screen controls.

### Out of v1
- Android (Phase 6).
- DRM (FairPlay/Widevine).
- Disk caching of remote audio.
- PCM taps, visualizers, DSP (USE-08).
- Low-latency SFX engine (AVAudioEngine-based).
- Custom encryption for HLS. Plain HLS and standard HLS AES-128 work through AVPlayer directly.

---

## 4. Decisions

| ID | Decision | Status |
|---|---|---|
| D-01 | iOS first, Android later with the same Dart API | LOCKED |
| D-02 | Native helpers written in Swift, exposed as `@objc` classes, bound to Dart with ffigen + `package:objective_c` | LOCKED (swiftgen evaluated in Phase 0 as an alternative) |
| D-03 | Native owns the player, playlist window, decryption, session and remote commands; Dart never sits in the playback data path | LOCKED |
| D-04 | Playlist: Dart sends lightweight descriptors once; native creates items lazily (current + next) | LOCKED |
| D-05 | Encryption: AES-CTR in v1, optional per source, local and remote; cipher layer is pluggable (P-06) | LOCKED |
| D-06 | Decryption via `AVAssetResourceLoaderDelegate` + CommonCrypto, in-memory chunks | LOCKED |
| D-07 | Position: synchronous native getter, polled by Dart only while someone listens | LOCKED |
| D-08 | Distribution: Flutter plugin with CocoaPods podspec **and** SwiftPM | LOCKED |
| D-13 | **One package.** Player, session and background live in the same native engine. No separate background or session packages. | LOCKED |
| D-14 | **Audio session is an app-wide API**, separate from players (the session is process-wide on iOS) | LOCKED |
| D-15 | **Background playback is opt-in per player**; at most one player owns Now Playing and remote commands at a time | LOCKED |
| D-16 | **Platform declarations belong to the app** (Info.plist background mode; Android manifest service + foreground-service permission). The package ships the code, the README ships the snippets. | LOCKED |
| D-17 | Multiple player instances are supported and share one session | LOCKED |
| D-18 | Federated structure (platform interface + implementations) is not needed for v1; can be adopted later without public API changes | LOCKED |
| D-09 | Minimum iOS version | PENDING (proposal: iOS 15) |
| D-10 | Minimum Flutter version (needs merged UI/platform threads on iOS for safe sync calls) | PENDING (confirm in Phase 0) |
| D-11 | Package name | PENDING |
| D-12 | Exact IV/counter layout of existing encrypted files | PENDING (must confirm before Phase 2; see ENC-02) |

---

## 5. Architecture

```
┌──────────────────────── Dart (remote control) ────────────────────────┐
│  AudioPlayer (many)   AudioSessionManager (one)   AudioSource configs │
│  sync calls ──────────────────────┐        ▲ events (async listener)  │
└───────────────────────────────────┼────────┼───────────────────────────┘
                 ffigen bindings    ▼        │
┌──────────────────────────── Swift (native) ───────────────────────────┐
│  NASessionManager (app-wide)                                          │
│     category/mode/options · activation · interruptions · routes       │
│                                                                       │
│  NAPlayer (one per AudioPlayer)                                       │
│     ├─ AVQueuePlayer (current + next)                                 │
│     ├─ NAPlaylist        descriptors, order, shuffle, window          │
│     ├─ NAItemFactory     descriptor → AVPlayerItem                     │
│     ├─ NAResourceLoader  → NAByteSource (local | remote)               │
│     │                    → NACipher (AES-CTR | passthrough)            │
│     └─ NAObserver        KVO + notifications → state machine           │
│                                                                       │
│  NARemoteControl (owned by the one background-enabled player)         │
│     MPRemoteCommandCenter · MPNowPlayingInfoCenter                    │
└────────────────────────────────────────────────────────────────────────┘
```

- **Plain sources without headers** go straight to AVPlayer (best compatibility, including HLS).
- **Encrypted sources and URLs with custom headers** go through the resource loader on a custom URL scheme. Headers use a passthrough cipher, so header support needs no proxy.
- The loader is layered as **loader → byte source → cipher**, so each layer can be tested alone and extended (P-06).

---

## 6. Public API (overview)

Exact signatures are settled in Phase 0/1. These are the main parts and what each is responsible for.

### AudioPlayer (one per playback stream; many allowed)
- **Construction options:** background config (null = foreground-only), preload-next, max skips on error, previous-track threshold, position polling interval.
- **Sources:** set a single source or a list with an initial index and position; add, insert, remove, move, clear.
- **Commands:** play, pause, stop, seek (optionally to an index), next, previous, set volume, set speed (with pitch-correction choice: speech-quality vs music-quality), set clip (start/end), loop mode, shuffle.
- **Synchronous getters:** position, duration, buffered position, current index, playing, processing state.
- **Streams:** player state (playing + processing state), position (polled only while listened to), duration, buffered position, current index, sequence/shuffle order, errors.
- **Lifecycle:** explicit dispose, with a finalizer as safety net.

### AudioSource (descriptors, cheap to create)
- Types: file, asset, URL (with optional headers).
- Optional per-source **encryption config**: key, IV source (explicit bytes or file header with length), declared audio format.
- Optional **metadata** for Now Playing: title, artist, album, artwork (bytes or URL), and an app-defined ID.

### AudioSessionManager (app-wide singleton)
- Configure with a preset or a full custom config (section 9).
- Streams: interruptions (begin/end, should-resume), becoming noisy (headphones unplugged), route changes.
- Option to leave the session entirely to the app.

### BackgroundConfig (per player, opt-in)
- Whether to show Now Playing.
- Which remote commands to enable: play/pause, next, previous, seek, skip forward/backward with intervals.
- Seek-bar and skip-interval preferences (e.g. 15 s/30 s for speech).

### State model
`ProcessingState`: idle, loading, buffering, ready, completed (same model as just_audio, to ease migration).

### Errors
Source load failure, decryption failure (wrong key or format), network failure, server without byte-range support, invalid configuration (e.g. background with an ambient session).

---

## 7. Encryption spec

| ID | Rule |
|---|---|
| ENC-01 | AES-CTR, key size 128/192/256 bit, no padding. Ciphertext length = plaintext length. |
| ENC-02 | Counter: the full 16-byte IV is a 128-bit big-endian counter (PointyCastle / `encrypt` package behavior). **Confirm against existing files (D-12).** |
| ENC-03 | IV source: explicit bytes, or the first N bytes of the file (`dataOffset = N`). Ciphertext starts at `dataOffset`. |
| ENC-04 | Random access: start counter = IV + (offset ÷ 16); discard (offset mod 16) keystream bytes. |
| ENC-05 | The app declares the audio format, because AVPlayer cannot sniff a custom-scheme URL. Format maps to a UTI: mp3, m4a/aac, wav, flac, caf. |
| ENC-06 | Key handling: key bytes passed to native once at source creation, held in a native buffer, never logged, zeroed on dispose. The package never persists keys. Fetching and storing keys is the app's job (option: on-demand key provider, see open questions). |
| ENC-07 | Wrong-key detection: check the first decrypted bytes against the declared format's signature (ID3/MPEG frame sync, `ftyp`, `RIFF`, `fLaC`). On mismatch, raise a decryption error instead of an opaque AVFoundation error. |
| ENC-08 | Threat model, written in the docs: protects against copying and sharing files; does not protect against key extraction on a jailbroken device (that needs DRM). |

### Local encrypted files
- Random-access reads at `dataOffset + offset`, in chunks of about 128 KB.
- Respond progressively from the request's current offset; stream "to end of resource" requests in chunks; stop as soon as the request is cancelled.
- Content length = file size − `dataOffset`; byte-range access always enabled.

### Remote encrypted files
- **Probe** once per source with a small range request: total size from `Content-Range`, plus the IV when it's stored in the header.
- **Per request:** map the plaintext range to the ciphertext range (+ `dataOffset`), fetch with a `Range` header, and decrypt **incrementally** as bytes arrive.
- Cancel the network task when AVPlayer cancels the request (fast seeking).
- Require `206 Partial Content` and no content compression; otherwise raise the byte-range error with a clear message.
- Custom headers (auth) apply to the probe and all range requests.
- Retry transient network errors twice with backoff, then surface the error.

---

## 8. Playlist (native-managed window)

| ID | Rule |
|---|---|
| PL-01 | Dart sends descriptors (URI, headers, encryption config, metadata) once; mutations are sent as individual operations. |
| PL-02 | The queue holds the current item, plus the next one when preload-next is on (gapless). With preload-next off, only the current item. |
| PL-03 | Native advances on end of item and on lock-screen next/previous, with no Dart involvement. |
| PL-04 | Loop modes: off, one, all. Shuffle order lives natively and is exposed to Dart. Single-item seamless looping supported (USE-06). |
| PL-05 | Previous: within the first N seconds (default 3), go to the previous item; otherwise restart the current one. N is configurable, 0 = always go back. |
| PL-06 | Error on an item: skip ahead up to the configured maximum (default 0 = stop and report). |
| PL-07 | Items are created lazily and released as soon as they leave the window; native memory doesn't grow with playlist length. |

---

## 9. Audio session (app-wide)

| ID | Rule |
|---|---|
| SES-01 | One session for the whole app, configured through `AudioSessionManager`. Players never set the session themselves. |
| SES-02 | **Presets**, each expanding into a plain, editable config (P-02): **music** (playback category, default mode, takes audio focus), **speech** (playback, spoken-audio mode, long-form route sharing; other apps' navigation prompts pause instead of duck), **ambient** (mixes with other apps, respects the silent switch, no background). |
| SES-03 | **Custom config** exposes iOS category, mode, category options (mix with others, duck others, Bluetooth/AirPlay options, default to speaker) and route-sharing policy. Android fields (usage, content type, focus type) are part of the config now and take effect in Phase 6. |
| SES-04 | **Interruption policy** (configurable): pause and auto-resume when the system allows; pause only; or ignore. Applies to all players. |
| SES-05 | **Activation:** activated on the first play of any player. **Deactivation** when all players are stopped or completed (configurable), notifying other apps so their audio can resume. |
| SES-06 | **Runtime changes** are allowed (e.g. switching to play-and-record and back). Native reapplies the config and keeps all players consistent. |
| SES-07 | **Hand-off mode:** the app can tell the package not to manage the session at all (for apps using recorders, TTS or other audio plugins). The package then only observes interruptions and route changes so player state stays correct. |
| SES-08 | **Validation:** a background-enabled player with an ambient-type session is invalid (ambient audio stops in the background). Debug: error. Release: warning. |
| SES-09 | Default when nothing is configured: the music preset, applied lazily at first play. |

---

## 10. Background playback and lock screen (opt-in)

| ID | Rule |
|---|---|
| BG-01 | Enabled by giving a player a background config. Players without it are foreground-only (e.g. SFX in USE-05/USE-07). |
| BG-02 | **Single owner:** only one player at a time owns Now Playing and remote commands. Enabling background on a second player either transfers ownership explicitly or raises a configuration error (decide in Phase 4; default: explicit transfer). |
| BG-03 | Remote commands (play/pause, next, previous, seek, skip intervals) are handled natively, so they work while Dart is suspended. Enabled commands follow the background config. |
| BG-04 | Now Playing info (title, artist, artwork, duration, rate, elapsed time) is updated natively from source metadata and player state. |
| BG-05 | Route change: pause when headphones are unplugged (configurable, part of SES-04 policy). |
| BG-06 | The app adds the `audio` background mode to Info.plist (D-16); the README documents it, and debug builds warn if a background config is used without it. |

---

## 11. Events, state and threading

| ID | Rule |
|---|---|
| EVT-01 | Native → Dart through one `@objc` listener protocol per player, implemented in Dart via ffigen (asynchronous delivery): state, index, duration, buffered, sequence, error. The session manager has its own listener for interruptions and routes. |
| EVT-02 | Processing state comes from one native state machine combining item status, time-control status, buffer state and end-of-item notifications. |
| EVT-03 | Position is not pushed. Dart reads it synchronously, polling at a configurable interval (default 200 ms) only while the position stream has listeners. |
| IO-01 | All AVFoundation access on the main thread. Dart calls arrive on the main thread because of merged UI/platform threads; native asserts this in debug builds. |
| IO-02 | Calls from background isolates are unsupported in v1, and documented as such. |
| IO-03 | Lifetimes: dispose releases native objects explicitly; a Dart finalizer is the safety net. Native retains resource-loader delegates per item (AVFoundation holds them weakly). |

---

## 12. Package structure

```
<package>/                        # name PENDING (D-11)
  lib/
    <package>.dart                # public exports
    src/                          # player, sources, encryption, session, background, state
    src/ios/                      # generated bindings (committed) + iOS engine glue
  ios/
    <package>.podspec
    <package>/Package.swift
    <package>/Sources/<package>/  # NAPlayer, NAPlaylist, NAItemFactory, NAResourceLoader,
                                  # byte sources, NAAesCtrCipher, NAObserver,
                                  # NASessionManager, NARemoteControl, listener protocols
    headers/                      # generated ObjC header for ffigen (committed)
    Tests/                        # XCTest: cipher, byte sources, session config mapping
  tool/                           # ffigen config + header generation script
  example/                        # one demo screen per USE profile
  example/integration_test/
  test/                           # Dart unit tests
```

---

## 13. Phases

Rough estimates for one developer.

### Phase 0: Spike (2–3 days)
Prove the risky interop before writing real code.
- [ ] Minimal native player bound with ffigen; synchronous call from Dart works on device.
- [ ] Listener protocol implemented in Dart receives native callbacks.
- [ ] Encrypted **local** file plays and seeks through the resource loader.
- [ ] Builds in the example app with both CocoaPods and SwiftPM.
- [ ] Quick swiftgen comparison; keep D-02 unless swiftgen is clearly simpler.
- [ ] Confirm D-10 and the main-thread assumption (IO-01).

**Exit:** all green. Anything red gets resolved here, before Phase 1.

### Phase 1: Core playback (~1 week)
- [ ] Sources: file, asset, URL, URL with headers (passthrough loader), HLS.
- [ ] Play, pause, stop, seek, volume, speed with pitch-correction choice, clips.
- [ ] State machine, duration, buffered position, errors, position polling, dispose.
- [ ] Minimal session manager: default music preset applied at first play (SES-09).
- [ ] Multiple simultaneous players.

**Done when:** each source type plays and seeks reliably; two players play at once; state transitions are correct; no leaks after 50 load/dispose cycles.

### Phase 2: Encryption (~1 week)
- [ ] Confirm the IV/counter layout (D-12) and lock ENC-02.
- [ ] AES-CTR cipher with offset positioning; local byte source.
- [ ] Remote byte source: probe, range mapping, incremental decrypt, cancellation, errors.
- [ ] IV from header or bytes; wrong-key detection; key zeroing.

**Done when:** files from the existing encryptor play locally and remotely; 100 random seeks per file land correctly; a wrong key fails clearly within one second; a server without Range support fails with a clear message.

### Phase 3: Playlist (~1 week)
- [ ] Native descriptors, lazy window, auto-advance, next/previous, seek to index.
- [ ] Loop (including seamless single-item loop), shuffle, mutations, skip on error.
- [ ] Mixed plain + encrypted + remote playlists.

**Done when:** a 1,000-item playlist uses constant native memory; gapless transitions work between encrypted local items; mutations during playback keep the correct current item.

### Phase 4: Session, background, lock screen (~1 week)
- [ ] Full session manager: presets, custom config, interruption policy, activation/deactivation, runtime changes, hand-off mode, validation (SES-01 … SES-09).
- [ ] Background config, single-owner rule, native remote commands, Now Playing (BG-01 … BG-06).

**Done when** the device checklist passes: 60+ minutes of screen-off playback (local and remote encrypted); phone-call interruption with each policy; headphone unplug; lock-screen controls while backgrounded; USE-07 (background music + foreground SFX) behaves correctly; hand-off mode works next to another audio plugin.

### Phase 5: Hardening and release 0.1.0 (~1 week)
- [ ] Error paths, slow and flaky networks, memory review.
- [ ] Example app with one screen per USE profile (USE-01 … USE-07).
- [ ] README: setup per use case, Info.plist snippet, session presets, threat model, format table, migration notes from just_audio.
- [ ] Publish 0.1.0 (iOS only, clearly labeled).

### Phase 6: Android (later)
- jnigen bindings to Media3.
- Kotlin helpers: AES-CTR data source (same ENC rules), media session service owning the background-enabled player, native playlist window.
- Session config maps to audio attributes and audio focus (SES-03).
- Same Dart API, same test vectors, same USE demos and checklists.

### Later (v2 candidates)
- PCM access and visualizers (USE-08), low-latency SFX engine, disk caching of ciphertext, on-demand key provider, DRM source type, federated structure.

---

## 14. Testing

- **Cipher:** decrypting at random offsets equals the matching slice of a whole-file decrypt; counter-carry edge case; 128- and 256-bit keys.
- **Cross-implementation vectors:** golden files encrypted with the **existing** Dart encryptor must decrypt natively to the same SHA-256. This gates ENC-02.
- **Byte sources:** tested without AVFoundation; the remote source runs against a local range-capable HTTP server (seeks, cancellation, throttling, 200 instead of 206, compression).
- **Session:** config-to-native mapping per preset and custom field; validation rules.
- **Integration (simulator + device):** per source type, per USE profile.
- **Manual device checklist:** the Phase 4 list, run before every release.
- **Leaks:** load/dispose loops, long playlists, many simultaneous players.

---

## 15. Risks

| Risk | Mitigation |
|---|---|
| ffigen / objective_c API churn | Pin versions; commit generated bindings and header; regenerate deliberately. |
| Resource loader quirks (exact UTI, m4a with `moov` at the end, huge "to end" requests) | Declared formats; byte-range access always on; chunked responses that honor cancellation; dedicated test files. |
| Gapless between custom-scheme items | Test early in Phase 3; fallback: two-player handoff inside the native player. |
| Servers without Range support or with compression | Detected during the probe; clear error; documented server requirements. |
| Encrypted file layout doesn't match ENC-02 | Cross-implementation vectors before building the remote source. |
| Multiple players fighting over session or Now Playing | App-wide session (D-14) and single background owner (D-15). |
| SFX latency with AVPlayer is too high for some apps | Documented limit; low-latency engine is a v2 candidate. |
| Merged-thread assumption breaks on some Flutter versions | Debug assertion + documented minimum Flutter version. |
| Key exposure in process memory | Documented threat model; key zeroing; DRM as a future source type. |

---

## 16. Open questions

1. **D-12:** IV layout of existing files: full 128-bit counter or nonce + counter? IV stored in the file header or delivered separately?
2. **D-09:** minimum iOS version (proposal: 15).
3. **D-11:** package name.
4. Keys: only passed up front (current plan), or also an on-demand key provider in v1?
5. Which audio formats do the encrypted files use today? This decides the formats to test first.
6. **BG-02:** when a second player enables background, transfer ownership automatically or require it explicitly?
7. Which USE profile do we build our own product on first? (It decides demo-screen order and which checklist runs first.)
