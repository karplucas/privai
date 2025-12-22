# 1. Google Play Core (Split Install / Deferred Components)
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.splitcompat.** { *; }
-keep class com.google.android.play.core.splitinstall.** { *; }
-keep class com.google.android.play.core.tasks.** { *; }

# 2. MediaPipe & Protobuf (Fixes the CalculatorProfile errors)
-dontwarn com.google.mediapipe.**
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }

# 3. Suppress general warnings for referenced missing classes
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

# 4. Keep shared_preferences pigeon classes for release
-keep class dev.flutter.pigeon.shared_preferences_android.** { *; }
-keep class **pigeon** { *; }