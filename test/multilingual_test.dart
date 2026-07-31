import 'package:flutter_test/flutter_test.dart';
import 'package:privai/services/app_settings.dart';
import 'package:privai/services/model_catalog.dart';

import 'test_harness.dart';

/// Tests over the language tables the app actually ships and reads.
///
/// The previous version of this file declared literal maps and then asserted
/// that those same literals held the values just written into them, so it could
/// not fail regardless of what the app did. Everything here reads
/// `assets/models_list.json` and the settings store.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ModelCatalogData catalog;

  setUpAll(() async {
    ModelCatalog().invalidate();
    catalog = await ModelCatalog().load();
  });

  group('Speech-to-text languages', () {
    test('offers auto-detect plus a broad language set', () {
      final codes = catalog.sttLanguages.map((l) => l.code).toList();

      expect(codes, contains('auto'));
      expect(codes.length, greaterThan(50));
    });

    test('covers the widely used languages Whisper supports', () {
      final codes = catalog.sttLanguages.map((l) => l.code).toSet();

      for (final code in [
        'en', 'es', 'fr', 'de', 'it', 'pt', 'ru', 'ja', 'zh', 'ko', 'ar', 'hi',
      ]) {
        expect(codes, contains(code), reason: '$code should be selectable');
      }
    });

    test('every code is a valid ISO-639 style tag', () {
      for (final language in catalog.sttLanguages) {
        if (language.code == 'auto') continue;
        expect(
          language.code,
          matches(r'^[a-z]{2,3}$'),
          reason: '${language.code} is not a plain language code',
        );
      }
    });

    test('names and codes are unique', () {
      final codes = catalog.sttLanguages.map((l) => l.code).toList();
      expect(codes.toSet(), hasLength(codes.length));

      for (final language in catalog.sttLanguages) {
        expect(language.name, isNotEmpty);
      }
    });

    test('the default STT language is one of the offered options', () {
      final codes = catalog.sttLanguages.map((l) => l.code).toSet();
      expect(codes, contains(AppSettings.defaultSttLanguage));
    });
  });

  group('Text-to-speech languages', () {
    test('offers the locales Kokoro is trained on', () {
      final codes = catalog.ttsLanguages.map((l) => l.code).toSet();

      expect(codes, contains('en-us'));
      expect(codes.length, greaterThan(4));
    });

    test('every code is a language or language-region tag', () {
      for (final language in catalog.ttsLanguages) {
        expect(
          language.code,
          matches(r'^[a-z]{2,3}(-[a-z0-9]{2,3})?$'),
          reason: '${language.code} is not a usable locale tag',
        );
      }
    });

    test('codes are unique and every entry is labelled', () {
      final codes = catalog.ttsLanguages.map((l) => l.code).toList();
      expect(codes.toSet(), hasLength(codes.length));

      for (final language in catalog.ttsLanguages) {
        expect(language.name, isNotEmpty);
      }
    });

    test('the default TTS language is one of the offered options', () {
      final codes = catalog.ttsLanguages.map((l) => l.code).toSet();
      expect(codes, contains(AppSettings.defaultTtsLanguage));
    });
  });

  group('Language settings', () {
    setUp(FakePlatform.install);

    test('language choices round-trip through storage', () async {
      final settings = AppSettings();

      expect(await settings.sttLanguage, AppSettings.defaultSttLanguage);
      expect(await settings.ttsLanguage, AppSettings.defaultTtsLanguage);

      await settings.setSttLanguage('ja');
      await settings.setTtsLanguage('pt-br');

      expect(await settings.sttLanguage, 'ja');
      expect(await settings.ttsLanguage, 'pt-br');
    });

    test('a stored language survives being re-read by another instance',
        () async {
      await AppSettings().setSttLanguage('de');
      expect(await AppSettings().sttLanguage, 'de');
    });
  });
}
