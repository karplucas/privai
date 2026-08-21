import 'package:flutter_test/flutter_test.dart';
import 'package:privai/services/mms_tts_service.dart';

void main() {
  // The real English vocabulary is a flat character map; these are its actual
  // ids for the characters used below.
  const vocab = {' ': 19, 'a': 26, 'b': 24, 'h': 6, 'i': 18, 'k': 0};

  test('interleaves the blank token, which the model was trained with', () {
    // "hi" -> blank h blank i blank. Without the interleaving the model reads a
    // sequence half the expected length and returns noise.
    expect(MmsTtsService.encode('hi', vocab), [0, 6, 0, 18, 0]);
  });

  test('lower-cases, since the vocabulary has no capitals', () {
    expect(MmsTtsService.encode('HI', vocab),
        MmsTtsService.encode('hi', vocab));
  });

  test('drops characters outside the alphabet but keeps spacing', () {
    // Punctuation has no token; the space survives because pauses come from it.
    expect(MmsTtsService.encode('ah, bi!', vocab), [
      0, 26, 0, 6, 0, // "ah"
      19, 0, // the comma is dropped, the space is not
      24, 0, 18, 0, // "bi"
    ]);
  });

  test('returns nothing for text with no speakable characters', () {
    expect(MmsTtsService.encode('!?...', vocab), isEmpty);
    expect(MmsTtsService.encode('', vocab), isEmpty);
  });
}
