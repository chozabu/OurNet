import 'package:flutter/material.dart';

/// Light and dark tints for each shared note colour name in `noteColors`.
/// ARGB values are also sent to Android widgets, which always draw light.
const noteTints = <String, (int, int)>{
  'coral': (0xfffaafa8, 0xff77172e),
  'peach': (0xfff39f76, 0xff692b17),
  'sand': (0xfffff8b8, 0xff7c4a03),
  'mint': (0xffe2f6d3, 0xff264d3b),
  'sage': (0xffb4ddd3, 0xff0c625d),
  'fog': (0xffd4e4ed, 0xff256377),
  'storm': (0xffaeccdc, 0xff284255),
  'dusk': (0xffd3bfdb, 0xff472e5b),
  'blossom': (0xfff6e2dd, 0xff6c394f),
  'clay': (0xffe9e3d4, 0xff4b443a),
  'chalk': (0xffefeff1, 0xff232427),
};

const noteColorNames = <String, String>{
  'default': 'Default',
  'coral': 'Coral',
  'peach': 'Peach',
  'sand': 'Sand',
  'mint': 'Mint',
  'sage': 'Sage',
  'fog': 'Fog',
  'storm': 'Storm',
  'dusk': 'Dusk',
  'blossom': 'Blossom',
  'clay': 'Clay',
  'chalk': 'Chalk',
};

/// The surface for a note, or null to use the theme's default card colour.
Color? noteColor(BuildContext context, String? name) {
  final tint = noteTints[name];
  if (tint == null) return null;
  return Color(
    Theme.of(context).brightness == Brightness.dark ? tint.$2 : tint.$1,
  );
}

/// Bottom sheet palette. Returns the chosen colour name.
Future<String?> pickNoteColor(BuildContext context, String? current) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Colour', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final entry in noteColorNames.entries)
                    Tooltip(
                      message: entry.value,
                      child: InkResponse(
                        onTap: () => Navigator.pop(context, entry.key),
                        radius: 26,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color:
                                noteColor(context, entry.key) ??
                                Theme.of(context).colorScheme.surface,
                            border: Border.all(
                              width: (current ?? 'default') == entry.key
                                  ? 3
                                  : 1,
                              color: (current ?? 'default') == entry.key
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.outline,
                            ),
                          ),
                          child: entry.key == 'default'
                              ? const Icon(Icons.format_color_reset, size: 20)
                              : (current ?? 'default') == entry.key
                              ? const Icon(Icons.check, size: 20)
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
