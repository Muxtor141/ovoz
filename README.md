# ovoz

Audio playback for Flutter with native-owned players: queues with gapless
transitions, encrypted sources decrypted in memory (no proxy, nothing
decrypted on disk), an app-wide audio session, and lock-screen controls.
Dart talks to the native engine directly: FFI to Swift on iOS, JNI to Kotlin
on Android.

**Status:** iOS (15+) and Android (6.0+, on Media3 ExoPlayer), behind one
API. `ovoz` is a working name.

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
  (iOS 16+; on Android ExoPlayer reads about 50 s ahead).
- Events you can act on: an item completed (once, never for skips), an item
  failed (with a kind: not found, network, decryption, …).
- Position, buffered position and duration as synchronous reads, and as
  streams that cost nothing while nobody listens.
- An app-wide session with presets (music, speech, ambient) and policies for
  interruptions and unplugged headphones; on Android it holds audio focus for
  the whole app.
- Lock screen, Control Center, the Android media notification, headsets and
  cars: metadata, artwork, and commands that go through the player (and
  through your own handler, if you want).

## Setup

The full guide, with every platform step and the whole API, is
[doc/integration.md](doc/integration.md). The short version:

```yaml
dependencies:
  ovoz:
    git:
      url: https://github.com/Muxtor141/ovoz.git
```

### iOS

Deployment target 15.0. CocoaPods and Swift Package Manager both work.
To keep playing with the screen off, add the `audio` background mode to
`ios/Runner/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

### Android

`minSdk` 23 or higher (Flutter's default is 24) and `compileSdk` 36 or higher
(Media3 1.11 needs it). To play with the screen off and show the media
notification, declare the playback service and its permissions in
`android/app/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.INTERNET"/>
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
  <application ...>
    ...
    <service
        android:name="uz.sayma.ovoz.OvozPlaybackService"
        android:foregroundServiceType="mediaPlayback"
        android:exported="true">
      <intent-filter>
        <action android:name="androidx.media3.session.MediaSessionService"/>
      </intent-filter>
    </service>
  </application>
</manifest>
```

Media3 starts the service in the foreground when the player that owns the
media controls plays, and lets it go when it stops. The notification uses the
drawable `ovoz_notification_icon` if the app has one (white on transparent,
like any status bar icon). On Android the foreground service is what keeps
an app playing in the background, and it comes with the notification: other
players play on in the background only alongside the one that owns the
controls (iOS's audio background mode covers every player).

Android ends the app's Flutter engine with its activity. When the user swipes
the app away, the players stop with it: without Dart, nothing could cue the
next item or answer a lock-screen command. To keep playing, keep the engine
alive beyond the activity (a cached `FlutterEngine`, as audio_service's
`AudioServiceActivity` does).

Plain HTTP needs a network security configuration that allows it, as for any
Android app. R8 keeps what the bindings need on its own (the plugin ships
its rules).

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

### Stalls and the network

Without a policy, a connection that goes quiet leaves the player waiting for
as long as the platform waits, which can be minutes. A connection that drops
fails the item. With a `StallPolicy`, the player handles both by itself, and
it stays playing throughout, so a pause works as ever:

- After `reconnectAfter` without audio, it loads the item again where it is,
  over new connections.
- A dropped connection is a wait, not a failure: the item is tried again
  shortly.
- Offline, nothing is timed and nothing gives up. When the network comes
  back, or the device moves from Wi-Fi to cellular, a waiting item is loaded
  again at once.
- After `giveUpAfter` of waiting with a network, it gives up: it pauses where
  it was, keeping the item (on the lock screen too), and reports an
  `ItemFailed` of kind `network`. `play()` loads the item again from there.

A load that never finishes counts as a wait too. Any failed item keeps its
position, including one that failed before it reached its start position.

```dart
player.stallPolicy = const StallPolicy(
  reconnectAfter: Duration(seconds: 6),
  giveUpAfter: Duration(seconds: 30),
);
```

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

### The audio session on Android

On Android the session sets the players' audio attributes and holds audio
focus for the whole app, requested at the first play. Each preset maps to it
on its own, and `AudioSessionConfig.effectiveAndroidAudio` shows how: speech
is speech content that pauses (rather than being ducked) when another app
speaks, ambient takes no focus and mixes with other apps, music takes focus
that stops them. Set `androidAudio` to choose yourself:

```dart
await AudioSession.instance.configure(
  const AudioSessionConfig.ambient().copyWith(
    androidAudio: const AndroidAudioConfig(
      usage: AndroidAudioUsage.navigationGuidance,
      focus: AndroidAudioFocus.gainTransientMayDuck,
    ),
  ),
);
```

A call or another app taking focus is an `AudioInterruption`, handled by the
`InterruptionPolicy` as on iOS: a short loss pauses and resumes, a lasting one
pauses for good.

### Encryption

AES in CTR mode, with the IV as one 128-bit big-endian counter (what
PointyCastle, the `encrypt` package, and OpenSSL do). Decryption happens
natively, in memory, inside the player's loading pipeline; nothing decrypted
reaches the disk and no local server is involved. Keys are handed to the
engine when an item is created and zeroed when it is released; the package
never stores them.

This protects files against copying and sharing. It does not protect keys on a
jailbroken or rooted device: that needs DRM. On Android the engine zeroes its
own copy of a key when the item is released; each cipher's copy inside the
platform's crypto provider is freed with the cipher.

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
bindings to Swift on iOS, jnigen bindings to Kotlin on Android, and by a fake
in tests.

What Mutolaa needs and how it maps: [doc/mutolaa-requirements.md](doc/mutolaa-requirements.md).

## Development

| Task | Command |
|---|---|
| Regenerate the bindings after changing an `@objc` API or the Kotlin engine's public API | `tool/generate_bindings.sh [ios\|android]` |
| Dart tests (queue, player, session config, cross-implementation vectors) | `flutter test` |
| Native tests (cipher, byte sources, resource loader) on macOS | `cd ios/native_tests && swift test` |
| Kotlin tests on the JVM (cipher, formats) | `cd example/android && ./gradlew :ovoz:testDebugUnitTest` |
| Kotlin tests on a device or emulator (decrypting source over files and HTTP, ExoPlayer) | `cd example/android && ./gradlew :ovoz:connectedDebugAndroidTest` |
| Android Lint on the plugin (API levels against `minSdk`, permissions) | `cd example/android && ./gradlew :ovoz:lintDebug` |
| The real engine on a simulator or emulator | `cd example && flutter test integration_test -d <device id>` |
| Rebuild test vectors / demo media | `tool/make_test_vectors.sh`, `tool/make_example_media.py` |

The example app has one screen per use case: an encrypted audiobook, a
music queue, streaming, a mixer of several players, and the audio session.

## Limitations

- Formats are what the platform decodes. iOS (AVFoundation): MP3, AAC/M4A,
  WAV, AIFF, CAF, FLAC, HLS; not Ogg Vorbis or Opus outside CAF. Android
  (Media3): MP3, AAC/M4A, WAV, FLAC, Ogg Vorbis and Opus, HLS; not AIFF or
  CAF.
- Encrypted sources must declare their format.
- Android recognises HLS by its `.m3u8` extension.
- Android's notification shows no queue position ("3 of 12").
- On Android, `InterruptionPolicy.none` pauses nothing: Android does not
  silence an app that lost audio focus, so the app decides.
- Engine calls must come from the main isolate.
