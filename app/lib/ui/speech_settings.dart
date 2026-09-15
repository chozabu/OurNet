import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/speech.dart';

const speechLanguages = {
  'auto': 'Detect automatically',
  'en': 'English',
  'de': 'Deutsch',
  'es': 'Español',
  'fr': 'Français',
  'it': 'Italiano',
  'nl': 'Nederlands',
  'pl': 'Polski',
  'pt': 'Português',
  'sv': 'Svenska',
  'tr': 'Türkçe',
  'uk': 'Українська',
  'ru': 'Русский',
  'ar': 'العربية',
  'hi': 'हिन्दी',
  'ja': '日本語',
  'ko': '한국어',
  'zh': '中文',
};

/// Explains on-device transcription and downloads the selected model with
/// consent. Returns true when a model is ready.
Future<bool> offerSpeechModel(BuildContext context, Speech speech) async {
  if (await speech.installed(speech.model)) return true;
  if (!context.mounted) return false;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => _ModelDialog(speech: speech),
  );
  return result == true;
}

class _ModelDialog extends StatefulWidget {
  final Speech speech;
  const _ModelDialog({required this.speech});
  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  String? error;
  late String model = widget.speech.modelId;

  @override
  void initState() {
    super.initState();
    widget.speech.addListener(_changed);
  }

  @override
  void dispose() {
    widget.speech.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> download() async {
    setState(() => error = null);
    widget.speech.modelId = model;
    try {
      await widget.speech.download(widget.speech.model);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final speech = widget.speech;
    final busy = speech.downloading != null;
    return AlertDialog(
      title: const Text('Transcribe on this device'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'OurNet turns recordings into text with Whisper, running entirely on this device. Your audio is never uploaded. The speech model is downloaded once from the whisper.cpp project and checked before use.',
            ),
            const SizedBox(height: 12),
            RadioGroup<String>(
              groupValue: model,
              onChanged: (v) {
                if (!busy && v != null) setState(() => model = v);
              },
              child: Column(
                children: [
                  for (final option in speechModels)
                    RadioListTile<String>(
                      value: option.id,
                      enabled: !busy,
                      title: Text('${option.label} · ${option.megabytes}'),
                      subtitle: Text(
                        option.id == 'base'
                            ? 'Better with names and accents; slower on older phones'
                            : 'Quicker; best for short, clear notes',
                      ),
                    ),
                ],
              ),
            ),
            if (busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: speech.downloadProgress),
              const SizedBox(height: 4),
              Text('${(speech.downloadProgress * 100).round()}%'),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Recordings are kept either way. You can transcribe later from the recording menu.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (busy) speech.cancelDownload();
            Navigator.pop(context, false);
          },
          child: Text(busy ? 'Cancel download' : 'Not now'),
        ),
        FilledButton(
          onPressed: busy ? null : download,
          child: const Text('Download'),
        ),
      ],
    );
  }
}

/// Settings section for voice notes.
class SpeechSettings extends StatelessWidget {
  final Speech speech;
  final void Function(String message) notice;
  const SpeechSettings({super.key, required this.speech, required this.notice});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: speech,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.record_voice_over_outlined),
          title: const Text('Voice note transcription'),
          subtitle: Text(switch (speech.engine) {
            'system' =>
              'System speech service. Audio may be sent to its provider.',
            'off' => 'Off. Recordings are kept without text.',
            _ => 'On this device with Whisper. Audio stays private.',
          }),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: [
              const ButtonSegment(value: 'whisper', label: Text('On device')),
              if (Platform.isAndroid)
                ButtonSegment(
                  value: 'system',
                  label: const Text('System service'),
                  enabled: speech.systemAvailable,
                ),
              const ButtonSegment(value: 'off', label: Text('Off')),
            ],
            selected: {speech.engine},
            onSelectionChanged: (value) async {
              final chosen = value.single;
              if (chosen == 'system') {
                final agreed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Use the system speech service?'),
                    content: const Text(
                      'Your phone\'s speech service (often Google) may send voice note audio to its provider to transcribe it. On-device Whisper keeps audio private.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Use system service'),
                      ),
                    ],
                  ),
                );
                if (agreed != true) return;
              }
              speech.engine = chosen;
            },
          ),
        ),
        if (Platform.isAndroid && !speech.systemAvailable)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              'The system service option needs Android 13 or later with a speech service installed.',
            ),
          ),
        if (speech.engine == 'whisper')
          FutureBuilder<List<bool>>(
            future: Future.wait([
              for (final m in speechModels) speech.installed(m),
            ]),
            builder: (context, snapshot) => RadioGroup<String>(
              groupValue: speech.modelId,
              onChanged: (v) => speech.modelId = v ?? speech.modelId,
              child: Column(
                children: [
                  for (final (i, model) in speechModels.indexed)
                    RadioListTile<String>(
                      value: model.id,
                      title: Text('${model.label} model · ${model.megabytes}'),
                      subtitle: Text(
                        speech.downloading == model.id
                            ? 'Downloading… ${(speech.downloadProgress * 100).round()}%'
                            : snapshot.data?[i] == true
                            ? 'Downloaded'
                            : 'Not downloaded',
                      ),
                      secondary: speech.downloading == model.id
                          ? IconButton(
                              tooltip: 'Cancel download',
                              onPressed: speech.cancelDownload,
                              icon: const Icon(Icons.close),
                            )
                          : snapshot.data?[i] == true
                          ? IconButton(
                              tooltip: 'Delete model',
                              onPressed: () => speech.removeModel(model),
                              icon: const Icon(Icons.delete_outline),
                            )
                          : IconButton(
                              tooltip: 'Download model',
                              onPressed: speech.downloading != null
                                  ? null
                                  : () => unawaited(
                                      speech
                                          .download(model)
                                          .catchError(
                                            (Object e) => notice('$e'),
                                          ),
                                    ),
                              icon: const Icon(Icons.download_outlined),
                            ),
                    ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonFormField<String>(
            initialValue: speechLanguages.containsKey(speech.language)
                ? speech.language
                : 'auto',
            decoration: const InputDecoration(labelText: 'Spoken language'),
            items: [
              for (final entry in speechLanguages.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) => speech.language = value ?? 'auto',
          ),
        ),
      ],
    ),
  );
}
