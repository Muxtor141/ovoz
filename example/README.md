# ovoz example

One screen per use case:

| Screen | Shows |
|---|---|
| Audiobook | Mutolaa's case: AES-128-CTR encrypted chapters decrypted in memory, chapter list (jump), ±10 s, speed, "pause after this chapter", lock screen with artwork |
| Music queue | shuffle, loop modes, gapless transition (a chord split across two files), reorder, remove, add |
| Streaming | an encrypted file streamed by byte range with a bearer token, a plain file with an auth header, a refused request, HLS, MP3 over HTTPS |
| Mixer | several players at once: a seamless loop bed with volume, overlapping sound effects, a phrase looper (clip + loop + speed) |
| Audio session | presets, options and policies at runtime, live system events |

Run it on an iOS simulator or device (iOS 15+):

```bash
flutter run
```

The engine's integration tests run the real engine through the public API:

```bash
flutter test integration_test -d <simulator id>
```

All audio and the cover are synthesized by `../tool/make_example_media.py`,
except `assets/audio/sample.mp3`, from the Dart project's ffigen examples
(BSD-3-Clause, see `assets/audio/NOTICE.md`). The demo's encryption key is
in the code for the demo only; a real app gets keys from its backend.
