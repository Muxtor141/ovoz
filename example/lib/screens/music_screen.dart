import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ovoz/ovoz.dart';

import 'package:ovoz_example/demo_media.dart';
import 'package:ovoz_example/widgets/player_controls.dart';

/// USE-01: a playlist with shuffle, loop, gapless transitions, queue edits
/// and lock-screen controls.
class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  final _player = AudioPlayer(options: const PlayerOptions(pitchCorrection: PitchCorrection.music));
  final _log = <String>[];
  StreamSubscription<PlayerEvent>? _events;
  var _added = 0;

  @override
  void initState() {
    super.initState();
    _events = _player.events.listen((event) => setState(() => _log.add(describeEvent(event))));
    unawaited(_open());
  }

  Future<void> _open() async {
    await AudioSession.instance.configure(const AudioSessionConfig.music());
    await _player.setQueue(DemoMedia.songs());
    await _player.setMediaControls(const MediaControls());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  void _addSong() {
    _added++;
    final songs = DemoMedia.songs();
    final song = songs[_added % 3];
    unawaited(
      _player.add(
        song.copyWith(
          metadata: MediaMetadata(title: '${song.metadata!.title} (added $_added)', artist: 'Ovoz demo'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Music queue'),
      actions: [IconButton(icon: const Icon(Icons.playlist_add), onPressed: _addSong)],
    ),
    body: Column(
      children: [
        const SizedBox(height: 8),
        StreamBuilder<int?>(
          stream: _player.currentIndexStream,
          builder: (context, _) => Text(
            _player.currentSource?.metadata?.title ?? '—',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        StateLabel(player: _player),
        ProgressBar(player: _player),
        _MusicTransport(player: _player),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'The two "Gapless chord" parts are one sustained chord cut in half: a gap between them would be audible. '
            'Drag to reorder, swipe to remove.',
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(child: _QueueList(player: _player)),
        Padding(
          padding: const EdgeInsets.all(12),
          child: EventLog(lines: _log),
        ),
      ],
    ),
  );
}

class _MusicTransport extends StatelessWidget {
  const _MusicTransport({required this.player});

  final AudioPlayer player;

  @override
  Widget build(BuildContext context) => StreamBuilder<QueueState>(
    stream: player.queueStream,
    initialData: player.queueState,
    builder: (context, snapshot) {
      final queue = snapshot.requireData;
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Shuffle',
            isSelected: queue.shuffle,
            icon: const Icon(Icons.shuffle),
            selectedIcon: const Icon(Icons.shuffle_on_outlined),
            onPressed: () => player.setShuffle(!queue.shuffle),
          ),
          IconButton(icon: const Icon(Icons.skip_previous), onPressed: player.skipToPrevious),
          PlayPauseButton(player: player),
          IconButton(icon: const Icon(Icons.skip_next), onPressed: player.hasNext ? player.skipToNext : null),
          IconButton(
            tooltip: 'Loop: ${queue.loopMode.name}',
            icon: Icon(switch (queue.loopMode) {
              LoopMode.off => Icons.repeat,
              LoopMode.all => Icons.repeat_on_outlined,
              LoopMode.one => Icons.repeat_one_on_outlined,
            }),
            onPressed: () =>
                player.setLoopMode(LoopMode.values[(queue.loopMode.index + 1) % LoopMode.values.length]),
          ),
        ],
      );
    },
  );
}

class _QueueList extends StatelessWidget {
  const _QueueList({required this.player});

  final AudioPlayer player;

  @override
  Widget build(BuildContext context) => StreamBuilder<QueueState>(
    stream: player.queueStream,
    initialData: player.queueState,
    builder: (context, snapshot) {
      final queue = snapshot.requireData;
      return ReorderableListView.builder(
        itemCount: queue.sources.length,
        onReorderItem: player.move,
        itemBuilder: (context, i) {
          final source = queue.sources[i];
          return Dismissible(
            key: ObjectKey(source),
            onDismissed: (_) => player.removeAt(i),
            child: ListTile(
              key: ObjectKey(source),
              leading: Icon(i == queue.currentIndex ? Icons.graphic_eq : Icons.music_note),
              title: Text(source.metadata?.title ?? source.uri.pathSegments.last),
              subtitle: queue.shuffle ? Text('plays ${queue.order.indexOf(i) + 1}. in shuffle') : null,
              selected: i == queue.currentIndex,
              onTap: () => player.skipToIndex(i),
            ),
          );
        },
      );
    },
  );
}
