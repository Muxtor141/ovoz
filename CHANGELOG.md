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
