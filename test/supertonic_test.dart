import 'package:flutter_test/flutter_test.dart';
import 'package:privai/services/supertonic_tts_service.dart';

void main() {
  group('language mapping', () {
    test('folds the app\'s regional codes onto Supertonic\'s', () {
      expect(SupertonicTtsService.languageFor('en-us'), 'en');
      expect(SupertonicTtsService.languageFor('en-gb'), 'en');
      expect(SupertonicTtsService.languageFor('pt-br'), 'pt');
      expect(SupertonicTtsService.languageFor('es-419'), 'es');
      expect(SupertonicTtsService.languageFor('ja'), 'ja');
      expect(SupertonicTtsService.languageFor('pl'), 'pl');
    });

    test('refuses Chinese rather than speaking it in another language', () {
      // Supertonic 3 covers 31 languages and Chinese is not among them. The
      // catalog offers `cmn`, so this has to fail where it can be explained.
      expect(
        () => SupertonicTtsService.languageFor('cmn'),
        throwsA(isA<SupertonicUnavailableException>()),
      );
      expect(
        () => SupertonicTtsService.languageFor('cmn'),
        throwsA(predicate((e) => e.toString().contains('Kokoro'))),
      );
    });

    test('defaults to English when nothing is configured', () {
      expect(SupertonicTtsService.languageFor(null), 'en');
    });
  });

  group('character encoding', () {
    // A lookup table indexed by code point, as the bundle ships it. -1 marks a
    // character the model has no id for.
    final indexer = List<int>.filled(128, -1);
    for (final entry in {'<': 2, '>': 3, '/': 4, 'e': 5, 'n': 6, 'h': 7, 'i': 8}
        .entries) {
      indexer[entry.key.codeUnitAt(0)] = entry.value;
    }

    test('wraps the text in the language tag the model was trained on', () {
      // "<en>hi</en>" — the tags are part of the input, not metadata.
      expect(
        SupertonicTtsService.encode('hi', 'en', indexer),
        [2, 5, 6, 3, 7, 8, 2, 4, 5, 6, 3],
      );
    });

    test('folds unknown characters to zero rather than dropping them', () {
      // Dropping would shift every following character against the durations
      // the predictor produced for them.
      final ids = SupertonicTtsService.encode('h?i', 'en', indexer);
      expect(ids.length, 12);
      expect(ids[5], 0);
    });
  });
}
