import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// App-wide FlutterSecureStorage instance with proper iOS accessibility.
///
/// Uses [KeychainAccessibility.first_unlock] so the keychain is accessible
/// after the user unlocks the device at least once since boot. The default
/// (kSecAttrAccessibleWhenUnlocked) blocks access when the device is locked,
/// which causes -25308 (errSecInteractionNotAllowed) errors when the app is
/// woken in the background or pre-launched by iOS.
const secureStorage = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
);
