import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Plays the rendered clips of one speech engine, one at a time.
///
/// Every engine had its own copy of this, and each copy called
/// `AudioPlayer.play()`, which sets the source and starts the clock in a single
/// step. On iOS and macOS the audio session is still being activated and the
/// output route established at that moment, and whatever plays during that
/// window is not heard — the clipped first syllable that showed up on every
/// engine. Preparing the source first, then resuming, gives the platform
/// somewhere to do that work before playback starts.
class AudioClipPlayer {
  AudioClipPlayer(this.label);

  /// Name used in logs, so a stall can be traced to its engine.
  final String label;

  /// Silence every engine prepends to a clip; see `encodeWav`.
  static const Duration leadingSilence = Duration(milliseconds: 80);

  AudioPlayer? _player;

  AudioPlayer get _ensurePlayer => _player ??= AudioPlayer();

  /// Prepares the player so the first clip does not pay for session set-up.
  ///
  /// Optional: [play] works without it, but the first utterance of a session is
  /// the one most likely to be clipped, and it is the one the user notices.
  Future<void> warmUp() async {
    try {
      await _ensurePlayer.setReleaseMode(ReleaseMode.stop);
    } catch (e) {
      debugPrint('$label: could not prepare the player: $e');
    }
  }

  /// Plays [file] and returns once it has finished, been interrupted, or the
  /// backstop has expired.
  ///
  /// [expected] is how long the clip should take; it only sizes the backstop.
  /// That backstop exists because a dropped completion event would otherwise
  /// hang the queue forever, but it must never be *shorter* than the audio —
  /// returning early makes the caller start the next clip, which replaces the
  /// source mid-sentence and is heard as speech stopping partway through.
  Future<void> play(
    File file, {
    Duration? expected,
    Future<void>? interrupted,
  }) async {
    final player = _ensurePlayer;

    // Subscribed before playback starts: `onPlayerComplete` is a broadcast
    // stream with no replay, so a clip that finishes before the listener
    // attaches drops its only completion event.
    final completed = player.onPlayerComplete.first;

    await player.setSource(DeviceFileSource(file.path));
    await player.resume();

    final backstop = (expected ?? const Duration(minutes: 1)) +
        const Duration(seconds: 10);
    await Future.any<void>([
      completed,
      if (interrupted != null) interrupted,
      Future<void>.delayed(backstop).then((_) {
        debugPrint('$label: playback did not report completion within '
            '${backstop.inSeconds}s');
      }),
    ]);
  }

  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('$label: error stopping playback: $e');
    }
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _player?.dispose();
    } catch (e) {
      debugPrint('$label: error disposing the player: $e');
    }
    _player = null;
  }
}
