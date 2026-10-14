import 'dart:io';

import 'package:ovoz/src/engine/player_engine.dart';
import 'package:ovoz/src/engine/session_engine.dart';
import 'package:ovoz/src/platform/android/android_player_engine.dart';
import 'package:ovoz/src/platform/android/android_session_engine.dart';
import 'package:ovoz/src/platform/darwin/darwin_player_engine.dart';
import 'package:ovoz/src/platform/darwin/darwin_session_engine.dart';

/// The engine for the platform the app runs on, behind the same contract on
/// each (D-01, D-18): Swift through ffigen on iOS, Kotlin on Media3 through
/// jnigen on Android.
PlayerEngine createPlayerEngine() {
  if (Platform.isIOS) return DarwinPlayerEngine();
  if (Platform.isAndroid) return AndroidPlayerEngine();
  throw UnsupportedError(_unsupported);
}

SessionEngine createSessionEngine() {
  if (Platform.isIOS) return DarwinSessionEngine();
  if (Platform.isAndroid) return AndroidSessionEngine();
  throw UnsupportedError(_unsupported);
}

const _unsupported = 'ovoz plays audio on iOS and Android only.';
