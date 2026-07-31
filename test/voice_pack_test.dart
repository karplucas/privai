import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privai/services/voice_pack_service.dart';

/// Builds a little-endian float32 buffer of [rows] x 256, where every value is
/// derived from its position so it can be checked exactly.
Uint8List buildVoiceBin(int rows) {
  const width = VoicePackService.vectorWidth;
  final floats = Float32List(rows * width);
  for (var row = 0; row < rows; row++) {
    for (var col = 0; col < width; col++) {
      floats[row * width + col] = (row * width + col) / 1000.0;
    }
  }
  return floats.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _assetContractTests();

  group('decodeStyleVectors', () {
    test('produces the [rows][1][256] shape the TTS package expects', () {
      final decoded = VoicePackService.decodeStyleVectors(buildVoiceBin(510));

      expect(decoded, hasLength(510));
      expect(decoded.first, hasLength(1),
          reason: 'each vector is wrapped in a single-element list');
      expect(decoded.first.first, hasLength(VoicePackService.vectorWidth));
    });

    test('preserves float values exactly', () {
      final decoded = VoicePackService.decodeStyleVectors(buildVoiceBin(4));

      for (var row = 0; row < 4; row++) {
        for (var col = 0; col < VoicePackService.vectorWidth; col++) {
          final expected =
              ((row * VoicePackService.vectorWidth + col) / 1000.0);
          expect(
            decoded[row][0][col],
            closeTo(expected, 1e-6),
            reason: 'value at [$row][$col] must survive the round trip',
          );
        }
      }
    });

    test('handles the real 510-row and 512-row layouts both published on the '
        'Hub', () {
      // af_heart.bin is 510 rows; af.bin is padded to 512. The package clamps
      // its lookup to the table length, so both are usable.
      expect(VoicePackService.decodeStyleVectors(buildVoiceBin(510)),
          hasLength(510));
      expect(VoicePackService.decodeStyleVectors(buildVoiceBin(512)),
          hasLength(512));
    });

    test('ignores a trailing partial vector rather than emitting a short row',
        () {
      final full = buildVoiceBin(3);
      final truncated = Uint8List.fromList(
        full.sublist(0, full.length - (VoicePackService.vectorWidth * 4) ~/ 2),
      );

      final decoded = VoicePackService.decodeStyleVectors(truncated);

      expect(decoded, hasLength(2));
      for (final row in decoded) {
        expect(row.first, hasLength(VoicePackService.vectorWidth));
      }
    });

    test('returns empty for data too small to hold one vector', () {
      expect(VoicePackService.decodeStyleVectors(Uint8List(16)), isEmpty);
      expect(VoicePackService.decodeStyleVectors(Uint8List(0)), isEmpty);
    });

    test('decodes from an unaligned buffer', () {
      // File reads can return a view whose byte offset is not a multiple of 4;
      // Float32List.view would throw on that.
      final source = buildVoiceBin(2);
      final padded = Uint8List(source.length + 1)..setRange(1, source.length + 1, source);
      final unaligned = Uint8List.sublistView(padded, 1);

      expect(
        () => VoicePackService.decodeStyleVectors(unaligned),
        returnsNormally,
      );
      expect(VoicePackService.decodeStyleVectors(unaligned), hasLength(2));
    });
  });

  group('voice catalogue', () {
    test('the default voices are ones the Hub repository publishes', () {
      for (final voice in VoicePackService.defaultVoices) {
        expect(VoicePackService.knownVoices, contains(voice));
      }
    });

    test('voice ids are unique', () {
      expect(
        VoicePackService.knownVoices.toSet(),
        hasLength(VoicePackService.knownVoices.length),
      );
    });
  });
}

/// Guards the assets the TTS stack reads through `rootBundle`.
///
/// Regression: `assets/us_gold.json` and `assets/us_silver.json` were removed
/// from the app on the incorrect belief that `malsami` served them from its own
/// package namespace. It declares them there, but `Lexicon` reads them from the
/// application's root asset namespace, so speech died with
/// `Unable to load asset: "assets/us_gold.json"`. They are now aliased onto the
/// package copies; these tests fail if those move.
void _assetContractTests() {
  group('TTS asset contract', () {
    test('malsami ships the lexicon files the alias points at', () async {
      for (final key in const [
        'packages/malsami/assets/us_gold.json',
        'packages/malsami/assets/us_silver.json',
        'packages/malsami/assets/gb_gold.json',
        'packages/malsami/assets/gb_silver.json',
      ]) {
        expect(
          () async => rootBundle.loadString(key),
          returnsNormally,
          reason: '$key must exist for the alias to resolve',
        );
        expect((await rootBundle.loadString(key)).isNotEmpty, isTrue);
      }
    });

    test('the app itself ships the two small asset-only files', () async {
      for (final key in const [
        'assets/tokenizer_vocab.json',
        'assets/lexicon.json',
      ]) {
        expect((await rootBundle.loadString(key)).isNotEmpty, isTrue,
            reason: '$key is read via rootBundle and cannot be downloaded');
      }
    });
  });
}
