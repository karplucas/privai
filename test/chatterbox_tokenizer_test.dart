import 'package:flutter_test/flutter_test.dart';
import 'package:privai/services/chatterbox_tokenizer.dart';

void main() {
  late ChatterboxTokenizer tokenizer;

  setUpAll(() {
    final byteEncoder = _gpt2ByteEncoder();
    tokenizer = ChatterboxTokenizer.fromJson({
      'model': {
        'type': 'BPE',
        'vocab': {
          for (var byte = 0; byte < 256; byte++)
            String.fromCharCode(byteEncoder[byte]!): byte,
          '<|endoftext|>': 50256,
        },
        'merges': <String>[],
      },
      'added_tokens': [
        {
          'id': 50256,
          'content': '<|endoftext|>',
          'special': true,
        },
        {'id': 50275, 'content': '[laugh]', 'special': true},
      ],
    });
  });

  test('uses GPT-2 byte-level tokens and appends two end markers', () {
    final ids = tokenizer.encode('Hi');
    expect(ids.take(2), [72, 105]);
    expect(ids.skip(ids.length - 2), [50256, 50256]);
  });

  test('recognises Nano performance tags as atomic special tokens', () {
    final ids = tokenizer.encode('[laugh] Hi');
    expect(ids.first, 50275);
    expect(ids.where((id) => id == 50275), hasLength(1));
  });

  test('can omit the post-processor end markers', () {
    expect(tokenizer.encode('Hi', addSpecialTokens: false), [72, 105]);
  });
}

Map<int, int> _gpt2ByteEncoder() {
  final bytes = <int>[
    ...List.generate(94, (i) => i + 33),
    ...List.generate(12, (i) => i + 161),
    ...List.generate(82, (i) => i + 174),
  ];
  final codepoints = [...bytes];
  var extra = 0;
  for (var byte = 0; byte < 256; byte++) {
    if (bytes.contains(byte)) continue;
    bytes.add(byte);
    codepoints.add(256 + extra++);
  }
  return {for (var i = 0; i < bytes.length; i++) bytes[i]: codepoints[i]};
}
