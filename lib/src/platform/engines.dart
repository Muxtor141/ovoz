import 'dart:io';

import 'package:ovoz/src/engine/player_engine.dart';
import 'package:ovoz/src/engine/session_engine.dart';
import 'package:ovoz/src/platform/darwin/darwin_player_engine.dart';
import 'package:ovoz/src/platform/darwin/darwin_session_engine.dart';

/// The engine for the platform the app runs on. Android (Media3 through
/// jnigen) slots in here behind the same contract (D-01, D-18).
PlayerEngine createPlayerEngine() {
  if (Platform.isIOS) return DarwinPlayerEngine();
  throw UnsupportedError(_unsupported);
}

SessionEngine createSessionEngine() {
  if (Platform.isIOS) return DarwinSessionEngine();
  throw UnsupportedError(_unsupported);
}

const _unsupported = 'ovoz plays audio on iOS only so far; Android is planned behind the same API.';
