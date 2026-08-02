/// Turns streamed text fragments into natural TTS-sized utterances.
///
/// Sentence punctuation is preferred. Long run-on output is split at a word
/// boundary so synthesis can still begin before the LLM finishes its reply.
class SpeechChunker {
  SpeechChunker({this.maxCharacters = 220});

  final int maxCharacters;
  String _buffer = '';

  List<String> add(String fragment) {
    _buffer += fragment;
    return _takeComplete(finalFlush: false);
  }

  List<String> finish() => _takeComplete(finalFlush: true);

  List<String> _takeComplete({required bool finalFlush}) {
    final chunks = <String>[];
    while (true) {
      final sentence =
          RegExp(r'''[.!?]+["')\]]*(?:\s+|$)''').firstMatch(_buffer);
      var cut = sentence?.end;

      if (cut == null && _buffer.length >= maxCharacters) {
        final window = _buffer.substring(0, maxCharacters);
        cut = window.lastIndexOf(RegExp(r'\s'));
        if (cut <= 0) cut = maxCharacters;
      }
      if (cut == null) break;

      final chunk = _buffer.substring(0, cut).trim();
      _buffer = _buffer.substring(cut).trimLeft();
      if (chunk.isNotEmpty) chunks.add(chunk);
    }

    if (finalFlush) {
      final tail = _buffer.trim();
      _buffer = '';
      if (tail.isNotEmpty) chunks.add(tail);
    }
    return chunks;
  }
}
