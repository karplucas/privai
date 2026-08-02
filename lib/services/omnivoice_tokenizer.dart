// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:io';

import 'package:tiktoken/src/common/byte_array.dart';
import 'package:tiktoken/tiktoken.dart';

/// Loads OmniVoice's Qwen byte-level BPE directly from tokenizer.json.
class OmniVoiceTokenizer {
  OmniVoiceTokenizer._(this._encoding);

  final Tiktoken _encoding;

  static Future<OmniVoiceTokenizer> fromFile(String path) async {
    final json =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    final model = json['model'] as Map<String, dynamic>;
    final vocab = model['vocab'] as Map<String, dynamic>;
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

    return OmniVoiceTokenizer._(Tiktoken(
      name: 'omnivoice-qwen',
      patStr:
          r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+",
      mergeableRanks: ranks,
      specialTokens: specials,
    ));
  }

  /// Encodes model prompts, including OmniVoice's control tokens such as
  /// `<|text_start|>`. Treating those strings as ordinary punctuation changes
  /// the conditioning sequence completely and produces non-speech codec data.
  List<int> encode(String text) => _encoding.encode(
        text,
        allowedSpecial: SpecialTokensSet.custom(_encoding.specialTokensSet),
      );

  static int _decodeRune(Map<int, int> decoder, int rune) {
    final byte = decoder[rune];
    if (byte == null) {
      throw FormatException(
        'OmniVoice tokenizer vocabulary contains an invalid byte rune U+'
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
}
