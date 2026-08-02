import 'package:flutter_test/flutter_test.dart';
import 'package:privai/services/speech_chunker.dart';

void main() {
  test('emits complete sentences across streamed fragments', () {
    final chunker = SpeechChunker();

    expect(chunker.add('Hello there.'), ['Hello there.']);
    expect(chunker.add(' How are you? Next'), ['How are you?']);
    expect(chunker.finish(), ['Next']);
  });

  test('splits long run-on output at a word boundary', () {
    final chunker = SpeechChunker(maxCharacters: 20);

    final chunks = chunker.add('one two three four five six seven');

    expect(chunks, ['one two three four']);
    expect(chunker.finish(), ['five six seven']);
  });

  test('does not return empty chunks for whitespace', () {
    final chunker = SpeechChunker();
    expect(chunker.add('   '), isEmpty);
    expect(chunker.finish(), isEmpty);
  });
}
