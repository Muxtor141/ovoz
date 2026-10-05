import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ovoz/ovoz.dart';

import 'package:ovoz_example/widgets/player_controls.dart';

/// The app-wide audio session: presets, policies, and what the system does
/// (interruptions, unplugged headphones, route changes).
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final _session = AudioSession.instance;
  final _log = <String>[];
  StreamSubscription<SessionEvent>? _events;
  String? _error;

  static const _presets = {
    'Music': AudioSessionConfig.music(),
    'Speech': AudioSessionConfig.speech(),
    'Ambient': AudioSessionConfig.ambient(),
    'Managed by app': AudioSessionConfig.managedByApp(),
  };

  @override
  void initState() {
    super.initState();
    _events = _session.events.listen((event) => setState(() => _log.add('$event')));
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  Future<void> _apply(AudioSessionConfig config) async {
    try {
      await _session.configure(config);
      setState(() => _error = null);
    } on AudioSessionException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _session.config;
    return Scaffold(
      appBar: AppBar(title: const Text('Audio session')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Preset', style: Theme.of(context).textTheme.titleMedium),
          Wrap(
            spacing: 8,
            children: [
              for (final MapEntry(:key, :value) in _presets.entries)
                ChoiceChip(label: Text(key), selected: config == value, onSelected: (_) => _apply(value)),
            ],
          ),
          const SizedBox(height: 8),
          Text('$config'),
          SwitchListTile(
            title: const Text('Mix with other apps'),
            value: config.options.contains(SessionOption.mixWithOthers),
            onChanged: config.category == SessionCategory.playback
                ? (on) => _apply(
                    config.copyWith(
                      options: on
                          ? {...config.options, SessionOption.mixWithOthers}
                          : ({...config.options}..remove(SessionOption.mixWithOthers)),
                    ),
                  )
                : null,
          ),
          SwitchListTile(
            title: const Text('Pause when headphones are unplugged'),
            value: config.pauseOnBecomingNoisy,
            onChanged: (on) => _apply(config.copyWith(pauseOnBecomingNoisy: on)),
          ),
          SwitchListTile(
            title: const Text('Hand audio back when idle'),
            subtitle: const Text('Deactivate the session once nothing plays'),
            value: config.deactivateWhenIdle,
            onChanged: (on) => _apply(config.copyWith(deactivateWhenIdle: on)),
          ),
          ListTile(
            title: const Text('Interruptions'),
            trailing: DropdownButton<InterruptionPolicy>(
              value: config.interruptionPolicy,
              onChanged: (policy) => _apply(config.copyWith(interruptionPolicy: policy)),
              items: [
                for (final policy in InterruptionPolicy.values)
                  DropdownMenuItem(value: policy, child: Text(policy.name)),
              ],
            ),
          ),
          ListTile(
            title: const Text('Info.plist "audio" background mode'),
            trailing: Icon(_session.hasAudioBackgroundMode ? Icons.check_circle : Icons.error_outline),
          ),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
          const Text(
            'Start audio in another screen, then call this simulator/device, set an alarm, '
            'or unplug headphones to see the events and the policies at work.',
          ),
          const SizedBox(height: 8),
          EventLog(lines: _log),
        ],
      ),
    );
  }
}
