## 0.1.0-dev.5

- `doc/integration.md`: the full integration guide, from iOS and Android
  setup through every part of the API, migration from just_audio and
  audio_service, and troubleshooting.
- Android, behind the same API: a Kotlin engine on Media3 1.11 ExoPlayer,
  called from Dart through jnigen bindings (synchronous calls on the platform
  thread, events posted to the isolate, as on iOS).
  - The same two-item window: ExoPlayer's playlist holds the current item and
    the cued one, for gapless advance with the screen off; pause at item end,
    clips, loop one, speed with pitch kept.
  - AES-CTR decrypted in memory by a Media3 `DataSource` with the iOS engine's
    counter arithmetic, over files, assets and HTTP byte ranges (206 required,
    no compression), with the same wrong-key check and error kinds.
  - Headers on every request, HLS playlists and segments included; two
    retries for a failed load, none for what retrying cannot fix.
  - A failure of the cued item that retrying will not fix is reported before
    it is reached, so it is never advanced into.
  - The session holds audio focus for the whole app; interruptions, unplugged
    headphones and output devices are reported as on iOS. A play during a
    call is refused; before Android 8, ovoz ducks players itself; a queue
    that has ended is not replayed when an interruption ends.
  - The media notification and media session: `OvozPlaybackService`, which
    the app declares, runs as a media-playback foreground service while the
    player that owns the controls plays. Commands go through Dart, as on iOS.
  - The network monitor reports a network going away, coming back or moving
    to another interface.
- `AudioSessionConfig.androidAudio` (`AndroidAudioConfig`: usage, content
  type, focus, pause when ducked) and `effectiveAndroidAudio`, which derives it
  from the presets when not set.
- Debug builds warn on Android when media controls are enabled but the
  manifest lacks the playback service.
- Fixed (iOS): route changes from `wakeFromSleep` on reached Dart as other
  reasons (`AVAudioSession.RouteChangeReason` skips 5, and its raw value was
  passed as the index).
- Fixed (iOS): a queue that had ended was played again from the start of its
  last item when an interruption ended.

## 0.1.0-dev.4

- `StallPolicy` handles the network. A dropped connection is a wait, not a
  failure: the player stays playing, tries the item again shortly, and loads
  it at once when the network comes back. Offline, waits are not timed and
  never given up on. A network switch (Wi-Fi to cellular) reloads a waiting
  item at once.
- The engine reports the network (`NWPathMonitor`): new
  `PlayerEngine.networkAvailable` and `EngineNetworkChanged`, and
  `FakePlayerEngine.changeNetwork` to drive them in tests.
- Fixed: on iOS an item's failure arrived after the idle, not-playing state
  it causes, so a player could not tell that playback had been wanted.
- Giving up on a stall pauses the player where it was, the item still current
  and on the lock screen, instead of emptying the engine (which cleared the
  lock screen as if playback had been discarded).
- Fixed: an item that failed before reaching its start position reported
  position 0, so `play()` started it over from the beginning.

## 0.1.0-dev.3

- `StallPolicy` (`AudioPlayer.stallPolicy`, `PlayerOptions.stallPolicy`): a
  player that waits for audio it should be playing reloads the item once
  over new connections, then gives up with an `ItemFailed` of kind
  `network`. Off by default.
- `FakePlayerEngine.startBuffering` and `finishBuffering`, to drive a stall
  in tests.

## 0.1.0-dev.2

- Fixed: local encrypted files are read as they play instead of 30–50 MB
  being prefetched into memory per item (iOS 16+). Measured with 300 MB,
  6-hour chapters: no growth over an idle app, across chapter changes and
  seeks.
- Fixed: a player referenced only by its own pending load (for example one
  created and awaited inside an async function) could be garbage-collected,
  and the load never completed. A player now lives until `dispose()`.

## 0.1.0-dev.1

First working version, iOS only.

- `AudioPlayer`: queues with gapless advance, next/previous/jump, shuffle,
  loop one/all, queue edits, replace in place, pause at item end, clips,
  speed with pitch correction, volume, stop/resume, media controls.
- Sources: files, assets, HTTP(S)/HLS with headers, AES-CTR encrypted files
  (local and streamed by byte range), decrypted in memory.
- `AudioSession`: presets, custom configuration, interruption and
  unplugged-headphone policies, system events.
- Lock screen and Control Center: metadata, artwork, remote commands routed
  through the player.
- `package:ovoz/testing.dart`: the engine contract and fakes.
