# Testing

```bash
flutter test                    # unit and widget tests
flutter test --coverage
flutter test integration_test/  # needs a connected device or emulator
```

## What is covered

| File | Covers |
| --- | --- |
| `test/model_catalog_test.dart` | Catalog parsing, gating metadata, URL derivation — including that every Gemma entry is marked gated, and that a model's license page and download URL resolve to the same repository |
| `test/unit_test.dart` | Settings defaults and clamping, model storage paths, conversation parsing and persistence, migration of history out of secure storage |
| `test/multilingual_test.dart` | The TTS/STT language tables the app ships, and that the stored defaults are options the UI actually offers |
| `test/widget_test.dart` | The chat screen shell: title, composer, empty state, drawer, and that sending without a loaded model warns instead of failing silently |
| `integration_test/app_test.dart` | Start-up, navigation, layout under resize, and that no gated model offers a download button while signed out |

`test/test_harness.dart` provides `FakePlatform`, which mocks the
flutter_secure_storage, path_provider and permission_handler method channels so
widget tests can render the real screens. Without it every `pumpWidget` throws
`MissingPluginException` before the first frame settles.

## What is deliberately not covered

**Model output.** A test run has no model weights — the Gemma files are several
gigabytes and sit behind an accepted license. A test that claimed to send a
message and receive a reply would be asserting on a stub rather than on the app.
The suite asserts the surrounding behaviour instead: that a message is rejected
with a visible explanation when no model is loaded.

**Live Hugging Face calls.** Access checks and downloads hit the network and
depend on which licenses the signed-in account has accepted. These are exercised
by hand against a real account.

There is no mocking framework in use. An earlier version of this document
described mocks for `WhisperController`, `AudioPlayer`, `SherpaOnnxOfflineTts`
and `AudioRecorder`; none existed, and `sherpa_onnx` is not a dependency of this
project.

## Notes

- `pumpAndSettle` never returns while a `CircularProgressIndicator` is on
  screen, because it animates indefinitely. Use fixed `pump(Duration(...))`
  calls around the drawer and any loading state.
- Timeouts come from `dart_test.yaml`. The old `flutter_test_config.yaml` was
  never read by any tool — Flutter looks for `dart_test.yaml` for configuration
  or `flutter_test_config.dart` for a Dart setup hook.
