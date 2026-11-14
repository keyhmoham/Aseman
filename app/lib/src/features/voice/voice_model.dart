import 'dart:math' as math;

/// Voice-message timing and display helpers (aligned with Decillion's
/// `voiceModel.ts`). Metadata is stored on `users.dm_file_upload`.

/// Longest recording the app will keep (the node accepts up to 10 minutes).
const maxVoiceMs = 5 * 60 * 1000;

/// Shorter than this is treated as an accidental tap.
const minVoiceMs = 600;

/// How many loudness bars a finished voice note carries.
const waveBars = 40;

/// `0:07`, `1:05`, `12:30`.
String formatVoiceClock(int ms) {
  final total = ms < 0 ? 0 : ms ~/ 1000;
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// True once the recording is long enough to send.
bool voiceLongEnough(int durationMs) => durationMs >= minVoiceMs;

/// Fold [levels] (0..1 over time) into [count] bars of 0..100.
List<int> levelsToWaveBars(List<double> levels, [int count = waveBars]) {
  if (levels.isEmpty || count <= 0) return const [];
  final raw = <double>[];
  for (var i = 0; i < count; i++) {
    final from = (i * levels.length) ~/ count;
    final to =
        (((i + 1) * levels.length) ~/ count).clamp(from + 1, levels.length);
    final slice = levels.sublist(from, to);
    final mean = slice.reduce((a, b) => a + b) / slice.length;
    final peak = slice.reduce((a, b) => a > b ? a : b);
    raw.add(0.6 * mean + 0.4 * peak);
  }
  final peak = raw.reduce((a, b) => a > b ? a : b);
  final scale = peak > 1e-6 ? peak : 1e-6;
  return [
    for (final v in raw) (((v / scale) * 100).round().clamp(6, 100)),
  ];
}

/// Loudness from a PCM16 little-endian mono chunk as 0..1.
double levelFromPcm16(List<int> pcm) {
  if (pcm.length < 4) return 0;
  final samples = pcm.length ~/ 2;
  var sum = 0.0;
  for (var i = 0; i < samples; i++) {
    final lo = pcm[i * 2];
    final hi = pcm[i * 2 + 1];
    final s = (hi << 8) | lo;
    final signed = s >= 0x8000 ? s - 0x10000 : s;
    sum += signed * signed;
  }
  final rms = math.sqrt(sum / samples) / 32768.0;
  // Speech is typically quiet on the meter; lift it so the wave moves.
  final lifted = (rms * 6).clamp(0.0, 1.0);
  return math.pow(lifted, 0.7).toDouble();
}
