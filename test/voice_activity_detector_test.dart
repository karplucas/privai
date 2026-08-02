import 'package:flutter_test/flutter_test.dart';
import 'package:privai/services/voice_activity_detector.dart';

void main() {
  test('barge-in requires sustained speech after its grace period', () {
    final start = DateTime(2026);
    final detector = BargeInDetector(startedAt: start);

    expect(detector.add(-20, start.add(const Duration(milliseconds: 400))),
        isFalse);
    expect(detector.add(-20, start.add(const Duration(milliseconds: 600))),
        isFalse);
    expect(detector.add(-20, start.add(const Duration(milliseconds: 1100))),
        isTrue);
  });

  test('barge-in ignores isolated loud noises', () {
    final start = DateTime(2026);
    final detector = BargeInDetector(startedAt: start);

    expect(detector.add(-20, start.add(const Duration(milliseconds: 600))),
        isFalse);
    expect(detector.add(-60, start.add(const Duration(milliseconds: 800))),
        isFalse);
    expect(detector.add(-20, start.add(const Duration(milliseconds: 1000))),
        isFalse);
  });

  final start = DateTime(2026);

  test('waits for speech and completes after sustained silence', () {
    final detector = VoiceActivityDetector(startedAt: start);

    expect(detector.add(-60, start), VoiceTurnState.listening);
    expect(
      detector.add(-20, start.add(const Duration(seconds: 1))),
      VoiceTurnState.listening,
    );
    expect(
      detector.add(-60, start.add(const Duration(milliseconds: 2100))),
      VoiceTurnState.listening,
    );
    expect(
      detector.add(-60, start.add(const Duration(milliseconds: 2200))),
      VoiceTurnState.complete,
    );
  });

  test('abandons an empty listening window', () {
    final detector = VoiceActivityDetector(startedAt: start);
    expect(
      detector.add(-60, start.add(const Duration(seconds: 12))),
      VoiceTurnState.noSpeech,
    );
  });

  test('caps a continuously spoken turn', () {
    final detector = VoiceActivityDetector(startedAt: start);
    detector.add(-20, start);
    expect(
      detector.add(-20, start.add(const Duration(seconds: 30))),
      VoiceTurnState.complete,
    );
  });
}
