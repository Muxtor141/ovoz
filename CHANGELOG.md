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
