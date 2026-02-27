# Flutter wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Play Core library (deferred components)
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task

# Keep Supabase/GoTrue classes
-keep class io.supabase.** { *; }
-keep class com.google.crypto.tink.** { *; }

# Keep Google Maps classes
-keep class com.google.android.gms.maps.** { *; }

# Keep Geolocator
-keep class com.baseflow.geolocator.** { *; }

# Keep Flutter Foreground Task
-keep class com.pravera.flutter_foreground_task.** { *; }

# Keep Disable Battery Optimization (fixes K3.e component error on Samsung)
-keep class in.jvapps.disable_battery_optimization.** { *; }

# Keep Android Alarm Manager (watchdog primary mechanism)
-keep class dev.fluttercommunity.plus.androidalarmmanager.** { *; }

# Keep WorkManager (watchdog backup mechanism)
-keep class dev.fluttercommunity.workmanager.** { *; }

# Keep SQLCipher
-keep class net.sqlcipher.** { *; }
-keep class net.sqlcipher.database.** { *; }

# Keep Flutter Secure Storage
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# Keep ML Kit for QR code scanning (Spec 016)
-keep class com.google.mlkit.vision.barcode.** { *; }
-keep class com.google.mlkit.vision.common.** { *; }

# Preserve annotations
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keepattributes Signature
-keepattributes Exceptions
