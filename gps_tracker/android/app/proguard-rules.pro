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

# Keep Flutter Activity Recognition (fixes K3.e component error on Android 16)
-keep class com.pravera.flutter_activity_recognition.** { *; }

# Keep WorkManager (watchdog mechanism)
-keep class dev.fluttercommunity.workmanager.** { *; }

# Keep SQLCipher
-keep class net.sqlcipher.** { *; }
-keep class net.sqlcipher.database.** { *; }

# Keep Flutter Secure Storage
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# Keep ML Kit for QR code scanning (Spec 016)
-keep class com.google.mlkit.vision.barcode.** { *; }
-keep class com.google.mlkit.vision.common.** { *; }

# Keep Gson TypeToken and its generic signatures (fixes flutter_local_notifications crash)
# R8 strips generic type info from TypeToken anonymous subclasses, causing:
#   "TypeToken must be created with a type argument: new TypeToken<...>() {}"
# See: https://github.com/google/gson/blob/main/gson/src/main/resources/META-INF/proguard/gson.pro
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# Keep Gson internals used by flutter_local_notifications
-keep class com.google.gson.** { *; }
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# Keep flutter_local_notifications plugin and its models (uses Gson TypeToken generics)
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# Preserve annotations
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keepattributes Signature
-keepattributes Exceptions
-keepattributes InnerClasses
-keepattributes EnclosingMethod
