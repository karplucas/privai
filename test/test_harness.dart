import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the platform plugins the app talks to, so widget tests can
/// render the real screens without a device.
///
/// Without this every `pumpWidget` throws `MissingPluginException` from
/// flutter_secure_storage and path_provider before the first frame settles.
class FakePlatform {
  FakePlatform._(this.tempDir);

  final Directory tempDir;
  final Map<String, String> secureStorage = {};

  static const _secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  static const _pathProviderChannel =
      MethodChannel('plugins.flutter.io/path_provider');
  static const _permissionsChannel =
      MethodChannel('flutter.baseflow.com/permissions/methods');

  /// Installs the fakes and registers teardown. Call from `setUp`.
  static FakePlatform install({Map<String, String>? initialSettings}) {
    TestWidgetsFlutterBinding.ensureInitialized();

    final tempDir = Directory.systemTemp.createTempSync('privai_test_');
    final platform = FakePlatform._(tempDir);
    if (initialSettings != null) {
      platform.secureStorage.addAll(initialSettings);
    }

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(_secureStorageChannel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return platform.secureStorage[key];
        case 'readAll':
          return Map<String, String>.from(platform.secureStorage);
        case 'write':
          platform.secureStorage[key!] = args['value'] as String;
          return null;
        case 'delete':
          platform.secureStorage.remove(key);
          return null;
        case 'deleteAll':
          platform.secureStorage.clear();
          return null;
        case 'containsKey':
          return platform.secureStorage.containsKey(key);
        default:
          return null;
      }
    });

    messenger.setMockMethodCallHandler(_pathProviderChannel, (call) async {
      switch (call.method) {
        case 'getTemporaryDirectory':
        case 'getApplicationSupportDirectory':
        case 'getApplicationDocumentsDirectory':
          return tempDir.path;
        case 'getExternalStorageDirectory':
          return tempDir.path;
        case 'getExternalStorageDirectories':
          return <String>[tempDir.path];
        default:
          return tempDir.path;
      }
    });

    // Report every permission as granted so the chat screen's start-up does not
    // stall waiting on a dialog that cannot appear.
    messenger.setMockMethodCallHandler(_permissionsChannel, (call) async {
      switch (call.method) {
        case 'checkPermissionStatus':
          return 1; // granted
        case 'requestPermissions':
          return <int, int>{if (call.arguments is List) ...{}};
        default:
          return 1;
      }
    });

    addTearDown(() {
      messenger.setMockMethodCallHandler(_secureStorageChannel, null);
      messenger.setMockMethodCallHandler(_pathProviderChannel, null);
      messenger.setMockMethodCallHandler(_permissionsChannel, null);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    return platform;
  }

  /// Convenience for asserting on what the app persisted.
  Map<String, dynamic>? decodeJson(String key) {
    final raw = secureStorage[key];
    return raw == null ? null : json.decode(raw) as Map<String, dynamic>;
  }
}
