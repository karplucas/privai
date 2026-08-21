import 'dart:io';
import 'dart:typed_data';

/// Encodes mono float samples in -1..1 as a 16-bit PCM WAV file.
///
/// [leadingSilence] prepends that much digital silence. Preparing the player
/// before resuming it (see `AudioClipPlayer`) is the actual fix for clipped
/// openings; this is the belt to that pair of braces, and cheap — a few
/// milliseconds of zeros cost nothing and are not heard as a gap, whereas a
/// swallowed first consonant is heard every time.
Uint8List encodeWav(
  List<double> samples, {
  required int sampleRate,
  int channels = 1,
  Duration leadingSilence = Duration.zero,
}) {
  const bitsPerSample = 16;
  final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
  final blockAlign = channels * (bitsPerSample ~/ 8);

  final padding =
      (leadingSilence.inMicroseconds * sampleRate) ~/ Duration.microsecondsPerSecond * channels;
  final pcm = Int16List(padding + samples.length);
  for (var i = 0; i < samples.length; i++) {
    pcm[padding + i] = (samples[i] * 32767).round().clamp(-32768, 32767);
  }
  final pcmBytes = pcm.buffer.asUint8List();

  final header = ByteData(44);
  header.setUint32(0, 0x52494646, Endian.big); // "RIFF"
  header.setUint32(4, 36 + pcmBytes.length, Endian.little);
  header.setUint32(8, 0x57415645, Endian.big); // "WAVE"
  header.setUint32(12, 0x666d7420, Endian.big); // "fmt "
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  header.setUint32(36, 0x64617461, Endian.big); // "data"
  header.setUint32(40, pcmBytes.length, Endian.little);

  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(pcmBytes))
      .takeBytes();
}

/// Reads a PCM WAV file as mono float samples in -1..1.
///
/// Handles the common 8/16/32-bit integer and 32-bit float encodings, downmixes
/// multi-channel audio, and nearest-neighbour resamples to [targetSampleRate]
/// when one is given — enough for reference-voice input, not a general decoder.
Future<Float32List> readWavMono(
  String path, {
  int? targetSampleRate,
}) async {
  final bytes = await File(path).readAsBytes();
  final data = ByteData.sublistView(bytes);

  if (bytes.length < 44 ||
      data.getUint32(0, Endian.big) != 0x52494646 ||
      data.getUint32(8, Endian.big) != 0x57415645) {
    throw FormatException('$path is not a RIFF/WAVE file');
  }

  var format = 1;
  var channels = 1;
  var sampleRate = targetSampleRate ?? 24000;
  var bitsPerSample = 16;
  var dataOffset = -1;
  var dataLength = 0;

  // Walk the chunk list rather than assuming "fmt " and "data" sit at fixed
  // offsets: real files interleave LIST/INFO chunks.
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = data.getUint32(offset, Endian.big);
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;

    if (id == 0x666d7420) {
      format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bitsPerSample = data.getUint16(body + 14, Endian.little);
    } else if (id == 0x64617461) {
      dataOffset = body;
      dataLength = size;
      break;
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }

  if (dataOffset < 0) throw FormatException('$path has no data chunk');
  dataLength = dataLength.clamp(0, bytes.length - dataOffset);

  final bytesPerSample = bitsPerSample ~/ 8;
  if (bytesPerSample == 0 || channels == 0) {
    throw FormatException('$path has an unusable format header');
  }
  final frameCount = dataLength ~/ (bytesPerSample * channels);
  final mono = Float32List(frameCount);

  for (var frame = 0; frame < frameCount; frame++) {
    var sum = 0.0;
    for (var channel = 0; channel < channels; channel++) {
      final at = dataOffset + (frame * channels + channel) * bytesPerSample;
      sum += switch ((format, bitsPerSample)) {
        (3, 32) => data.getFloat32(at, Endian.little),
        (_, 8) => (data.getUint8(at) - 128) / 128.0,
        (_, 16) => data.getInt16(at, Endian.little) / 32768.0,
        (_, 24) => _int24(data, at) / 8388608.0,
        (_, 32) => data.getInt32(at, Endian.little) / 2147483648.0,
        _ => throw FormatException(
            '$path uses an unsupported format ($format/$bitsPerSample-bit)'),
      };
    }
    mono[frame] = sum / channels;
  }

  if (targetSampleRate == null || targetSampleRate == sampleRate) return mono;
  return _resample(mono, from: sampleRate, to: targetSampleRate);
}

int _int24(ByteData data, int at) {
  final value = data.getUint8(at) |
      (data.getUint8(at + 1) << 8) |
      (data.getUint8(at + 2) << 16);
  return value & 0x800000 != 0 ? value - 0x1000000 : value;
}

Float32List _resample(Float32List input, {required int from, required int to}) {
  if (input.isEmpty || from == to) return input;
  final outLength = (input.length * to / from).floor();
  final output = Float32List(outLength);
  final ratio = from / to;
  for (var i = 0; i < outLength; i++) {
    final source = i * ratio;
    final left = source.floor();
    final right = (left + 1).clamp(0, input.length - 1);
    final t = source - left;
    output[i] = input[left] * (1 - t) + input[right] * t;
  }
  return output;
}
