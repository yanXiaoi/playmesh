# gomobile bindings and JNI entry points are reached from native code.
-keep class go.** { *; }
-keep class mobile.** { *; }

# These capability adapters are initialized by the Runtime host and call JNI.
-keep class org.webrtc.** { *; }
-keep class com.google.ar.core.** { *; }
-keep class top.zfjmm.playmesh_runtime.** { *; }

# Flutter plugins are registered by generated code.
-keep class io.flutter.plugins.** { *; }
