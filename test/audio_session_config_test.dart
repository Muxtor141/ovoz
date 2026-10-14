import 'package:flutter_test/flutter_test.dart';
import 'package:ovoz/ovoz.dart';

void main() {
  group('Android audio from the session presets', () {
    test('music takes focus that stops other apps', () {
      expect(const AudioSessionConfig.music().effectiveAndroidAudio, const AndroidAudioConfig());
    });

    test('speech is speech content, paused rather than ducked', () {
      expect(
        const AudioSessionConfig.speech().effectiveAndroidAudio,
        const AndroidAudioConfig(contentType: AndroidAudioContentType.speech, pauseWhenDucked: true),
      );
    });

    test('ambient takes no focus, so it plays alongside other apps', () {
      expect(const AudioSessionConfig.ambient().effectiveAndroidAudio.focus, AndroidAudioFocus.none);
      expect(
        const AudioSessionConfig(options: {SessionOption.mixWithOthers}).effectiveAndroidAudio.focus,
        AndroidAudioFocus.none,
      );
    });

    test('ducking others asks for focus that lets them duck', () {
      for (final option in [SessionOption.duckOthers, SessionOption.interruptSpokenAudioAndMixWithOthers]) {
        expect(
          AudioSessionConfig(options: {option}).effectiveAndroidAudio.focus,
          AndroidAudioFocus.gainTransientMayDuck,
          reason: option.name,
        );
      }
    });

    test('movie playback is movie content', () {
      expect(
        const AudioSessionConfig(mode: SessionMode.moviePlayback).effectiveAndroidAudio.contentType,
        AndroidAudioContentType.movie,
      );
    });

    test('an explicit Android configuration wins, and takes part in equality', () {
      const custom = AndroidAudioConfig(
        usage: AndroidAudioUsage.navigationGuidance,
        focus: AndroidAudioFocus.gainTransientMayDuck,
      );
      final config = const AudioSessionConfig.speech().copyWith(androidAudio: custom);
      expect(config.effectiveAndroidAudio, custom);
      expect(config, isNot(const AudioSessionConfig.speech()));
      expect(config, const AudioSessionConfig.speech().copyWith(androidAudio: custom));
    });
  });
}
