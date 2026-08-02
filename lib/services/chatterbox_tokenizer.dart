// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:io';

import 'package:tiktoken/src/common/byte_array.dart';
import 'package:tiktoken/tiktoken.dart';

/// GPT-2 byte-level BPE shared by Chatterbox Nano and Turbo.
///
/// Nano's tokenizer is entirely different from the small word-level BPE used
/// by Chatterbox Multilingual. It also treats performance tags such as
/// `[laugh]` as added special tokens and appends two end-of-text tokens.
class ChatterboxTokenizer {
  ChatterboxTokenizer._(this._encoding, this.endOfTextId, this.vocabSize);

  final Tiktoken _encoding;
  final int endOfTextId;
  final int vocabSize;

  static Future<ChatterboxTokenizer> fromFile(String path) async {
    final json =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    return ChatterboxTokenizer.fromJson(json);
  }

  factory ChatterboxTokenizer.fromJson(Map<String, dynamic> json) {
    final model = json['model'] as Map<String, dynamic>?;
    final vocab = model?['vocab'] as Map<String, dynamic>?;
    if (vocab == null || vocab.isEmpty) {
      throw const FormatException('tokenizer.json has no BPE vocabulary');
    }

    final byteDecoder = _gpt2ByteDecoder();
    final ranks = <ByteArray, int>{};
    for (final entry in vocab.entries) {
      ranks[ByteArray.fromList([
        for (final rune in entry.key.runes) _decodeRune(byteDecoder, rune),
      ])] = (entry.value as num).toInt();
    }

    final specials = <String, int>{};
    for (final token in (json['added_tokens'] as List? ?? const [])) {
      final value = token as Map<String, dynamic>;
      if (value['special'] == true) {
        specials[value['content'] as String] = (value['id'] as num).toInt();
      }
    }
    final eos = specials['<|endoftext|>'];
    if (eos == null) {
      throw const FormatException('tokenizer.json has no end-of-text token');
    }

    return ChatterboxTokenizer._(
      Tiktoken(
        name: 'chatterbox-nano',
        patStr:
            r"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+",
        mergeableRanks: ranks,
        specialTokens: specials,
      ),
      eos,
      vocab.length +
          specials.length -
          (vocab.containsKey('<|endoftext|>') ? 1 : 0),
    );
  }

  /// Matches `AutoTokenizer(text)` used by the Nano reference implementation.
  List<int> encode(String text, {bool addSpecialTokens = true}) {
    final ids = _encoding.encode(
      text,
      allowedSpecial: SpecialTokensSet.custom(_encoding.specialTokensSet),
    );
    return addSpecialTokens ? [...ids, endOfTextId, endOfTextId] : ids;
  }

  static int _decodeRune(Map<int, int> decoder, int rune) {
    final byte = decoder[rune];
    if (byte == null) {
      throw FormatException(
        'Chatterbox tokenizer contains invalid byte rune U+'
        '${rune.toRadixString(16).toUpperCase()}.',
      );
    }
    return byte;
  }

  static Map<int, int> _gpt2ByteDecoder() {
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
    return {for (var i = 0; i < bytes.length; i++) codepoints[i]: bytes[i]};
  }

  @override
  String toString() => 'ChatterboxNanoTokenizer(vocab: $vocabSize)';
}
