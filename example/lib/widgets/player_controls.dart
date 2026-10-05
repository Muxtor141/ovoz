import 'package:flutter/material.dart';
import 'package:ovoz/ovoz.dart';

/// Play, pause, or a spinner while loading or buffering.
class PlayPauseButton extends StatelessWidget {
  const PlayPauseButton({super.key, required this.player, this.size = 56});

  final AudioPlayer player;
  final double size;

  @override
  Widget build(BuildContext context) => StreamBuilder<PlayerState>(
    stream: player.playerStateStream,
    initialData: player.playerState,
    builder: (context, snapshot) {
      final state = snapshot.requireData;
      if (state.isBusy) {
        return SizedBox.square(
          dimension: size,
          child: const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator()),
        );
      }
      return IconButton.filled(
        iconSize: size * 0.6,
        icon: Icon(state.showsPause ? Icons.pause : Icons.play_arrow),
        onPressed: state.showsPause ? player.pause : player.play,
      );
    },
  );
}

/// A seek bar with the buffered range behind it. Holds its own value while
/// dragged, so position updates do not fight the finger.
class ProgressBar extends StatefulWidget {
  const ProgressBar({super.key, required this.player});

  final AudioPlayer player;

  @override
  State<ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<ProgressBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) => StreamBuilder<PlaybackProgress>(
    stream: widget.player.progressStream,
    initialData: widget.player.progress,
    builder: (context, snapshot) {
      final progress = snapshot.requireData;
      final total = progress.duration?.inMilliseconds.toDouble() ?? 0;
      final max = total > 0 ? total : 1.0;
      final position = (_dragging ?? progress.position.inMilliseconds.toDouble()).clamp(0.0, max);
      final buffered = progress.bufferedPosition.inMilliseconds.toDouble().clamp(0.0, max);
      return Column(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: LinearProgressIndicator(
                  value: buffered / max,
                  minHeight: 3,
                  backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  color: Theme.of(context).colorScheme.secondaryContainer,
                ),
              ),
              Slider(
                max: max,
                value: position,
                onChanged: total > 0 ? (v) => setState(() => _dragging = v) : null,
                onChangeEnd: (v) {
                  setState(() => _dragging = null);
                  widget.player.seek(Duration(milliseconds: v.round()));
                },
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatDuration(Duration(milliseconds: position.round()))),
                Text(progress.duration == null ? '--:--' : formatDuration(progress.duration!)),
              ],
            ),
          ),
        ],
      );
    },
  );
}

/// The player's state in words, for the demos.
class StateLabel extends StatelessWidget {
  const StateLabel({super.key, required this.player});

  final AudioPlayer player;

  @override
  Widget build(BuildContext context) => StreamBuilder<PlayerState>(
    stream: player.playerStateStream,
    initialData: player.playerState,
    builder: (context, snapshot) {
      final state = snapshot.requireData;
      return Text(
        '${state.processingState.name}${state.playing ? ' · playing' : ''}',
        style: Theme.of(context).textTheme.labelMedium,
      );
    },
  );
}

/// The last few lines of something happening.
class EventLog extends StatelessWidget {
  const EventLog({super.key, required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) => Card.outlined(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Events', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          if (lines.isEmpty) const Text('—'),
          for (final line in lines.reversed.take(6)) Text(line, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );
}

String formatDuration(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$minutes:$seconds' : '$minutes:$seconds';
}

/// A human line for a player event.
String describeEvent(PlayerEvent event) => switch (event) {
  ItemCompleted(:final index) => 'Item ${index ?? '?'} completed',
  ItemFailed(:final index, :final error) => 'Item ${index ?? '?'} failed: ${error.kind.name}',
};
