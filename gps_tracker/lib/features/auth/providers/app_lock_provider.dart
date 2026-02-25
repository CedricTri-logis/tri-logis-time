import 'package:flutter_riverpod/flutter_riverpod.dart';

/// In-memory lock state for the "app lock" pattern.
///
/// When biometric is enabled, "sign out" locks the app instead of calling
/// Supabase signOut() (which revokes the refresh token). Face ID then
/// simply clears this flag to "unlock" — no network call needed.
///
/// Not persisted: if the app is killed while locked, the Supabase SDK
/// restores the session normally on next launch → straight to HomeScreen.
final appLockProvider = StateProvider<bool>((ref) => false);
