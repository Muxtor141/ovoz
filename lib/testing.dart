/// The engine contracts and fakes of them, for testing code that uses ovoz
/// without a device:
///
/// ```dart
/// final engine = FakePlayerEngine();
/// final player = AudioPlayer.withEngine(engine);
/// await player.setQueue([...]);
/// engine.finishItem(); // the current item plays to its end
/// ```
library;

export 'src/engine/player_engine.dart'
    show
        EngineDurationChanged,
        EngineEvent,
        EngineItem,
        EngineItemEnded,
        EngineItemFailed,
        EngineItemStarted,
        EngineMediaCommand,
        EngineStateChanged,
        PlayerEngine;
export 'src/engine/session_engine.dart' show SessionEngine;
export 'src/testing/fake_player_engine.dart' show FakePlayerEngine;
export 'src/testing/fake_session_engine.dart' show FakeSessionEngine;
