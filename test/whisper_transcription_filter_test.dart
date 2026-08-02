import 'package:flutter_test/flutter_test.dart';
import 'package:privai/services/whisper_service.dart';

void main() {
  test('discards bracketed Whisper annotations', () {
    expect(WhisperService.sanitizeTranscription('[BLANK_AUDIO]'), isEmpty);
    expect(WhisperService.sanitizeTranscription('  [music]  '), isEmpty);
    expect(
        WhisperService.sanitizeTranscription('[inaudible\nspeech]'), isEmpty);
    expect(WhisperService.sanitizeTranscription('(silence)'), isEmpty);
    expect(
      WhisperService.sanitizeTranscription('  (background noise)  '),
      isEmpty,
    );
  });

  test('keeps spoken text that is not wholly bracketed', () {
    expect(
      WhisperService.sanitizeTranscription('[note] please continue'),
      '[note] please continue',
    );
    expect(WhisperService.sanitizeTranscription('hello'), 'hello');
    expect(
      WhisperService.sanitizeTranscription('hello (again)'),
      'hello (again)',
    );
  });
}
