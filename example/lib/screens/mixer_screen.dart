import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ovoz/ovoz.dart';

import 'package:ovoz_example/widgets/player_controls.dart';

/// Several players at once (USE-04 to USE-07): a seamless looping bed with
/// its own volume, sound effects on top, and a phrase looper for language
/// practice — the shape of Mutolaa's quote editor (narration, bed, sound).
class MixerScreen extends StatefulWidget {
  const MixerScreen({super.key});

  @override
  State<MixerScreen> createState() => _MixerScreenState();
}

class _MixerScreenState extends State<MixerScreen> {
  final _bed = AudioPlayer();
  final _phrase = AudioPlayer(options: const PlayerOptions(positionInterval: Duration(milliseconds: 50)));

  /// Two players per effect, so a quick second tap overlaps the first.
  final _effects = <String, List<AudioPlayer>>{};
  final _nextVoice = <String, int>{};
  var _bedVolume = 0.6;
  var _range = const RangeValues(2, 5);

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    await _bed.setSource(AudioSource.asset('assets/audio/rain_loop.m4a'));
    await _bed.setLoopMode(LoopMode.one);
    await _bed.setVolume(_bedVolume);
    await _phrase.setLoopMode(LoopMode.one);
    await _loadPhrase();
    for (final name in ['click', 'ding']) {
      final voices = [AudioPlayer(), AudioPlayer()];
      _effects[name] = voices;
      for (final voice in voices) {
        await voice.setSource(AudioSource.asset('assets/audio/$name.wav'));
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadPhrase() async {
    final wasPlaying = _phrase.playing;
    await _phrase.setSource(
      AudioSource.asset(
        'assets/audio/sample.mp3',
        clip: ClipRange(
          start: Duration(milliseconds: (_range.start * 1000).round()),
          end: Duration(milliseconds: (_range.end * 1000).round()),
        ),
      ),
    );
    if (wasPlaying) await _phrase.play();
  }

  Future<void> _fire(String name) async {
    final voices = _effects[name];
    if (voices == null) return;
    final index = _nextVoice[name] = ((_nextVoice[name] ?? -1) + 1) % voices.length;
    final voice = voices[index];
    await voice.seek(Duration.zero);
    await voice.play();
  }

  @override
  void dispose() {
    for (final player in [_bed, _phrase, for (final voices in _effects.values) ...voices]) {
      unawaited(player.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Mixer: players at once')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Rain bed (seamless loop)', style: Theme.of(context).textTheme.titleMedium),
        Row(
          children: [
            PlayPauseButton(player: _bed, size: 44),
            Expanded(
              child: Slider(
                value: _bedVolume,
                onChanged: (v) {
                  setState(() => _bedVolume = v);
                  unawaited(_bed.setVolume(v));
                },
              ),
            ),
          ],
        ),
        const Divider(height: 32),
        Text('Sound effects', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          children: [
            for (final name in ['click', 'ding'])
              FilledButton.tonal(
                onPressed: _effects.containsKey(name) ? () => _fire(name) : null,
                child: Text(name),
              ),
          ],
        ),
        const Divider(height: 32),
        Text('Phrase looper (clip + loop one)', style: Theme.of(context).textTheme.titleMedium),
        RangeSlider(
          max: 11.7,
          divisions: 117,
          values: _range,
          labels: RangeLabels('${_range.start.toStringAsFixed(1)} s', '${_range.end.toStringAsFixed(1)} s'),
          onChanged: (v) {
            if (v.end - v.start >= 0.5) setState(() => _range = v);
          },
          onChangeEnd: (_) => _loadPhrase(),
        ),
        ProgressBar(player: _phrase),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PlayPauseButton(player: _phrase, size: 44),
            const SizedBox(width: 16),
            for (final speed in [0.5, 0.75, 1.0])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: StreamBuilder<double>(
                  stream: _phrase.speedStream,
                  initialData: _phrase.speed,
                  builder: (context, snapshot) => ChoiceChip(
                    label: Text('${speed}x'),
                    selected: snapshot.requireData == speed,
                    onSelected: (_) => _phrase.setSpeed(speed),
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}
