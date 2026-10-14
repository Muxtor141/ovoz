package uz.sayma.ovoz

import io.flutter.embedding.engine.plugins.FlutterPlugin
import uz.sayma.ovoz.engine.Ovoz

/**
 * Registers no method channel: Dart talks to the engine through jnigen
 * bindings.
 *
 * The class exists for what only Flutter can provide: the application
 * context, the lookup of Flutter's assets, and when the engine goes away.
 * This is the only file that knows Flutter.
 */
class OvozPlugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    Ovoz.attach(binding.applicationContext, binding.flutterAssets)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    Ovoz.detach()
  }
}
