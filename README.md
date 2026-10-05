# ovoz

Audio playback for Flutter with native-owned players: queues with gapless
transitions, encrypted sources decrypted in memory (no proxy, nothing
decrypted on disk), an app-wide audio session, and lock-screen controls.
Dart talks to the native engine through FFI.

**Status:** iOS (15+). Android is planned behind the same API. `ovoz` is a
working name.

- One or many players at once, each with its own queue, speed, volume and
  loop mode.
- Queue: next, previous, jump to any item, shuffle, loop one/all, insert,
  remove, move, replace in place (same position), gapless advance that keeps
  working with the screen off.
- Sources: files, Flutter assets, HTTP(S) and HLS with headers on every
  request, clips (start/end).
- Encryption: AES-CTR (128/192/256), IV given or read from the file's header,
  local or streamed by byte range; a wrong key is reported as such.
- Long files cost little memory: nothing is loaded whole, finished items are
  released, and local files, encrypted or not, are read as they play: a
  300 MB encrypted chapter costs about as much memory as a plain file
  (iOS 16+).
- Events you can act on: an item completed (once, never for skips), an item
  failed (with a kind: not found, network, decryption, …).
- Position, buffered position and duration as synchronous reads, and as
  streams that cost nothing while nobody listens.
- An app-wide session with presets (music, speech, ambient) and policies for
  interruptions and unplugged headphones.
- Lock screen, Control Center, headsets: metadata, artwork, and commands that
  go through the player (and through your own handler, if you want).

## Setup

```yaml
dependencies:
  ovoz:
    git:
      url: https://github.com/Muxtor141/ovoz.git
```

iOS: deployment target 15.0. CocoaPods and Swift Package Manager both work.
To keep playing with the screen off, add the `audio` background mode to
`ios/Runner/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

## Use

```dart
import 'package:ovoz/ovoz.dart';

final player = AudioPlayer();

// Once per app, before playing (the music preset applies otherwise).
await AudioSession.instance.configure(const AudioSessionConfig.speech());

await player.setQueue([
  AudioSource.url(Uri.parse('https://example.com/book/1.m3u8'),
      headers: {'Authorization': 'Bearer $token'},
      metadata: const MediaMetadata(title: 'Chapter 1'),
      tag: chapterOne),
  AudioSource.file(downloadedPath,
      encryption: AesCtrEncryption(key: key, iv: iv),
      format: AudioFormat.mp3,
      metadata: const MediaMetadata(title: 'Chapter 2'),
      tag: chapterTwo),
], initialIndex: 0, initialPosition: const Duration(minutes: 3));

await player.play();               // returns at once
await player.skipToIndex(1);       // jump to an item
await player.seekBy(const Duration(seconds: -10));
player.pauseAtItemEnd = true;      // "stop after this chapter"
await player.setMediaControls(const MediaControls());   // lock screen

player.progressStream.listen((p) => /* slider */ null);
player.currentIndexStream.listen((i) => /* highlight item i */ null);
player.events.listen((event) {
  if (event is ItemCompleted) markFinished(event.source.tag);
  if (event is ItemFailed) showError(event.error.kind);
});
```

A player lives until you call `dispose()`, even if you drop every reference
to it, so a sound started from a short-lived function plays to its end.
Dispose the players you create.

Streams give each new listener the current value first, so a `StreamBuilder`
needs no special setup. `play()`, `pause()`, `seek()` and the skips never
throw for playback failures: those arrive as `ItemFailed` and leave the player
idle, and `play()` retries the failed item where it stopped. Only `setSource`
and `setQueue` wait for the item to load, and throw if it cannot.

### Several players

```dart
final bed = AudioPlayer();
await bed.setSource(AudioSource.asset('assets/rain.m4a'));
await bed.setLoopMode(LoopMode.one);      // seamless
await bed.setVolume(0.4);

final phrase = AudioPlayer(options: const PlayerOptions(positionInterval: Duration(milliseconds: 50)));
await phrase.setSource(AudioSource.file(path,
    clip: const ClipRange(start: Duration(seconds: 12), end: Duration(seconds: 15))));
await phrase.setLoopMode(LoopMode.one);   // loops the range natively
```

### Encryption

AES in CTR mode, with the IV as one 128-bit big-endian counter (what
PointyCastle, the `encrypt` package, and OpenSSL do). Decryption happens
natively, in memory, inside the player's loading pipeline; nothing decrypted
reaches the disk and no local server is involved. Keys are handed to the
engine when an item is created and zeroed when it is released; the package
never stores them.

This protects files against copying and sharing. It does not protect keys on a
jailbroken device: that needs DRM.

### Testing your code

```dart
import 'package:ovoz/testing.dart';

final engine = FakePlayerEngine();
final player = AudioPlayer.withEngine(engine);
await player.setQueue(sources);
engine.finishItem();            // the current item plays to its end
await pumpEventQueue();
expect(player.currentIndex, 1);
```

## How it is built

See [doc/architecture.md](doc/architecture.md). In short: `AudioPlayer` (Dart)
owns the queue and every rule about what plays next; a native engine per
player plays the current item and keeps the next one cued; the two talk
through a small engine contract (`PlayerEngine`), implemented with ffigen
bindings to Swift on iOS and by a fake in tests.

What Mutolaa needs and how it maps: [doc/mutolaa-requirements.md](doc/mutolaa-requirements.md).

## Development

| Task | Command |
|---|---|
| Regenerate the FFI bindings after changing an `@objc` API | `tool/generate_bindings.sh` |
| Dart tests (queue, player, cross-implementation vectors) | `flutter test` |
| Native tests (cipher, byte sources, resource loader) on macOS | `cd ios/native_tests && swift test` |
| The real engine on a simulator | `cd example && flutter test integration_test -d <simulator id>` |
| Rebuild test vectors / demo media | `tool/make_test_vectors.sh`, `tool/make_example_media.py` |

The example app has one screen per use case: an encrypted audiobook, a
music queue, streaming, a mixer of several players, and the audio session.

## Limitations

- iOS only so far.
- Formats are what AVFoundation decodes: MP3, AAC/M4A, WAV, AIFF, CAF, FLAC,
  HLS. Not Ogg Vorbis or Opus outside CAF.
- Encrypted sources must declare their format.
- Engine calls must come from the main isolate.
