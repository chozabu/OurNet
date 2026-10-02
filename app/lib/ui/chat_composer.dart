import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/clipboard_image.dart';

/// The message box of every chat, direct or group: a pill-shaped field with
/// attach, paste-image, voice and send buttons, and the keyboard behaviour
/// that goes with it (Enter sends, Shift+Enter adds a line, Esc leaves reply or
/// edit, Up in an empty box edits the last message, Ctrl/Cmd+V pastes an
/// image). Each chat supplies only what the buttons do.
class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;

  /// Null while sending is unavailable; Enter then does nothing, never a
  /// newline.
  final VoidCallback? onSend;

  /// Reply or edit banner above the field.
  final Widget? contextBar;
  final VoidCallback? onAttach;
  final VoidCallback? onPasteButton;

  /// Ctrl/Cmd+V. Without it the field pastes text as usual.
  final VoidCallback? onPasteShortcut;

  /// An image from the keyboard (stickers, GIFs).
  final void Function(Uint8List bytes, String? mime)? onImageInserted;
  final bool hasVoice;
  final VoidCallback? onVoice;

  /// Esc: true when it left a reply or edit.
  final bool Function()? onEscape;

  /// Up in an empty field: true when it started editing.
  final bool Function()? onEditLast;
  const ChatComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onSend,
    this.contextBar,
    this.onAttach,
    this.onPasteButton,
    this.onPasteShortcut,
    this.onImageInserted,
    this.hasVoice = false,
    this.onVoice,
    this.onEscape,
    this.onEditLast,
  });

  @override
  Widget build(BuildContext context) {
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    const sendHint = 'Enter sends · Shift+Enter adds a line';
    void send() {
      onSend?.call();
      focusNode.requestFocus();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        children: [
          ?contextBar,
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (onAttach != null)
                IconButton(
                  tooltip: 'Attach file',
                  onPressed: onAttach,
                  icon: const Icon(Icons.attach_file),
                ),
              if (onAttach != null && onPasteButton != null)
                IconButton(
                  tooltip: 'Paste image',
                  onPressed: onPasteButton,
                  icon: const Icon(Icons.content_paste),
                ),
              Expanded(
                child: Shortcuts(
                  // The text field consumes Ctrl+V before a Focus ancestor
                  // sees it, so claim the shortcut nearer to the field.
                  shortcuts: {
                    if (onPasteShortcut != null) ...{
                      const SingleActivator(
                        LogicalKeyboardKey.keyV,
                        control: true,
                      ): const _PasteIntent(),
                      const SingleActivator(
                        LogicalKeyboardKey.keyV,
                        meta: true,
                      ): const _PasteIntent(),
                    },
                  },
                  child: Actions(
                    actions: {
                      _PasteIntent: CallbackAction<_PasteIntent>(
                        onInvoke: (_) {
                          onPasteShortcut?.call();
                          return null;
                        },
                      ),
                    },
                    child: Focus(
                      onKeyEvent: (_, event) {
                        if (event is KeyDownEvent) {
                          if (event.logicalKey == LogicalKeyboardKey.escape &&
                              onEscape?.call() == true) {
                            return KeyEventResult.handled;
                          }
                          if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                              controller.text.isEmpty &&
                              onEditLast?.call() == true) {
                            return KeyEventResult.handled;
                          }
                        }
                        return enterSends(
                          controller,
                          event,
                          onSend == null ? null : send,
                        );
                      },
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        minLines: 1,
                        maxLines: 5,
                        contentInsertionConfiguration: onImageInserted != null
                            ? ContentInsertionConfiguration(
                                allowedMimeTypes: const [
                                  'image/png',
                                  'image/jpeg',
                                  'image/gif',
                                  'image/webp',
                                ],
                                onContentInserted: (content) {
                                  final bytes = content.data;
                                  if (bytes != null) {
                                    onImageInserted!(bytes, content.mimeType);
                                  }
                                },
                              )
                            : null,
                        decoration: InputDecoration(
                          hintText: hint,
                          filled: true,
                          fillColor: Theme.of(context).colorScheme.surface,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (hasVoice) ...[
                const SizedBox(width: 2),
                IconButton(
                  tooltip: 'Record voice message',
                  onPressed: onVoice,
                  icon: const Icon(Icons.mic_none),
                ),
              ],
              const SizedBox(width: 6),
              IconButton.filled(
                tooltip: desktop ? 'Send · $sendHint' : 'Send',
                style: IconButton.styleFrom(minimumSize: const Size.square(46)),
                onPressed: onSend == null ? null : send,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PasteIntent extends Intent {
  const _PasteIntent();
}

/// Pastes the clipboard into [controller]: [onImage] when it holds an image,
/// otherwise its text at the cursor.
Future<void> pasteIntoComposer(
  TextEditingController controller,
  Future<void> Function() onImage,
) async {
  if (await clipboardImage() != null) {
    await onImage();
    return;
  }
  final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  if (text == null || text.isEmpty) return;
  final selection = controller.selection;
  final start = selection.isValid ? selection.start : controller.text.length;
  final end = selection.isValid ? selection.end : start;
  controller.value = TextEditingValue(
    text: controller.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
  );
}

/// Composer key handling: Enter sends, Shift+Enter adds a line. Enter that
/// confirms an input-method composition is left alone. [send] null means
/// sending is unavailable, but Enter still never inserts a newline.
KeyEventResult enterSends(
  TextEditingController controller,
  KeyEvent event,
  VoidCallback? send,
) {
  if (event.logicalKey != LogicalKeyboardKey.enter ||
      (controller.value.composing.isValid &&
          !controller.value.composing.isCollapsed)) {
    return KeyEventResult.ignored;
  }
  if (HardwareKeyboard.instance.isShiftPressed) {
    if (event is KeyDownEvent) {
      final selection = controller.selection;
      final start = selection.isValid
          ? selection.start
          : controller.text.length;
      final end = selection.isValid ? selection.end : start;
      controller.value = TextEditingValue(
        text: controller.text.replaceRange(start, end, '\n'),
        selection: TextSelection.collapsed(offset: start + 1),
      );
    }
    return KeyEventResult.handled;
  }
  if (event is KeyDownEvent) send?.call();
  return KeyEventResult.handled;
}
