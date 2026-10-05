import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ovoz/ovoz.dart';

import 'package:ovoz_example/demo_media.dart';
import 'package:ovoz_example/local_server.dart';
import 'package:ovoz_example/widgets/player_controls.dart';

/// USE-03: remote files and HLS, with auth headers and buffering — and an
/// encrypted file streamed by byte range, decrypted as it arrives. No local
/// proxy anywhere.
class StreamingScreen extends StatefulWidget {
  const StreamingScreen({super.key});

  @override
  State<StreamingScreen> createState() => _StreamingScreenState();
}

class _Stream {
  const _Stream(this.title, this.subtitle, this.source);

  final String title;
  final String subtitle;
  final AudioSource Function(LocalServer server) source;
}

class _StreamingScreenState extends State<StreamingScreen> {
  final _player = AudioPlayer();
  final _log = <String>[];
  LocalServer? _server;
  StreamSubscription<PlayerEvent>? _events;
  String? _selected;

  static final _streams = [
    _Stream(
      'Encrypted chapter over HTTP',
      'AES-CTR by byte range + bearer token (in-app server)',
      (server) => AudioSource.url(
        server.url('chapter_2.m4a.enc'),
        headers: const {'Authorization': 'Bearer ${LocalServer.token}'},
        encryption: DemoMedia.encryption,
        format: AudioFormat.m4a,
        metadata: const MediaMetadata(title: 'Chapter 2, streamed'),
      ),
    ),
    _Stream(
      'Plain file with an auth header',
      'The header reaches the server without a proxy',
      (server) => AudioSource.url(
        server.url('song_b.m4a'),
        headers: const {'Authorization': 'Bearer ${LocalServer.token}'},
        metadata: const MediaMetadata(title: 'Noon, streamed'),
      ),
    ),
    _Stream(
      'Missing token',
      'The server answers 401: an error, not a hang',
      (server) => AudioSource.url(server.url('song_c.m4a')),
    ),
    _Stream(
      'HLS (Apple test stream)',
      'devstreaming-cdn.apple.com — needs internet',
      (_) => AudioSource.url(
        Uri.parse(
          'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
        ),
        metadata: const MediaMetadata(title: 'Bip-bop HLS'),
      ),
    ),
    _Stream(
      'MP3 over HTTPS',
      'soundhelix.com — needs internet',
      (_) => AudioSource.url(
        Uri.parse('https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3'),
        metadata: const MediaMetadata(title: 'SoundHelix Song 1'),
      ),
    ),
  ];

  @override
  void initState() {
    super.initState();
    _events = _player.events.listen((event) => setState(() => _log.add(describeEvent(event))));
    unawaited(_start());
  }

  Future<void> _start() async {
    await AudioSession.instance.configure(const AudioSessionConfig.music());
    final server = await LocalServer.start();
    if (!mounted) {
      await server.close();
      return;
    }
    setState(() => _server = server);
  }

  Future<void> _open(_Stream stream) async {
    final server = _server;
    if (server == null) return;
    setState(() => _selected = stream.title);
    try {
      final duration = await _player.setSource(stream.source(server));
      setState(
        () => _log.add('Loaded: ${duration == null ? 'live / unknown length' : formatDuration(duration)}'),
      );
      await _player.play();
    } on AudioError catch (e) {
      setState(() => _log.add('Load failed (${e.kind.name})'));
    } on LoadInterruptedException {
      // Another stream was chosen meanwhile.
    }
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_player.dispose());
    unawaited(_server?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Streaming')),
    body: ListView(
      children: [
        for (final stream in _streams)
          ListTile(
            title: Text(stream.title),
            subtitle: Text(stream.subtitle),
            selected: stream.title == _selected,
            trailing: const Icon(Icons.play_circle_outline),
            enabled: _server != null,
            onTap: () => _open(stream),
          ),
        const Divider(),
        Center(child: StateLabel(player: _player)),
        ProgressBar(player: _player),
        Center(child: PlayPauseButton(player: _player)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: EventLog(lines: [..._log, if (_server != null) ..._server!.requests.reversed.take(2)]),
        ),
      ],
    ),
  );
}
