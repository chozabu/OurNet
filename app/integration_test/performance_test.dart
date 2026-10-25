import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'calendar_history_test.dart' as calendar;
import 'conversation_history_test.dart' as conversation;
import 'group_history_test.dart' as groups;
import 'note_history_test.dart' as notes;
import 'photo_scroll_test.dart' as photos;
import 'responsiveness_test.dart' as responsiveness;
import 'git_browser_test.dart' as git_browser;

/// One profile compilation; each journey keeps its own temporary profiles,
/// cleanup, report keys and acceptance budgets. Individual targets still work.
void main() {
  // Photo decoding counters require this binding before any suite registers.
  final binding = photos.CountingBinding();
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  group('responsiveness', responsiveness.main);
  group('photos and maps', () => photos.registerPhotoScrollTests(binding));
  group('notes', notes.main);
  group('conversations', conversation.main);
  group('groups', groups.main);
  group('calendar', calendar.main);
  group('git browser', git_browser.main);
}
