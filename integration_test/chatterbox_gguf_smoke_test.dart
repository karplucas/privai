import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:privai/services/chatterbox_gguf_bindings.dart';

/// Proves the native GGUF library is linked into the app and reachable.
///
/// The iOS build of this backend had never been compiled before, let alone
/// loaded, so this asserts the part that is easy to get wrong and impossible to
/// see from a successful build: that `DynamicLibrary.process()` finds the FFI
/// symbols, which only holds if the framework is embedded *and* linked into the
/// app binary rather than lazily loaded. No model is needed.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the native library loads and answers', (tester) async {
    final native = ChatterboxNative.open();
    final version = native.version;

    // ignore: avoid_print
    print('CHATTERBOX_NATIVE_VERSION $version');
    expect(version, isNotEmpty);
  });
}
