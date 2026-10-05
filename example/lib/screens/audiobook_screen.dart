import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ovoz/ovoz.dart';

import 'package:ovoz_example/demo_media.dart';
import 'package:ovoz_example/widgets/player_controls.dart';

/// USE-02, the Mutolaa case: encrypted downloaded chapters, chapter list,
/// ±10 s, speed with pitch kept, "stop after this chapter", lock screen.
class AudiobookScreen extends StatefulWidget {
  const AudiobookScreen({super.key});

  @override
  State<AudiobookScreen> createState() => _AudiobookScreenState();
}

class _AudiobookScreenState extends State<AudiobookScreen> {
  // Chapters behave like Mutolaa's: "previous" always goes to the previous
  // chapter, and a failing chapter stops playback instead of skipping it.
  final _player = AudioPlayer(options: const PlayerOptions(previousRestartThreshold: Duration.zero));
  final _log = <String>[];
  StreamSubscription<PlayerEvent>? _events;
  String? _error;

  @override
  void initState() {
    super.initState();
    _events = _player.events.listen((event) => setState(() => _log.add(describeEvent(event))));
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await AudioSession.instance.configure(const AudioSessionConfig.speech());
      await _player.setQueue(await DemoMedia.bookChapters());
      await _player.setMediaControls(
        const MediaControls(
          commands: {...MediaControls.spokenWordCommands, MediaCommand.next, MediaCommand.previous},
          skipInterval: Duration(seconds: 10),
        ),
      );
    } on AudioError catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Audiobook (encrypted)')),
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        _NowPlaying(player: _player),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ProgressBar(player: _player),
        _Transport(player: _player),
        const SizedBox(height: 8),
        _SpeedChips(player: _player),
        _SleepAfterChapter(player: _player),
        const Divider(),
        _ChapterList(player: _player),
        Padding(
          padding: const EdgeInsets.all(16),
          child: EventLog(lines: _log),
        ),
      ],
    ),
  );
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.player});

  final AudioPlayer player;

  @override
  Widget build(BuildContext context) => StreamBuilder<int?>(
    stream: player.currentIndexStream,
    builder: (context, _) {
      final metadata = player.currentSource?.metadata;
      return Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset('assets/images/cover.png', width: 160, height: 160),
          ),
          const SizedBox(height: 12),
          Text(metadata?.title ?? 'Loading…', style: Theme.of(context).textTheme.titleLarge),
          Text(metadata?.album ?? '', style: Theme.of(context).textTheme.bodyMedium),
          StateLabel(player: player),
        ],
      );
    },
  );
}

class _Transport extends StatelessWidget {
  const _Transport({required this.player});

  final AudioPlayer player;

  @override
  Widget build(BuildContext context) => StreamBuilder<int?>(
    stream: player.currentIndexStream,
    builder: (context, _) => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous),
          onPressed: player.hasPrevious ? player.skipToPrevious : null,
        ),
        IconButton(
          icon: const Icon(Icons.replay_10),
          onPressed: () => player.seekBy(const Duration(seconds: -10)),
        ),
        PlayPauseButton(player: player),
        IconButton(
          icon: const Icon(Icons.forward_10),
          onPressed: () => player.seekBy(const Duration(seconds: 10)),
        ),
        IconButton(icon: const Icon(Icons.skip_next), onPressed: player.hasNext ? player.skipToNext : null),
      ],
    ),
  );
}

class _SpeedChips extends StatelessWidget {
  const _SpeedChips({required this.player});

  final AudioPlayer player;

  static const _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) => StreamBuilder<double>(
    stream: player.speedStream,
    initialData: player.speed,
    builder: (context, snapshot) => Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      children: [
        for (final speed in _speeds)
          ChoiceChip(
            label: Text('${speed}x'),
            selected: snapshot.requireData == speed,
            onSelected: (_) => player.setSpeed(speed),
          ),
      ],
    ),
  );
}

class _SleepAfterChapter extends StatefulWidget {
  const _SleepAfterChapter({required this.player});

  final AudioPlayer player;

  @override
  State<_SleepAfterChapter> createState() => _SleepAfterChapterState();
}

class _SleepAfterChapterState extends State<_SleepAfterChapter> {
  @override
  Widget build(BuildContext context) => SwitchListTile(
    title: const Text('Pause after this chapter'),
    subtitle: const Text('A sleep timer\'s "end of chapter"'),
    value: widget.player.pauseAtItemEnd,
    onChanged: (value) => setState(() => widget.player.pauseAtItemEnd = value),
  );
}

class _ChapterList extends StatelessWidget {
  const _ChapterList({required this.player});

  final AudioPlayer player;

  @override
  Widget build(BuildContext context) => StreamBuilder<QueueState>(
    stream: player.queueStream,
    initialData: player.queueState,
    builder: (context, snapshot) {
      final queue = snapshot.requireData;
      return Column(
        children: [
          for (var i = 0; i < queue.sources.length; i++)
            ListTile(
              leading: Icon(i == queue.currentIndex ? Icons.graphic_eq : Icons.lock_outline),
              title: Text(queue.sources[i].metadata?.title ?? 'Chapter ${i + 1}'),
              subtitle: const Text('AES-128-CTR, decrypted in memory'),
              selected: i == queue.currentIndex,
              onTap: () => player.skipToIndex(i),
            ),
        ],
      );
    },
  );
}
