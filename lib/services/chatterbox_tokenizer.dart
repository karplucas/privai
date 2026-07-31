import 'dart:convert';
import 'dart:io';

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
    required this.exaggerationId,
    required this.startSpeechId,
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

  /// Opens every encoding; the embedding graph reads the `exaggeration` input
  /// at this position.
  final int? exaggerationId;

  /// Closes every encoding, twice, and hands the language model over to speech
  /// generation. Ids at or above it are speech tokens, which is also how the
  /// reference implementation decides a position id is 0.
  final int? startSpeechId;

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

    // The post-processor, not the vocabulary, defines what wraps an encoding:
    // `<EXAGGERATION> <s> …text… </s> <START_SPEECH> <START_SPEECH>`. The two
    // outer ids are not in the vocabulary at all — they address the language
    // model's speech range — so they can only be read from here.
    final template = _templateTokens(json['post_processor']);

    return ChatterboxTokenizer._(
      vocab: vocab,
      mergeRanks: mergeRanks,
      unknownId: vocab[_unknown] ?? 1,
      startId: template['BOS'] ?? vocab[_start] ?? 1,
      stopId: template['EOS'] ?? vocab[_stop] ?? 0,
      exaggerationId: template['EXAGGERATION'],
      startSpeechId: template['START_SPEECH'],
      spaceId: vocab[_space],
      lowercase: lowercase,
    );
  }

  /// `{name: id}` from the post-processor's special-token table.
  static Map<String, int> _templateTokens(Object? postProcessor) {
    final out = <String, int>{};
    if (postProcessor is! Map<String, dynamic>) return out;
    final specials = postProcessor['special_tokens'];
    if (specials is! Map<String, dynamic>) return out;

    specials.forEach((name, entry) {
      if (entry is! Map<String, dynamic>) return;
      final ids = entry['ids'];
      if (ids is List && ids.isNotEmpty && ids.first is num) {
        out[name] = (ids.first as num).toInt();
      }
    });
    return out;
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

  /// Encodes [text] as the model's post-processor template does:
  /// `<EXAGGERATION> <s> …text… </s> <START_SPEECH> <START_SPEECH>`.
  ///
  /// The trailing pair is what puts the language model into speech generation.
  /// Emitting only `[START]`/`[STOP]` — as this did — leaves it continuing text
  /// instead, which decodes to a drone that never reaches end-of-speech.
  List<int> encode(String text, {bool addSpecialTokens = true}) {
    final ids = <int>[];
    if (addSpecialTokens) {
      if (exaggerationId != null) ids.add(exaggerationId!);
      ids.add(startId);
    }

    ids.addAll(_encodeBody(text));

    if (addSpecialTokens) {
      ids.add(stopId);
      if (startSpeechId != null) ids.addAll([startSpeechId!, startSpeechId!]);
    }
    return ids;
  }

  /// Everything between the template's special tokens.
  ///
  /// Mirrors the shipped pipeline: the normalizer replaces each literal space
  /// with `[SPACE]`, then a Whitespace pre-tokenizer splits words from runs of
  /// punctuation, and BPE runs over each piece. Spaces are *not* collapsed —
  /// three spaces are three `[SPACE]` tokens.
  List<int> _encodeBody(String text) {
    final normalized = _lowercase ? text.toLowerCase() : text;
    final ids = <int>[];

    for (final match in _pieces.allMatches(normalized)) {
      final piece = match.group(0)!;
      if (piece == ' ') {
        if (spaceId != null) ids.add(spaceId!);
      } else if (_vocab.containsKey(piece)) {
        // A `[bracketed]` token that really is in the vocabulary is atomic.
        ids.add(_vocab[piece]!);
      } else if (piece.startsWith('[') && piece.endsWith(']')) {
        // Brackets around something unrecognised are just punctuation.
        ids.addAll(_encodeChunk('['));
        ids.addAll(_encodeChunk(piece.substring(1, piece.length - 1)));
        ids.addAll(_encodeChunk(']'));
      } else {
        ids.addAll(_encodeChunk(piece));
      }
    }
    return ids;
  }

  /// Bracketed specials, single spaces, word runs, punctuation runs. Other
  /// whitespace matches nothing and drops out, as it does upstream.
  static final RegExp _pieces = RegExp(r'\[[^\[\]\s]+\]| |\w+|[^\w\s]+');

  /// Greedy BPE over one pre-tokenized chunk.
  List<int> _encodeChunk(String word) {
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

  /// Whether [token] — brackets included, e.g. `[fr]` — is in the vocabulary
  /// as an atomic token.
  bool hasToken(String token) => _vocab.containsKey(token);
}
