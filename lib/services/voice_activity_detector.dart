enum VoiceTurnState { listening, complete, noSpeech }

/// Requires a short run of loud samples before treating speech as a barge-in.
/// This avoids stopping for taps and other isolated noises.
class BargeInDetector {
  BargeInDetector({
    required this.startedAt,
    this.thresholdDb = -32,
    this.gracePeriod = const Duration(milliseconds: 500),
    this.sustainedFor = const Duration(milliseconds: 450),
  });

  final DateTime startedAt;
  final double thresholdDb;
  final Duration gracePeriod;
  final Duration sustainedFor;
  DateTime? _loudSince;

  bool add(double db, DateTime now) {
    if (now.difference(startedAt) < gracePeriod) return false;
    if (db < thresholdDb) {
      _loudSince = null;
      return false;
    }
    _loudSince ??= now;
    return now.difference(_loudSince!) >= sustainedFor;
  }
}

/// Small deterministic silence detector for hands-free voice turns.
class VoiceActivityDetector {
  VoiceActivityDetector({
    required this.startedAt,
    this.speechThresholdDb = -35,
    this.endSilence = const Duration(milliseconds: 1200),
    this.waitForSpeech = const Duration(seconds: 12),
    this.maxTurn = const Duration(seconds: 30),
  });

  final DateTime startedAt;
  final double speechThresholdDb;
  final Duration endSilence;
  final Duration waitForSpeech;
  final Duration maxTurn;

  bool _heardSpeech = false;
  DateTime? _lastSpeechAt;

  bool get heardSpeech => _heardSpeech;

  VoiceTurnState add(double db, DateTime now) {
    final elapsed = now.difference(startedAt);
    if (db.isFinite && db >= speechThresholdDb) {
      _heardSpeech = true;
      _lastSpeechAt = now;
    }

    if (!_heardSpeech && elapsed >= waitForSpeech) {
      return VoiceTurnState.noSpeech;
    }
    if (_heardSpeech && elapsed >= maxTurn) {
      return VoiceTurnState.complete;
    }
    final lastSpeech = _lastSpeechAt;
    if (lastSpeech != null && now.difference(lastSpeech) >= endSilence) {
      return VoiceTurnState.complete;
    }
    return VoiceTurnState.listening;
  }
}
