import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Makes files on disk visible to [rootBundle].
///
/// Some packages read their data through `rootBundle` and offer no way to point
/// them at a filesystem path — `kokoro_tts_flutter` loads its 52 MB voice table
/// that way. `rootBundle` itself is `final` and cannot be replaced, but
/// [PlatformAssetBundle.load] fetches bytes by sending the asset key over the
/// `flutter/assets` platform channel, and [ServicesBinding.createBinaryMessenger]
/// is `@protected` and therefore overridable in production. Intercepting that
/// one channel lets a downloaded file stand in for a bundled asset.
///
/// The interception is deliberately narrow: anything that is not the
/// `flutter/assets` channel, and any asset key without a registered override, is
/// passed straight through to the real messenger untouched.
class AssetOverrideBinding extends WidgetsFlutterBinding {
  static final Map<String, String> _overrides = <String, String>{};

  /// The binding this class installed, if it was the one to install it.
  ///
  /// Tracked separately because [WidgetsBinding.instance] *throws* when no
  /// binding exists yet, so it cannot be used to test whether one does.
  static AssetOverrideBinding? _binding;

  AssetOverrideBinding() {
    _binding = this;
  }

  /// Installs this binding. Call instead of
  /// `WidgetsFlutterBinding.ensureInitialized()`, as the first line of `main`.
  static WidgetsBinding ensureInitialized() {
    final existing = _binding;
    if (existing != null) return existing;

    // Something may have installed a binding already — flutter_test does so
    // before any test runs. Constructing a second one trips BindingBase's
    // "Binding is already initialized" assertion, so defer to it. This only
    // reports a type in debug builds, which is exactly where test bindings
    // live; in a release app it is null and the branch below runs, as intended.
    if (BindingBase.debugBindingType() != null) {
      return WidgetsBinding.instance;
    }

    // Constructing the binding is what registers it. Only afterwards is
    // WidgetsBinding.instance safe to read.
    AssetOverrideBinding();
    return WidgetsBinding.instance;
  }

  /// Serves [filePath] whenever [assetKey] is requested from the asset bundle.
  ///
  /// Evicts any cached copy so a later override replaces an earlier one —
  /// [CachingAssetBundle] would otherwise hold the first result forever.
  static void registerOverride(String assetKey, String filePath) {
    _overrides[assetKey] = filePath;
    rootBundle.evict(assetKey);
    debugPrint('AssetOverrideBinding: $assetKey -> $filePath');
  }

  static void removeOverride(String assetKey) {
    if (_overrides.remove(assetKey) != null) rootBundle.evict(assetKey);
  }

  static bool hasOverride(String assetKey) => _overrides.containsKey(assetKey);

  static bool hasAlias(String assetKey) => _aliases.containsKey(assetKey);

  /// Maps one asset key onto another that is already in the bundle.
  ///
  /// Used for packages that ship data under their own `packages/<name>/…`
  /// prefix but then read it from the application's root asset namespace. The
  /// bytes are already in the build, so aliasing costs nothing, where copying
  /// the files into `assets/` would duplicate them.
  static void registerAlias(String assetKey, String targetAssetKey) {
    _aliases[assetKey] = targetAssetKey;
    rootBundle.evict(assetKey);
    debugPrint('AssetOverrideBinding: $assetKey => $targetAssetKey (alias)');
  }

  static final Map<String, String> _aliases = <String, String>{};

  @override
  BinaryMessenger createBinaryMessenger() =>
      _AssetOverridingBinaryMessenger(super.createBinaryMessenger());
}

/// Delegating messenger that answers `flutter/assets` requests for overridden
/// keys from disk.
class _AssetOverridingBinaryMessenger implements BinaryMessenger {
  _AssetOverridingBinaryMessenger(this._inner);

  final BinaryMessenger _inner;

  static const String _assetChannel = 'flutter/assets';

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    if (channel != _assetChannel || message == null) {
      return _inner.send(channel, message);
    }

    final String key;
    try {
      key = Uri.decodeFull(utf8.decode(message.buffer
          .asUint8List(message.offsetInBytes, message.lengthInBytes)));
    } catch (_) {
      // Not a key we can read; let the platform deal with it.
      return _inner.send(channel, message);
    }

    final path = AssetOverrideBinding._overrides[key];
    if (path != null) return _readOrFallThrough(path, channel, message);

    final alias = AssetOverrideBinding._aliases[key];
    if (alias != null) return _inner.send(channel, _encodeAssetKey(alias));

    return _inner.send(channel, message);
  }

  /// Encodes an asset key the same way [PlatformAssetBundle.load] does, so the
  /// platform side sees a request indistinguishable from a direct one.
  static ByteData _encodeAssetKey(String key) => ByteData.sublistView(
        utf8.encode(Uri(path: Uri.encodeFull(key)).path),
      );

  Future<ByteData?>? _readOrFallThrough(
    String path,
    String channel,
    ByteData message,
  ) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        return ByteData.sublistView(await file.readAsBytes());
      }
      debugPrint('AssetOverrideBinding: override file missing at $path');
    } catch (e) {
      debugPrint('AssetOverrideBinding: could not read $path: $e');
    }
    // Fall back to the real bundle so a broken override degrades to whatever
    // was compiled in rather than failing outright.
    return _inner.send(channel, message);
  }

  // Required by the BinaryMessenger interface; deprecated upstream but still
  // part of the contract this class has to satisfy in order to delegate.
  @Deprecated('Kept only to satisfy BinaryMessenger; delegates to the real one.')
  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    PlatformMessageResponseCallback? callback,
  ) =>
      _inner.handlePlatformMessage(channel, data, callback);

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      _inner.setMessageHandler(channel, handler);
}
