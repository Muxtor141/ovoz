# Dart reaches these classes through JNI only (jnigen bindings), so nothing in
# the app's code refers to them: keep their names and members.
-keep class uz.sayma.ovoz.OvozPlayer { public *; }
-keep class uz.sayma.ovoz.OvozItem { public *; }
-keep class uz.sayma.ovoz.OvozSession { public *; }
-keep interface uz.sayma.ovoz.OvozPlayerListener { *; }
-keep interface uz.sayma.ovoz.OvozSessionListener { *; }
