import 'package:flutter/material.dart';

import 'package:ovoz_example/screens/audiobook_screen.dart';
import 'package:ovoz_example/screens/mixer_screen.dart';
import 'package:ovoz_example/screens/music_screen.dart';
import 'package:ovoz_example/screens/session_screen.dart';
import 'package:ovoz_example/screens/streaming_screen.dart';

void main() => runApp(const OvozDemoApp());

class OvozDemoApp extends StatelessWidget {
  const OvozDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ovoz demo',
    theme: ThemeData(colorSchemeSeed: const Color(0xFF6B4FBB), useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: const Color(0xFF6B4FBB),
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const HomeScreen(),
  );
}

class _Demo {
  const _Demo(this.title, this.subtitle, this.icon, this.builder);

  final String title;
  final String subtitle;
  final IconData icon;
  final WidgetBuilder builder;
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static final _demos = [
    _Demo(
      'Audiobook',
      'Encrypted chapters, speed, sleep after chapter, lock screen',
      Icons.menu_book,
      (_) => const AudiobookScreen(),
    ),
    _Demo(
      'Music queue',
      'Shuffle, loop, gapless, queue edits',
      Icons.queue_music,
      (_) => const MusicScreen(),
    ),
    _Demo(
      'Streaming',
      'HLS, auth headers, encrypted byte ranges',
      Icons.cloud_outlined,
      (_) => const StreamingScreen(),
    ),
    _Demo(
      'Mixer',
      'Several players: loop bed, effects, phrase looper',
      Icons.tune,
      (_) => const MixerScreen(),
    ),
    _Demo(
      'Audio session',
      'Presets, policies, system events',
      Icons.settings_voice,
      (_) => const SessionScreen(),
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ovoz')),
    body: ListView(
      children: [
        for (final demo in _demos)
          ListTile(
            leading: Icon(demo.icon),
            title: Text(demo.title),
            subtitle: Text(demo.subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: demo.builder)),
          ),
      ],
    ),
  );
}
