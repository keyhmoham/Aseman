import 'dart:convert';
import 'dart:typed_data';

import '../../../data/services/aseman_service.dart';
import 'live_speaker.dart';
import 'live_voice_model.dart';

/// Which voice roles the node serves (Admin → AI → Voice): true when on.
class LiveVoiceConfig {
  const LiveVoiceConfig({this.speech = false, this.transcription = false});

  final bool speech;
  final bool transcription;

  /// Live voice needs both: it listens with the transcription model and
  /// answers with the speech model.
  bool get ready => speech && transcription;
}

/// What a live voice chat asks of the Decillion node. What you say becomes a
/// note like any typed one — so its brain, memory, tools and your credits work
/// exactly as in the text chat — and only the ears and mouth are voice models.
abstract class LiveVoiceBackend {
  Future<LiveVoiceConfig> config();

  /// One short piece of a turn as text; "" when nothing was recognized.
  Future<String> transcribeChunk(Uint8List wav);

  /// Say [text] with the node's speech model.
  Future<SpeechClip> speak(String text);

  /// Send what was said as a note; resolves with its id.
  Future<String> sendNote(String text);

  /// The note's answer so far, and any proposal waiting for a tap.
  Future<LiveSnapshot> snapshot(String noteId);

  /// Confirm or cancel what Decillion proposed.
  Future<void> confirm(String proposalId, {required bool approve});
}

/// The live voice backend of one direct chat (your own Aseman, or an agent),
/// over the node's `users` actions.
class ServiceLiveVoiceBackend implements LiveVoiceBackend {
  ServiceLiveVoiceBackend(this.service, {required this.peer});

  final AsemanService service;

  /// The chat's peer id, as the messenger addresses it (your own id for your
  /// personal Aseman).
  final String peer;

  String get _me => service.session?.accountId ?? '';

  @override
  Future<LiveVoiceConfig> config() async {
    final out = await service.voiceConfig();
    return LiveVoiceConfig(
      speech: out['speech'] == true,
      transcription: out['transcription'] == true,
    );
  }

  @override
  Future<String> transcribeChunk(Uint8List wav) async {
    final out = await service.voiceTranscribeChunk(
      audio: wav,
      mime: 'audio/wav',
    );
    return '${out['text'] ?? ''}'.trim();
  }

  @override
  Future<SpeechClip> speak(String text) async {
    final out = await service.voiceSpeak(text);
    final audio = '${out['audio'] ?? ''}';
    if (audio.isEmpty) throw const LiveVoiceException('No speech came back.');
    final mime = '${out['mime'] ?? ''}';
    return SpeechClip(
      base64Decode(audio),
      mime.isEmpty ? 'audio/wav' : mime,
    );
  }

  @override
  Future<String> sendNote(String text) async {
    final sent = await service.sendDirectMessage(peer, text, voice: true);
    return sent.id;
  }

  @override
  Future<LiveSnapshot> snapshot(String noteId) async => parseLiveSnapshot(
        await service.dmList(peer, limit: 30),
        noteId: noteId,
        me: _me,
      );

  @override
  Future<void> confirm(String proposalId, {required bool approve}) async {
    await service.brainConfirm(proposalId, approve: approve);
  }
}
