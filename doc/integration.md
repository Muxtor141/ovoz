# Integrating ovoz

How to add ovoz to a Flutter app, set up iOS and Android, and use every part
of the API. The [README](../README.md) is the short version; this is the whole
of it. How the package is built inside is in [architecture.md](architecture.md).

- [1. Requirements](#1-requirements)
- [2. Adding the package](#2-adding-the-package)
- [3. iOS setup](#3-ios-setup)
- [4. Android setup](#4-android-setup)
- [5. First playback](#5-first-playback)
- [6. Sources](#6-sources)
- [7. Encrypted audio](#7-encrypted-audio)
- [8. The queue](#8-the-queue)
- [9. Controlling playback](#9-controlling-playback)
- [10. State, progress and events](#10-state-progress-and-events)
- [11. Errors](#11-errors)
- [12. Stalls and the network](#12-stalls-and-the-network)
- [13. Lock screen, notification and media buttons](#13-lock-screen-notification-and-media-buttons)
- [14. The audio session](#14-the-audio-session)
- [15. Several players](#15-several-players)
- [16. Player options](#16-player-options)
- [17. Testing your code](#17-testing-your-code)
- [18. Coming from just_audio and audio_service](#18-coming-from-just_audio-and-audio_service)
- [19. Platform differences](#19-platform-differences)
- [20. Troubleshooting](#20-troubleshooting)
- [21. Checklist before release](#21-checklist-before-release)

## 1. Requirements

| | Minimum |
|---|---|
| Flutter | 3.38 (Dart 3.10) |
| iOS | 15.0. Local encrypted files are read on demand from iOS 16; on iOS 15 they are read whole. |
| Android | 6.0 (API 23) `minSdk`, `compileSdk` 36 |
| Android build | AGP 8.13 or 9, Kotlin 2.2 or later, JDK 17 |

Engine calls must come from the **main isolate**. Flutter runs Dart on the
platform thread by default (merged platform and UI threads), and that is
where the native players live. Do not turn that off, and do not create
players in a background isolate.

## 2. Adding the package

```yaml
dependencies:
  ovoz:
    git:
      url: https://github.com/Muxtor141/ovoz.git
      ref: main          # a branch, a tag, or a commit hash
```

Pin a commit hash (or a tag) for release builds, so that `flutter pub get`
cannot bring in changes you did not test; `pubspec.lock` records the commit
either way.

```dart
import 'package:ovoz/ovoz.dart';
```

`package:ovoz/testing.dart` holds the fakes for tests (section 17).

ovoz replaces a player plugin together with its background and audio-session
plugins. Do not run it alongside another plugin that also owns the audio
session or the media notification (audio_service, just_audio_background):
two owners of the lock screen fight over it. If another plugin must keep the
session, see `AudioSessionConfig.managedByApp()` (section 14).

## 3. iOS setup

### Deployment target

`ios/Podfile`:

```ruby
platform :ios, '15.0'
```

and the Runner target's *Minimum Deployments* in Xcode, 15.0 or later.
Both CocoaPods and Swift Package Manager work; nothing else to add.

### Background playback

To keep playing with the screen locked or the app in the background, declare
the `audio` background mode in `ios/Runner/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

(or *Signing & Capabilities* > *Background Modes* > *Audio, AirPlay, and
Picture in Picture* in Xcode). The session category must also be one that
plays in the background: `playback` (every preset except `ambient`) or
`playAndRecord`.

In debug builds, a player that enables media controls prints a warning if
either is missing.

### Plain HTTP

Streams over `http://` need an App Transport Security exception, as for any
iOS app:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSExceptionDomains</key>
  <dict>
    <key>media.example.com</key>
    <dict>
      <key>NSExceptionAllowsInsecureHTTPLoads</key>
      <true/>
    </dict>
  </dict>
</dict>
```

### What iOS gives you without more setup

The lock screen, Control Center, the Dynamic Island and AirPods show and
control the player that owns the media controls (section 13). Interruptions (calls, Siri, alarms) and unplugged headphones are
handled by the session's policies (section 14).

## 4. Android setup

### Gradle

`android/app/build.gradle` (or `.kts`):

```groovy
android {
    compileSdk 36            // Media3 1.11 needs it
    defaultConfig {
        minSdk 23            // Flutter's default (24) is fine
    }
}
```

The plugin brings Media3 (ExoPlayer, HLS and session libraries) itself.
It builds with both AGP 8 (Kotlin applied by the plugin) and AGP 9 (built-in
Kotlin).

### Manifest

`android/app/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.INTERNET"/>
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>

  <application ...>
    <activity android:name=".MainActivity" ...>
      ...
    </activity>

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

What each part is for:

- **`OvozPlaybackService`** is a Media3 `MediaSessionService`. It shows the
  media notification and keeps the process in the foreground while the
  player that owns the media controls plays. Without it there is no
  notification, no lock-screen player, and Android stops the app soon after
  it leaves the screen.
- **`FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK`**: needed to run
  that service in the foreground (the second from Android 14).
- **`ACCESS_NETWORK_STATE`** comes from the plugin's own manifest; you do not
  add it.
- **`POST_NOTIFICATIONS`** is not needed for the media notification: Android 13
  exempts media-session notifications from it.

In debug builds, a player that enables media controls prints a warning if the
service or its permissions are missing.

### Notification icon

The notification uses Media3's default icon unless the app has a drawable
named **`ovoz_notification_icon`**: a white, transparent-background status-bar
icon, for example `android/app/src/main/res/drawable/ovoz_notification_icon.xml`
(a vector) or PNGs in `drawable-*dpi/`.

### Keep the Flutter engine alive (playing after the app is swiped away)

On Android, the Flutter engine ends with its activity by default. When the
user swipes the app away from Recents, the engine ends, and ovoz stops its
players: without Dart nothing could cue the next item or answer a lock-screen
command. Screen off and the app in the background are fine either way; only
the swipe-away needs this.

To keep playing after a swipe-away, give the activity a cached engine that
outlives it:

```kotlin
package com.example.app

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        FlutterEngineCache.getInstance().get(ENGINE_ID)
            ?: FlutterEngine(context.applicationContext).also { engine ->
                engine.navigationChannel.setInitialRoute(initialRoute ?: "/")
                engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
                FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            }

    private companion object {
        const val ENGINE_ID = "main"
    }
}
```

A provided engine is not destroyed with the activity, and plugins are
registered by the engine's constructor. When the user opens the app again,
the new activity attaches to the same engine, and the UI is where it was.
If the app opens deep links with Flutter's deep linking, compute the initial
route from `intent.data` before `setInitialRoute`, because the engine starts
before the activity would hand the link to it.

This is what audio_service's `AudioServiceActivity` does; an app moving from
audio_service keeps the same behaviour with this.

### Plain HTTP

Android blocks cleartext HTTP by default. Allow it per domain with a network
security configuration (`res/xml/network_security_config.xml`):

```xml
<network-security-config>
  <domain-config cleartextTrafficPermitted="true">
    <domain includeSubdomains="false">media.example.com</domain>
  </domain-config>
</network-security-config>
```

and `android:networkSecurityConfig="@xml/network_security_config"` on
`<application>`. A blocked request fails the item with
`AudioErrorKind.invalidConfiguration`.

### R8 and ProGuard

Nothing to add: the plugin ships consumer rules that keep the classes its
bindings call.

### Jetifier

Apps with `android.enableJetifier=true` see a build warning that
`media3-session` "contains references to both AndroidX and old support
library". Media3 keeps a few `android.support.v4.media` class names on
purpose, for compatibility with old media controllers, and Jetifier maps
them to themselves. The warning is harmless; turning Jetifier off removes it
if no dependency needs it.

### Phone makers' battery savers

Some Android skins (MIUI/HyperOS, EMUI, ColorOS, One UI's "sleeping apps")
restrict background apps. A playing media session with a foreground service
is normally left alone: ovoz has played for 10 minutes with the screen off on
MIUI 13 without being stopped. If a phone still stops playback, the user can
exempt the app from battery optimisation; see dontkillmyapp.com for each
maker's settings.

## 5. First playback

```dart
final player = AudioPlayer();

Future<void> start() async {
  // Once per app, before the first play. The music preset applies otherwise.
  await AudioSession.instance.configure(const AudioSessionConfig.speech());

  await player.setSource(
    AudioSource.url(
      Uri.parse('https://example.com/episode.mp3'),
      metadata: const MediaMetadata(title: 'Episode 1', artist: 'The Show'),
    ),
  );
  await player.setMediaControls(const MediaControls()); // lock screen
  await player.play(); // returns at once
}

@override
void dispose() {
  player.dispose();
  super.dispose();
}
```

Rules worth knowing from the start:

- **A player lives until `dispose()`**, even if nothing references it any more,
  so a sound started from a short-lived function plays to its end. Dispose
  every player you create.
- **Only `setSource` and `setQueue` wait for the item to load**, and throw if it
  cannot. `play()`, `pause()`, `seek()` and the skips never throw for playback
  failures: those arrive as `ItemFailed` events (section 11).
- **`play()` returns at once.** It does not wait for loading or for the end of
  playback.
- **Streams replay their current value** to each new listener, so
  `StreamBuilder` needs no `initialData`.

## 6. Sources

An `AudioSource` describes something to play. It is cheap: nothing is opened
until a player loads it.

```dart
// A local file (an absolute path).
AudioSource.file('/data/.../chapter1.mp3');

// An asset, by its key in pubspec.yaml; another package's with `package:`.
AudioSource.asset('assets/sounds/click.wav');
AudioSource.asset('sounds/click.wav', package: 'my_sounds');

// HTTP(S) files and HLS. Headers go with every request, HLS segments and keys
// included. No local proxy is involved.
AudioSource.url(
  Uri.parse('https://cdn.example.com/book/master.m3u8'),
  headers: {'Authorization': 'Bearer $token'},
);
```

Every constructor also takes:

| Parameter | What it does |
|---|---|
| `metadata` | `MediaMetadata(title:, artist:, album:, artUri:, duration:)`: what the lock screen and notification show. `artUri` is `https:`, `file:` or `asset:`; `duration` is shown until the real one is measured. |
| `tag` | Any object of yours (an id, a model). Read it back from `player.currentSource?.tag` or from events, to know what is playing. |
| `clip` | `ClipRange(start:, end:)`: play only part of the source. Position, duration and the end are relative to `start`. |
| `format` | `AudioFormat.mp3`, `aac`, `m4a`, `wav`, `aiff`, `flac`, `caf`. Detected for plain sources; required for encrypted ones. |
| `encryption` | Section 7. |

`source.copyWith(metadata:, clip:, tag:)` makes a variant.

Formats are what the platform decodes; see section 19. Android recognises HLS
by the `.m3u8` extension in the URL.

## 7. Encrypted audio

AES in CTR mode, 128, 192 or 256-bit keys. The IV is the first counter block,
counted as one 128-bit big-endian integer: what PointyCastle (the `encrypt`
package) and OpenSSL's `aes-*-ctr` produce. Decryption happens natively,
in memory, inside the player's loading pipeline: nothing decrypted reaches
the disk, and there is no local HTTP server.

```dart
// IV known to the app.
final encryption = AesCtrEncryption(key: key, iv: iv);

// IV stored as the file's first 16 bytes, ciphertext after it.
final withHeader = AesCtrEncryption.ivInHeader(key: key);

// The app's own header before the ciphertext.
final withOffset = AesCtrEncryption(key: key, iv: iv, dataOffset: 64);

// Local, downloaded file:
AudioSource.file(path, encryption: encryption, format: AudioFormat.mp3);

// Streamed: the server must answer byte-range requests (206 Partial Content)
// and must not compress the response.
AudioSource.url(url, headers: headers, encryption: encryption, format: AudioFormat.mp3);
```

- **`format` is required.** The platform cannot detect the format of bytes it
  receives already decrypted; an encrypted source without one throws an
  `ArgumentError` when created.
- **Seeking is exact**: CTR decrypts from any byte, so seeks do not read from
  the start.
- **Memory stays low**: files are read as they play, so a 300 MB chapter costs
  about what a plain file does.
- **A wrong key** is reported as `AudioErrorKind.decryption`, not as a vague
  format error. A server that ignores ranges or compresses them is reported as
  `AudioErrorKind.rangeNotSupported`.
- **Keys** are handed to the native engine when an item is created and zeroed
  when it is released; the package never stores them. `AesCtrEncryption`
  never prints its key.

This protects files against copying and sharing. It does not protect the key
on a jailbroken or rooted device: that needs DRM.

## 8. The queue

Each player owns a queue. The native engine plays the current item and keeps
the next one cued, so moving on is gapless and does not need Dart to be
awake at that moment, which is what keeps it working with the screen off.

```dart
await player.setQueue(
  chapters, // List<AudioSource>
  initialIndex: 3,
  initialPosition: const Duration(minutes: 12, seconds: 5),
);
```

| Call | Effect |
|---|---|
| `add(source)`, `addAll(sources)` | Append. |
| `insert(index, source)` | Insert before `index`. |
| `removeAt(index)` | Remove. Removing the current item moves to the one taking its place, keeping play/pause; the player goes idle if there is none. |
| `move(from, to)` | Reorder (drag and drop). |
| `replaceAt(index, source, keepPosition: true)` | Swap an item in place. If it is current, playback switches to the new source at the same position, still playing: for example a stream for its finished download. |
| `clearQueue()` | Empty the queue and the player. |
| `setLoopMode(LoopMode.off / one / all)` | Off stops after the last item; `one` repeats the current item seamlessly; `all` wraps to the first. |
| `setShuffle(true / false)` | Shuffles the playing order, keeping the current item current; off restores the queue's order. |
| `pauseAtItemEnd = true` | Pause at the end of each item instead of moving on; the next item becomes current, paused at its start. A sleep timer's "stop after this chapter". |

Read it back with `queue`, `currentIndex`, `currentSource`, `hasNext`,
`hasPrevious`, `loopMode`, `shuffle`, or as one value, `queueState`
(`sources`, `currentIndex`, `order`, `loopMode`, `shuffle`), with
`queueStream` and `currentIndexStream`.

An item added after the queue has completed plays at once, as if the queue
had gone on.

## 9. Controlling playback

```dart
await player.play();
await player.pause();
await player.stop();                 // releases decoders; keeps queue, item and position
await player.seek(const Duration(minutes: 5));
await player.seek(Duration.zero, index: 2);
await player.seekBy(const Duration(seconds: -15));   // stays within the item
await player.skipToNext();           // nothing at the end (wraps with LoopMode.all)
await player.skipToPrevious();       // restarts the item after 3 s, else previous
await player.skipToIndex(4);
await player.setSpeed(1.5);
await player.setPitchCorrection(PitchCorrection.speech);  // speech, music, none
await player.setVolume(0.5);         // 0 to 1
```

After `stop()` or a failure, `play()` loads the item again first, from where
it stopped.

## 10. State, progress and events

### State

`PlayerState` combines two independent things: whether playback is wanted
(`playing`) and where the player is in delivering it (`processingState`).
A player can be playing and buffering at once.

| `ProcessingState` | Meaning |
|---|---|
| `idle` | Nothing loaded, stopped, or the current item failed. |
| `loading` | The current item is being opened or positioned. |
| `buffering` | Waiting for data in the middle of playback. |
| `ready` | Able to play. |
| `completed` | The last item played to its end and nothing followed. |

`playing` stays true from `play()` until a pause, stop or interruption,
including while loading or buffering and at `completed`. For the UI:

```dart
StreamBuilder<PlayerState>(
  stream: player.playerStateStream,
  builder: (context, snapshot) {
    final state = snapshot.data ?? PlayerState.idle;
    if (state.isBusy) return const CircularProgressIndicator();   // loading/buffering while playing
    return IconButton(
      icon: Icon(state.showsPause ? Icons.pause : Icons.play_arrow),
      onPressed: state.showsPause ? player.pause : player.play,
    );
  },
);
```

Also: `playingStream`, `processingStateStream`, `speedStream`,
`volumeStream`, `durationStream`.

### Position

`position`, `bufferedPosition`, `duration` and `progress` are synchronous
reads from the native player. `positionStream` and `progressStream`
(position, buffered position and duration together, for a slider) poll every
`PlayerOptions.positionInterval` (200 ms by default) and only while someone
listens. `duration` is null while unknown and for live streams.

```dart
StreamBuilder<PlaybackProgress>(
  stream: player.progressStream,
  builder: (context, snapshot) {
    final p = snapshot.data ?? PlaybackProgress.zero;
    final total = p.duration ?? Duration.zero;
    return Slider(
      max: total.inMilliseconds.toDouble(),
      value: p.position.inMilliseconds.clamp(0, total.inMilliseconds).toDouble(),
      onChanged: (ms) => player.seek(Duration(milliseconds: ms.round())),
    );
  },
);
```

### Events

`player.events` sends one-off events, each with the item's `index` (null if
it left the queue meanwhile) and its `source`:

```dart
player.events.listen((event) {
  switch (event) {
    case ItemCompleted(:final source, :final duration):
      markFinished(source.tag, duration);     // once per real end, never for skips
    case ItemFailed(:final source, :final error):
      showError(source.tag, error.kind);
  }
});
```

`ItemCompleted` is sent once per end, before the player moves on: never for
skips, replacements or stops. It is the right place to mark a chapter as
listened.

## 11. Errors

Failures come as `AudioError(kind, message)`. `message` is for logs; map
`kind` to your own user-facing text:

| `AudioErrorKind` | Typical cause |
|---|---|
| `sourceNotFound` | Missing file or asset; HTTP 401, 403, 404 or 410. |
| `network` | No connection, timeout, server error. |
| `decryption` | Wrong key or IV, or the wrong format declared. |
| `unsupportedFormat` | The platform cannot decode the audio. |
| `rangeNotSupported` | An encrypted stream's server ignores byte ranges or compresses them. |
| `invalidConfiguration` | An invalid request, for example cleartext HTTP that the platform blocks. |
| `unknown` | Anything else. |

Where they surface:

- `setSource` / `setQueue` throw `AudioError` if the item cannot load, and
  `LoadInterruptedException` if a newer load replaced it first (safe to
  ignore in most apps).
- During playback, an `ItemFailed` event, and the player goes `idle`, keeping
  the item and its position; `play()` retries from there.
- `PlayerOptions(maxSkipsOnError: n)` skips up to `n` failing items in a row
  before stopping (0, the default, stops at the first).
- `AudioSession.configure` and `setActive` throw `AudioSessionException` when
  the system refuses.

## 12. Stalls and the network

Without a policy, a connection that goes quiet leaves the player waiting as
long as the platform waits (which can be minutes), and a dropped connection
fails the item. With a `StallPolicy`, the player handles both, staying
"playing" throughout:

```dart
player.stallPolicy = const StallPolicy(
  reconnectAfter: Duration(seconds: 6),   // reload the item over new connections
  giveUpAfter: Duration(seconds: 30),     // then pause and report a network failure
);
```

- After `reconnectAfter` without audio, the item is loaded again where it is.
- A dropped connection is a wait, not a failure: the item is tried again
  shortly.
- Offline, nothing is timed and nothing gives up. When the network comes back
  or moves (Wi-Fi to cellular), a waiting item is loaded again at once.
- After `giveUpAfter` of waiting with a network, the player pauses where it
  was, keeping the item (also on the lock screen), and sends `ItemFailed` with
  `AudioErrorKind.network`. `play()` loads it again from there.

The policy can also be set from the start with `PlayerOptions(stallPolicy:)`.

## 13. Lock screen, notification and media buttons

```dart
await player.setMediaControls(MediaControls(
  commands: MediaControls.spokenWordCommands,   // or defaultCommands, or your own set
  skipInterval: const Duration(seconds: 10),
  onCommand: (event) {
    if (event.command == MediaCommand.next) {
      openNextBook();
      return true;          // handled by the app
    }
    return false;           // let the player apply it
  },
));

await player.setMediaControls(null);            // take the player off the lock screen
```

- **One player at a time** owns the controls; enabling them on a player takes
  them from any other.
- **What is shown** comes from the current source's `MediaMetadata`: title,
  artist, album, artwork, duration, plus position and speed.
- **Commands**: `play`, `pause`, `togglePlayPause`, `stop`, `next`, `previous`,
  `seek` (scrubbing), `skipForward`, `skipBackward`, `changeSpeed`.
  `defaultCommands` suits music (next/previous, seek); `spokenWordCommands`
  suits books and podcasts (±skip, seek).
- **Commands go through the player's own methods** (`play`, `skipToNext`, …),
  so the app sees them in the player's state and events. `onCommand` sees
  every command first; return true to handle it yourself.
- **Where they come from**: the lock screen, Control Center, the Android
  notification, wired and Bluetooth headset buttons, and car stereos over
  Bluetooth. CarPlay and Android Auto apps (browsing a library on the car's
  screen) are not supported.

On iOS the lock screen shows skip buttons instead of next/previous when both
are enabled. On Android the notification shows the skip buttons as custom
buttons, and no queue position.

## 14. The audio session

The session decides how the app's audio coexists with other apps, calls and
the system. There is one per app, shared by every player; players never
configure it themselves. Nothing touches the system until the first player
plays.

```dart
await AudioSession.instance.configure(const AudioSessionConfig.speech());
```

### Presets

| Preset | For | iOS | Android |
|---|---|---|---|
| `music()` (default) | Music, general playback | `playback` category | Music, focus that stops other apps |
| `speech()` | Audiobooks, podcasts, lessons | `playback`, `spokenAudio` mode | Speech; pauses (not ducked) when another app speaks over it |
| `ambient()` | Effects and ambience mixed with other apps | `ambient` (obeys the silent switch, no background) | No focus: plays alongside other apps |
| `managedByApp()` | Another plugin or the app owns the session | Not configured by ovoz | No focus requested by ovoz |

Every preset is a plain configuration; change any field with `copyWith`:

```dart
await AudioSession.instance.configure(
  const AudioSessionConfig.speech().copyWith(
    interruptionPolicy: InterruptionPolicy.pauseOnly,
    deactivateWhenIdle: true,
    options: {SessionOption.allowBluetoothA2dp, SessionOption.allowAirPlay},
  ),
);
```

| Field | Meaning |
|---|---|
| `category`, `mode`, `options`, `routeSharingPolicy` | iOS's `AVAudioSession` settings. |
| `interruptionPolicy` | `pauseAndResume` (default): pause on a call or another app, resume after if the system says so. `pauseOnly`: stay paused. `none`: the app decides (on Android, nothing is paused). |
| `pauseOnBecomingNoisy` | Pause when headphones are unplugged (default true). |
| `deactivateWhenIdle` | Give audio back to other apps a moment after every player stops. |
| `androidAudio` | Android's audio attributes and focus; null derives them from the fields above. |

The session can be configured again at any time; it applies at once if audio
plays, otherwise at the next play.

### Android: audio focus

On Android the session holds audio focus for the whole app (not per player),
requested at the first play. `effectiveAndroidAudio` shows what a
configuration gives; set `androidAudio` to choose yourself:

```dart
await AudioSession.instance.configure(
  const AudioSessionConfig.ambient().copyWith(
    androidAudio: const AndroidAudioConfig(
      usage: AndroidAudioUsage.navigationGuidance,
      contentType: AndroidAudioContentType.speech,
      focus: AndroidAudioFocus.gainTransientMayDuck,
    ),
  ),
);
```

| `AndroidAudioFocus` | Other apps while this one plays |
|---|---|
| `gain` | Stop (music, books). |
| `gainTransient` | Pause for a moment (a voice message). |
| `gainTransientMayDuck` | Lower their volume, or pause if they speak (navigation prompts). |
| `none` | Unaffected; this app is never interrupted either. |

A call or another app taking focus becomes an `AudioInterruption`, handled by
the `interruptionPolicy` as on iOS: a short loss pauses and resumes, a lasting
one pauses for good. When another app ducks this one, Android lowers the
volume itself (ovoz does it before Android 8), or pauses with
`pauseWhenDucked`.

### Session events

Players have already reacted (per the policies) when these arrive; listen to
update the UI or to decide yourself:

```dart
AudioSession.instance.interruptions.listen((e) {
  // e.began, e.shouldResume
});
AudioSession.instance.becomingNoisy.listen((_) { /* headphones unplugged */ });
AudioSession.instance.routeChanges.listen((e) { /* e.reason */ });
AudioSession.instance.events.listen((e) {
  if (e is MediaServicesReset) { /* rare: reload sources */ }
});
```

`AudioSession.instance.setActive(true / false)` activates or deactivates the
session explicitly, for apps managing it themselves or handing audio back to
other apps early. `hasAudioBackgroundMode` says whether the app's background
declarations (section 3 or 4) are in place.

## 15. Several players

Players are independent: each has its own queue, speed, volume and loop
mode, and they play at the same time.

```dart
final bed = AudioPlayer();
await bed.setSource(AudioSource.asset('assets/rain.m4a'));
await bed.setLoopMode(LoopMode.one);     // seamless loop
await bed.setVolume(0.4);

final phrase = AudioPlayer(
  options: const PlayerOptions(positionInterval: Duration(milliseconds: 50)),
);
await phrase.setSource(AudioSource.file(
  path,
  clip: const ClipRange(start: Duration(seconds: 12), end: Duration(seconds: 15)),
));
await phrase.setLoopMode(LoopMode.one);  // loops the range natively
```

The session and audio focus are shared by all of them. Only one owns the
media controls. On Android, other players keep playing in the background only
alongside the player that owns the controls, because its foreground service
is what keeps the app running (iOS's audio background mode covers every
player).

## 16. Player options

```dart
final player = AudioPlayer(options: const PlayerOptions(
  positionInterval: Duration(milliseconds: 200),   // positionStream / progressStream
  previousRestartThreshold: Duration(seconds: 3),  // skipToPrevious restarts after this; zero always goes back
  maxSkipsOnError: 0,                              // failing items skipped in a row before stopping
  pitchCorrection: PitchCorrection.speech,         // initial pitch correction
  stallPolicy: null,                               // initial StallPolicy
));
```

## 17. Testing your code

`package:ovoz/testing.dart` gives fakes of the native engines, so code that
uses `AudioPlayer` and `AudioSession` can be tested without a device:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ovoz/ovoz.dart';
import 'package:ovoz/testing.dart';

void main() {
  test('moves to the next chapter', () async {
    final engine = FakePlayerEngine();       // autoLoad: true by default
    final player = AudioPlayer.withEngine(engine);
    AudioSession.debugUseEngine(FakeSessionEngine());

    await player.setQueue([AudioSource.file('/a.mp3'), AudioSource.file('/b.mp3')]);
    await player.play();
    engine.finishItem();                     // the current item plays to its end
    await pumpEventQueue();

    expect(player.currentIndex, 1);
  });
}
```

`FakePlayerEngine` can also `completeLoad(duration)` (with `autoLoad: false`),
`failCurrent(error)`, `startBuffering()` / `finishBuffering()`,
`changeNetwork(available:)`, and records every command in `log`.
`FakeSessionEngine.send(event)` posts session events; `configurations` and
`active` record what the code asked for.

## 18. Coming from just_audio and audio_service

The player model is just_audio's (`playing` + `processingState`, the same
state names), so most code carries over.

| just_audio / audio_service | ovoz |
|---|---|
| `AudioPlayer()` | `AudioPlayer()` |
| `setAudioSource(ConcatenatingAudioSource(...))` | `setQueue([...])` |
| `setUrl`, `setFilePath`, `setAsset` | `setSource(AudioSource.url / file / asset(...))` |
| `LockCachingAudioSource`, a local proxy or a decrypting `StreamAudioSource` | `AudioSource.file/url(..., encryption: AesCtrEncryption(...))` |
| `ClippingAudioSource` | `clip: ClipRange(...)` |
| `seek(pos, index: i)`, `seekToNext()`, `seekToPrevious()` | `seek(pos, index: i)`, `skipToNext()`, `skipToPrevious()` |
| `currentIndexStream`, `sequenceStateStream` | `currentIndexStream`, `queueStream` |
| `playbackEventStream` errors | `events` (`ItemFailed`) |
| `processingState == completed` to detect an item's end | `ItemCompleted` |
| `audio_session`'s `AudioSession.instance.configure(...)` | ovoz's `AudioSession.instance.configure(AudioSessionConfig...)` |
| `AudioHandler`, `MediaItem` | `setMediaControls(MediaControls(...))`, `MediaMetadata` on each source |
| `AudioService.init(...)` | nothing: there is no separate service to start |
| `AudioServiceActivity` | a cached engine in `MainActivity` (section 4) |
| audio_service's `<service>` and `MediaButtonReceiver` in the manifest | `OvozPlaybackService` (section 4) |

Remove audio_service's and just_audio_background's manifest entries and
their initialization when switching: two owners of the media session conflict.

## 19. Platform differences

| | iOS | Android |
|---|---|---|
| Native player | AVFoundation (`AVQueuePlayer`) | Media3 ExoPlayer 1.11 |
| Bridge | FFI to Swift (ffigen) | JNI to Kotlin (jnigen) |
| Formats | MP3, AAC/M4A, WAV, AIFF, CAF, FLAC, HLS | MP3, AAC/M4A, WAV, FLAC, Ogg Vorbis/Opus, HLS |
| Not supported | Ogg Vorbis, Opus outside CAF | AIFF, CAF |
| HLS detection | Automatic | By the `.m3u8` extension |
| Background | `audio` background mode | Foreground service (`OvozPlaybackService`) |
| After a swipe-away | Stops: iOS ends the app | Keeps playing with a cached engine, stops without one |
| Lock screen | Now Playing (lock screen, Control Center, Dynamic Island) | Media notification and lock-screen player |
| Queue position on the lock screen | Shown | Not shown |
| Interruptions | `AVAudioSession` notifications | Audio focus changes |
| `InterruptionPolicy.none` | The system still pauses; the app resumes | Nothing is paused |
| Read-ahead of local files | On demand (iOS 16+) | About 50 s ahead |

## 20. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Playback stops when the screen locks (iOS) | The `audio` background mode is missing, or the session is `ambient`. Debug builds print a warning. |
| No notification, playback stops in the background (Android) | `OvozPlaybackService` or its permissions are missing from the manifest. Debug builds print a warning. |
| Playback stops when the app is swiped away (Android) | No cached Flutter engine (section 4). |
| `IllegalStateException: ovoz: call the engine from the main isolate…` (Android) | A player was used from another isolate, or the app turned off Flutter's merged platform and UI threads. |
| `ArgumentError` creating an encrypted source | It needs `format:`. |
| `ItemFailed` with `decryption` | Wrong key or IV, wrong `dataOffset`, or the wrong `format` declared. |
| `ItemFailed` with `rangeNotSupported` | The server returns 200 instead of 206 for ranges, or gzip-compresses the response. Serve the file with range support and no compression. |
| `ItemFailed` with `invalidConfiguration` on an `http://` URL | Cleartext is blocked: add an ATS exception (iOS) or a network security configuration (Android). |
| An HLS stream fails on Android | The URL does not end in `.m3u8`. |
| Jetifier warning about `media3-session` | Harmless (section 4). |
| Another app's notification or lock-screen player fights with this one | Another plugin also owns the media session; remove it. |

## 21. Checklist before release

- [ ] `pubspec.yaml` pins ovoz to a tag or commit.
- [ ] iOS: deployment target 15.0+, `audio` background mode, ATS exceptions
      for any `http://` host.
- [ ] Android: `compileSdk` 36, `minSdk` 23+, `OvozPlaybackService` and both
      foreground-service permissions, `ovoz_notification_icon`, a network
      security configuration for any `http://` host.
- [ ] Android: a cached Flutter engine, if playback should survive a
      swipe-away.
- [ ] The session configured once at startup with the right preset.
- [ ] Every `AudioPlayer` disposed.
- [ ] Errors mapped from `AudioErrorKind` to user-facing text.
- [ ] On real devices: lock-screen and notification buttons, wired and
      Bluetooth headset buttons, a phone call during playback, unplugging
      headphones, another app's audio over yours, a long pause then resume
      from the lock screen, the app swiped away while playing (Android), and
      a phone from a maker with an aggressive battery saver.
