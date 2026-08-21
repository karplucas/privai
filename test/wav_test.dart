import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:privai/services/wav.dart';

void main() {
  ByteData view(Uint8List wav) => ByteData.sublistView(wav);

  test('writes a header that matches the samples it carries', () {
    final wav = encodeWav([0.0, 1.0, -1.0], sampleRate: 16000);

    expect(wav.length, 44 + 3 * 2);
    expect(view(wav).getUint32(40, Endian.little), 6, reason: 'data size');
    expect(view(wav).getUint32(4, Endian.little), 36 + 6, reason: 'riff size');
    expect(view(wav).getUint32(24, Endian.little), 16000);
  });

  test('prepends silence without displacing the samples', () {
    const rate = 16000;
    final wav = encodeWav(
      [1.0, -1.0],
      sampleRate: rate,
      leadingSilence: const Duration(milliseconds: 80),
    );

    // 80 ms at 16 kHz is 1280 samples of zeros, then the audio itself.
    const padding = 1280;
    expect(wav.length, 44 + (padding + 2) * 2);
    expect(view(wav).getUint32(40, Endian.little), (padding + 2) * 2);

    final samples = Int16List.sublistView(wav, 44);
    expect(samples.take(padding), everyElement(0));
    expect(samples[padding], 32767);
    expect(samples[padding + 1], -32767);
  });

  test('clips rather than wrapping around on out-of-range input', () {
    final samples =
        Int16List.sublistView(encodeWav([2.0, -2.0], sampleRate: 8000), 44);
    expect(samples[0], 32767);
    expect(samples[1], -32768);
  });
}
