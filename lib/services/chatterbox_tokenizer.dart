import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Byte-pair tokenizer for Chatterbox, reading Hugging Face `tokenizer.json`.
///
/// Small enough to implement directly: 2,454 vocabulary entries and 265 merges,
/// with a whitespace pre-tokenizer. That is a long way from a general port of
/// `tokenizers`, and only the subset this model actually uses is supported —
/// lowercasing, whitespace splitting, greedy BPE, and the `[…]` special tokens.
class ChatterboxTokenizer {
  ChatterboxTokenizer._({
    required Map<String, int> vocab,
    required Map<String, int> mergeRanks,
    required this.unknownId,
    required this.startId,
    required this.stopId,
    required this.spaceId,
    required bool lowercase,
  })  : _vocab = vocab,
        _mergeRanks = mergeRanks,
        _lowercase = lowercase;

  final Map<String, int> _vocab;

  /// `"a b" -> rank`; a lower rank is merged first.
  final Map<String, int> _mergeRanks;

  final bool _lowercase;

  final int unknownId;
  final int startId;
  final int stopId;

  /// Token standing in for a space between words, when the vocabulary has one.
  final int? spaceId;

  int get vocabSize => _vocab.length;

  static const String _unknown = '[UNK]';
  static const String _start = '[START]';
  static const String _stop = '[STOP]';
  static const String _space = '[SPACE]';

  /// Parses a `tokenizer.json`.
  factory ChatterboxTokenizer.fromJson(Map<String, dynamic> json) {
    final model = json['model'] as Map<String, dynamic>?;
    if (model == null) {
      throw const FormatException('tokenizer.json has no "model" section');
    }

    final vocab = <String, int>{};
    (model['vocab'] as Map<String, dynamic>? ?? {}).forEach((token, id) {
      vocab[token] = (id as num).toInt();
    });
    if (vocab.isEmpty) {
      throw const FormatException('tokenizer.json has an empty vocabulary');
    }

    // Merges are either "a b" strings or ["a", "b"] pairs depending on the
    // version that produced the file.
    final mergeRanks = <String, int>{};
    final merges = model['merges'] as List? ?? const [];
    for (var rank = 0; rank < merges.length; rank++) {
      final entry = merges[rank];
      final String key;
      if (entry is String) {
        key = entry;
      } else if (entry is List && entry.length == 2) {
        key = '${entry[0]} ${entry[1]}';
      } else {
        continue;
      }
      mergeRanks[key] = rank;
    }

    // Case is significant: this vocabulary contains uppercase letters, and the
    // shipped normalizer is a Replace of " " with "[SPACE]" — not a Lowercase.
    // Folding case here would silently pick different tokens than the model was
    // trained on. Only fold if the file actually asks for it.
    final lowercase = _declaresLowercase(json['normalizer']);

    return ChatterboxTokenizer._(
      vocab: vocab,
      mergeRanks: mergeRanks,
      unknownId: vocab[_unknown] ?? 1,
      startId: vocab[_start] ?? 1,
      stopId: vocab[_stop] ?? 0,
      spaceId: vocab[_space],
      lowercase: lowercase,
    );
  }

  /// Walks a normalizer definition, which may be a single entry or a Sequence,
  /// looking for a Lowercase step.
  static bool _declaresLowercase(Object? normalizer) {
    if (normalizer is! Map<String, dynamic>) return false;
    if (normalizer['type'] == 'Lowercase') return true;
    final nested = normalizer['normalizers'];
    if (nested is List) return nested.any(_declaresLowercase);
    return false;
  }

  static Future<ChatterboxTokenizer> fromFile(String path) async {
    final raw = await File(path).readAsString();
    return ChatterboxTokenizer.fromJson(
      json.decode(raw) as Map<String, dynamic>,
    );
  }

  /// Encodes [text], wrapped in the start/stop tokens the model expects.
  List<int> encode(String text, {bool addSpecialTokens = true}) {
    final ids = <int>[if (addSpecialTokens) startId];

    final words = _preTokenize(text);
    for (var i = 0; i < words.length; i++) {
      if (i > 0 && spaceId != null) ids.add(spaceId!);
      ids.addAll(_encodeWord(words[i]));
    }

    if (addSpecialTokens) ids.add(stopId);
    return ids;
  }

  /// Splits on whitespace, keeping any `[bracketed]` special token whole.
  List<String> _preTokenize(String text) {
    final normalized = _lowercase ? text.toLowerCase() : text;
    final out = <String>[];
    final pattern = RegExp(r'\[[a-zA-Z_]+\]|\S+');
    for (final match in pattern.allMatches(normalized)) {
      final piece = match.group(0)!;
      out.add(piece);
    }
    return out;
  }

  /// Greedy BPE over one whitespace-delimited chunk.
  List<int> _encodeWord(String word) {
    // Special tokens are atomic; casing is preserved for them.
    final special = _vocab[word] ?? _vocab[word.toUpperCase()];
    if (word.startsWith('[') && word.endsWith(']') && special != null) {
      return [special];
    }

    var symbols = word.split('');
    if (symbols.isEmpty) return const [];

    while (symbols.length > 1) {
      var bestRank = 1 << 30;
      var bestIndex = -1;
      for (var i = 0; i < symbols.length - 1; i++) {
        final rank = _mergeRanks['${symbols[i]} ${symbols[i + 1]}'];
        if (rank != null && rank < bestRank) {
          bestRank = rank;
          bestIndex = i;
        }
      }
      if (bestIndex == -1) break;
      symbols = [
        ...symbols.take(bestIndex),
        symbols[bestIndex] + symbols[bestIndex + 1],
        ...symbols.skip(bestIndex + 2),
      ];
    }

    return [
      for (final symbol in symbols) _vocab[symbol] ?? unknownId,
    ];
  }

  /// Reverse lookup, for debugging generated sequences.
  String decode(List<int> ids) {
    final reverse = {for (final e in _vocab.entries) e.value: e.key};
    final buffer = StringBuffer();
    for (final id in ids) {
      final token = reverse[id];
      if (token == null || token == _start || token == _stop) continue;
      buffer.write(token == _space ? ' ' : token);
    }
    return buffer.toString();
  }

  @override
  String toString() =>
      'ChatterboxTokenizer(vocab: ${_vocab.length}, merges: ${_mergeRanks.length})';

  @visibleForTesting
  bool hasToken(String token) => _vocab.containsKey(token);
}
