# What Mutolaa needs from ovoz

Every player capability the Mutolaa app relies on today, where it uses it,
and what replaces it in ovoz. Measured on 2026-10-05 from
`packages/mutolaa_audio_engine` and the app's call sites of `AudioPlayback`
and `ClipPlayer`.

Legend: ✅ done and tested · ◐ partly · ➖ app's job, not the player's ·
🗑 not needed any more · ⏳ planned

## 1. Book player (`AudioPlayback`, one per app)

| Capability | Where Mutolaa uses it | ovoz | |
|---|---|---|---|
| Play / pause; `play()` returns at once | control buttons, mini player, lock screen | `play()`, `pause()` — `play()` never waits for playback to end (just_audio's did, so the engine wrapped it) | ✅ |
| Stop, keep source and position, resume | mini-player close, `releaseIfPaused` | `stop()` releases decoders and keeps queue + position; `play()` reloads there | ✅ |
| Seek; replay after the end | slider, `seek(zero)` when completed | `seek()` is exact (zero tolerance); `play()` after the end replays | ✅ |
| ±10 s | `seekBy` | `seekBy(offset)`, clamped to the item. Mutolaa's "do nothing past the end" stays in its own wrapper | ✅ |
| Jump to chapter | playlist sheet → `skipTo(i)` | `skipToIndex(i)`, `seek(pos, index: i)` | ✅ |
| Next / previous, `hasNext` / `hasPrevious` | mini player, lock screen | `skipToNext()`, `skipToPrevious()`; `PlayerOptions(previousRestartThreshold: Duration.zero)` gives Mutolaa's "always the previous chapter" | ✅ |
| Speed 0.25–2.0, pitch kept | speed sheet | `setSpeed`; `PitchCorrection.speech` = time-domain, what the fork used | ✅ |
| Speed remembered across launches | `PlaybackSettingsStore` | `speedStream` to persist, `setSpeed` to restore | ➖ |
| Position, buffered position, duration for sliders | player slider, mini player | `progressStream` (read only while listened to, default every 200 ms) | ✅ |
| Once-a-second ticks for reading sessions | bloc: every 2/3/20/100 ticks | `positionStream` with a 1 s interval, or a timer reading `position`; tick counting stays in the app | ➖ |
| "A chapter ended", exactly once | `TrackCompleted` → finished marking, sleep | `events` → `ItemCompleted` (once per natural end, never for skips) | ✅ |
| Auto-advance to the next chapter | engine `_onCompleted` → `skipToNext` | native, gapless, from the queue; works with the screen locked | ✅ |
| "Stop after this chapter" | `stopAfterCurrentTrack` | `pauseAtItemEnd` | ✅ |
| Which book/file is playing, read from the player | `PlaybackSource` from the source tag | `AudioSource.tag` + `currentSource`, updated from the engine's own item events | ✅ |
| idle / loading / buffering / ready / completed | `PlaybackPhase` | `ProcessingState`: same five values; `playing` is separate, as before | ✅ |
| Stop on error instead of skipping (the fork's iOS/Android fix) | backend error handler | default `maxSkipsOnError: 0`: `ItemFailed`, then idle; `play()` retries where it failed | ✅ |
| Error kinds the app can phrase | `PlaybackFailure` | `AudioErrorKind`: `sourceNotFound`, `network`, `decryption`, `unsupportedFormat`, `rangeNotSupported`, … | ✅ |
| Stall detection and recovery | stall probe, `PlaybackStalled` | `buffering` state + `position`; a failed item retries on `play()`. The probe's policy can stay in Mutolaa's engine | ➖ |
| HLS with `Authorization: Bearer` | `HlsStream(headers)` via the fork's localhost proxy | `AudioSource.url(url, headers: …)` through `AVURLAssetHTTPHeaderFieldsKey`: no proxy, covers playlists, keys and segments | ✅ (headers tested on a plain file; HLS tested without headers) |
| Plain streams (advertisement, fragment) | `PlainStream` | `AudioSource.url` | ✅ |
| Encrypted downloads (AES-128-CTR) | `CustomLockCachingSource` / `OfflineAudioSource2`: localhost proxy + Dart isolate + a plaintext copy on disk | `AudioSource.file(path, encryption: AesCtrEncryption(key, iv), format: AudioFormat.mp3)`: decrypted natively, in memory | ✅ |
| Same, streamed (encrypted file over HTTP) | not used today | `AudioSource.url(..., encryption: …)`: byte ranges, decrypted as they arrive | ✅ |
| Switch stream ↔ download mid-chapter, same second | `_switchCurrentSource` | `replaceAt(index, source)` keeps position and play state | ✅ |
| Sound-effect mix toggle at the same position | `stop` → `openBook(startPosition)` | `replaceAt`, or `setQueue(..., initialPosition:)` | ✅ |
| Advertisement, then the book at the same second | `playInterstitial` | the app composes it: a second `AudioPlayer` for the ad while the book waits, or `setSource(ad)` then `setQueue(book, initialPosition:)` | ➖ |
| Hold (quote flow): pause, leave the lock screen, ignore every command | `hold()` | `pause()` + `setMediaControls(null)`; `setMediaControls(...)` to come back. Without controls no headset or car command reaches the player | ✅ |
| Interruption ends → resume | `_watchAudioFocus` | `InterruptionPolicy.pauseAndResume`. **Differs:** honours the system's `shouldResume`; Mutolaa resumes regardless | ✅ / decide |
| Headphones unplugged → pause | `becomingNoisy` | `pauseOnBecomingNoisy: true` (default) | ✅ |
| Spoken-audio session | `AudioSession.configure(speech())` | `AudioSessionConfig.speech()`: the same playback + spokenAudio | ✅ |
| Lock screen: title, cover URL, duration; previous, play/pause, stop, next; scrubbing | `MediaSessionBridge` (audio_service) | `MediaMetadata` per source + `MediaControls(commands: …)`; commands come back through the player, so app rules apply to them | ✅ data and commands checked in MediaRemote on the simulator; buttons need a device check |
| Queue shown to the system | `showQueue` | "3 of 12" (index and count); no browsable queue | ◐ |
| Android notification channel, foreground service | `AudioServiceConfig` | Android engine | ⏳ |

## 2. Quote editor clips (`ClipPlayer`, two at once)

| Capability | Where | ovoz | |
|---|---|---|---|
| Load a file or URL, get its duration | narration, bed | `setSource` returns the duration | ✅ |
| Loop | narration, bed | `setLoopMode(LoopMode.one)`, seamless | ✅ |
| Volume per player (envelope recomputed per position report) | bed | `setVolume` | ✅ |
| Millisecond seeks | scrubbing | exact seeks | ✅ |
| Position every ≤ 100 ms | playhead, bed envelope, cover video | `PlayerOptions(positionInterval: Duration(milliseconds: 50))` | ✅ |
| `playing` stream | play glyph | `playingStream` | ✅ |
| A newer load aborts the one in flight, which throws | bed | `LoadInterruptedException` | ✅ |
| Loop a range of a track (audition) | Dart seeks back at `end − 50 ms` ("no platform player loops a range") | `ClipRange(start, end)` + `LoopMode.one`: looped natively | ✅ new |
| Formats: mp3, m4a, aac, wav, aiff, caf, flac | device audio picker | all of these through AVFoundation | ✅ |
| Formats: ogg, opus | device audio picker | not decodable by AVFoundation (Opus only inside CAF) | ◐ |

## 3. Things ovoz makes unnecessary

| Today | Why it existed | With ovoz |
|---|---|---|
| The fork's `proxy.isProxyServerHealthy/start/stop`, the resume-time proxy restart | iOS kills the localhost proxy socket in the background | 🗑 No proxy: headers go through AVFoundation, decryption through a resource loader |
| `discardCache` / `clearCacheFor` | the proxy cached **decrypted** audio on disk; a deleted download stayed playable | 🗑 Nothing decrypted is ever written to disk |
| Dart decryption isolate, throttled chunking (heat) | decryption in Dart, on the CPU | 🗑 Native AES (hardware-accelerated CommonCrypto) |
| `usesCleartextTraffic` / ATS for the loopback proxy | the proxy was plain HTTP | 🗑 |
| `AudioServiceCustom`, `audio_service` handler on iOS | lock-screen integration | 🗑 on iOS (`MediaControls`); stays on Android until ⏳ |

## 4. How Mutolaa can adopt it

The engine already hides its player behind `PlayerBackend`
(`lib/src/engine/player_backend.dart`), so ovoz goes in as one new class,
`OvozBackend implements PlayerBackend`, chosen on iOS in `AudioEngine`. Android
keeps `JustAudioBackend` + `MediaSessionBridge` until ovoz has its Android
engine. Nothing in the app changes.

| `PlayerBackend` | `OvozBackend` |
|---|---|
| `playing` / `playingStream` | `player.playing` / `playingStream` |
| `phase` / `phaseStream` | `processingState` / `processingStateStream` (same values) |
| `speed`, `position`, `bufferedPosition`, `duration` (+ streams) | the same names on `AudioPlayer` |
| `track` / `trackStream` | `currentSource?.tag as Track?` / `currentIndexStream.map(...)` |
| `hasSource` | `currentSource != null` |
| `events` | `playerStateStream` (+ `progressStream` if needed) |
| `interruptions` / `becomingNoisy` | `AudioSession.instance.interruptions.map((e) => e.began)` / `becomingNoisy` |
| `activateSession()` | `AudioSession.instance.configure(const AudioSessionConfig.speech())`, once |
| `load(track, initialPosition)` | `setSource(sourceFor(track), initialPosition: …)` |
| `reload()` | `setSource(current, initialPosition: position)` |
| `play`, `pause`, `stop`, `seek`, `setSpeed` | the same |
| `isConnectionHealthy` / `startConnection` / `stopConnection` | delete (no proxy) |
| `discardCache` | delete (no plaintext cache) |

`Track.media` maps to sources:

```dart
AudioSource sourceFor(Track track) => switch (track.media) {
  HlsStream(:final url, :final headers) =>
    AudioSource.url(url, headers: headers ?? const {}, tag: track, metadata: metadataOf(track)),
  PlainStream(:final url) => AudioSource.url(url, tag: track, metadata: metadataOf(track)),
  EncryptedDownload(:final path) => AudioSource.file(
    path,
    encryption: mutolaaEncryption, // AesCtrEncryption(key: …, iv: …) from the app
    format: AudioFormat.mp3,
    tag: track,
    metadata: metadataOf(track),
  ),
};
```

`MediaSessionBridge` becomes `setMediaControls(MediaControls(commands: …))` on
the book player plus `MediaMetadata(title, artUri)` on each source; `hold()`
becomes `setMediaControls(null)` while held. The engine keeps its own
playlist, ad swap and download swaps at first; moving chapter navigation onto
ovoz's queue (`setQueue` + `skipToIndex`, gapless auto-advance, native
"stop after chapter") is a later, separate step.

## 5. Decisions for the team

1. **Name.** `ovoz` is a working name (Uzbek: sound, voice). `native_audio` is
   taken on pub.dev.
2. **Resume after an interruption** regardless of the system's
   `shouldResume` (Mutolaa today) or only when the system allows it (Apple's
   guidance, ovoz default)?
3. **Lock screen:** next/previous chapter, or ±10 s? iOS shows skip buttons
   instead of next/previous when both are enabled.
4. **Keys:** ovoz takes keys per source and never stores them; fetching and
   keeping them stays the app's job.
5. **Android:** Media3 through jnigen (the plan) or through Pigeon — see
   `architecture.md`, "Next".
