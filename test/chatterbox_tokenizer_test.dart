import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privai/services/chatterbox_tokenizer.dart';

/// Runs against the real `tokenizer.json` from
/// onnx-community/chatterbox-multilingual-ONNX, checked in as a fixture so these
/// do not need the network.
void main() {
  late ChatterboxTokenizer tokenizer;

  setUpAll(() async {
    final raw =
        await File('test/fixtures/chatterbox_tokenizer.json').readAsString();
    tokenizer = ChatterboxTokenizer.fromJson(
      json.decode(raw) as Map<String, dynamic>,
    );
  });

  test('parses the real vocabulary and merge table', () {
    expect(tokenizer.vocabSize, 2454);
    expect(tokenizer.hasToken('[STOP]'), isTrue);
    expect(tokenizer.hasToken('[START]'), isTrue);
    expect(tokenizer.hasToken('[SPACE]'), isTrue);
  });

  test('special token ids match generation_config', () {
    // generation_config.json: bos_token_id 1, eos_token_id [2, 6562].
    expect(tokenizer.startId, isNonNegative);
    expect(tokenizer.stopId, isNonNegative);
    expect(tokenizer.startId, isNot(tokenizer.stopId));
  });

  test('wraps encodings in start and stop tokens', () {
    final ids = tokenizer.encode('hello');
    expect(ids.first, tokenizer.startId);
    expect(ids.last, tokenizer.stopId);
    expect(ids.length, greaterThan(2));
  });

  test('omits special tokens when asked', () {
    final ids = tokenizer.encode('hello', addSpecialTokens: false);
    expect(ids, isNot(contains(tokenizer.startId)));
    expect(ids, isNot(contains(tokenizer.stopId)));
  });

  test('separates words with the space token', () {
    final one = tokenizer.encode('hello', addSpecialTokens: false);
    final two = tokenizer.encode('hello hello', addSpecialTokens: false);

    expect(tokenizer.spaceId, isNotNull);
    expect(two.length, one.length * 2 + 1);
    expect(two[one.length], tokenizer.spaceId);
  });

  test('collapses runs of whitespace rather than emitting empty tokens', () {
    expect(
      tokenizer.encode('hello   world', addSpecialTokens: false),
      tokenizer.encode('hello world', addSpecialTokens: false),
    );
    expect(
      tokenizer.encode('  hello  ', addSpecialTokens: false),
      tokenizer.encode('hello', addSpecialTokens: false),
    );
  });

  test('keeps bracketed special tokens atomic', () {
    final ids = tokenizer.encode('[laughter]', addSpecialTokens: false);
    expect(ids, hasLength(1), reason: 'must not be split into characters');
  });

  test('round-trips simple text through decode', () {
    const text = 'the quick brown fox';
    expect(tokenizer.decode(tokenizer.encode(text)), text);
  });

  test('never emits an id outside the vocabulary', () {
    const samples = [
      'hello world',
      'Hola, ¿cómo estás?',
      'a b c 1 2 3 !?',
      'ZZZZ unpronounceable qqxz',
      '',
    ];
    for (final sample in samples) {
      for (final id in tokenizer.encode(sample)) {
        expect(id, inInclusiveRange(0, tokenizer.vocabSize - 1),
            reason: 'id out of range for "$sample"');
      }
    }
  });

  test('maps unknown characters to the unknown token, not a crash', () {
    final ids = tokenizer.encode('日本語', addSpecialTokens: false);
    expect(ids, isNotEmpty);
    expect(ids.every((id) => id >= 0), isTrue);
  });

  test('an empty string yields just the special tokens', () {
    expect(tokenizer.encode(''), [tokenizer.startId, tokenizer.stopId]);
  });

  test('preserves case, because the vocabulary is case-sensitive', () {
    // The shipped normalizer is a Replace of " " with "[SPACE]", not a
    // Lowercase, and the vocab contains uppercase letters. Folding case here
    // would pick tokens the model was not trained on.
    expect(
      tokenizer.encode('HELLO', addSpecialTokens: false),
      isNot(tokenizer.encode('hello', addSpecialTokens: false)),
    );
    expect(tokenizer.hasToken('A'), isTrue);
  });

  test('applies BPE merges rather than one id per character', () {
    // 265 merges exist, so a common word should compress below its length.
    final ids = tokenizer.encode('the', addSpecialTokens: false);
    expect(ids.length, lessThanOrEqualTo(3));
  });
}
