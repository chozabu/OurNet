import '../services/drafts.dart';
import '../services/folder_connections.dart';
import '../services/coalesced_task.dart';
import '../services/performance.dart';
import '../services/share_inbox.dart';
import '../services/everyday_sync.dart';
import '../services/thumbnails.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart'
    show DriveSync, FolderSync;
import '../services/network.dart';
import '../services/files.dart';
import '../services/calls.dart';
import '../services/notifications.dart';
import '../services/session.dart';
import 'world_map.dart';
import 'inline_image.dart';
import 'friend_invite.dart';
import '../build_info.dart';
import 'add_device.dart';
import 'onboarding.dart';
import 'sync_status.dart';
import 'sync_health.dart';
import 'conversation_delivery.dart';
import 'note_editor.dart';
import 'note_card.dart';
import 'note_colors.dart';
import 'package:animations/animations.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../services/note_widgets.dart';
import '../services/reminders.dart';
import '../services/speech.dart';
import 'drawing.dart';
import 'note_markup.dart';
import 'note_organise.dart';
import 'speech_settings.dart';
import 'voice_recorder.dart';
import 'package:image_picker/image_picker.dart';

part 'home.dart';
part 'everyday.dart';
part 'social.dart';
part 'objects.dart';
part 'network.dart';
part 'voting.dart';
part 'settings.dart';
part 'drive.dart';
part 'discovery.dart';
part 'group_members.dart';
part 'forum_features.dart';
part 'notes_home.dart';

class OurNetApp extends StatefulWidget {
  final Node node;
  final bool enablePlatform;
  final int? initialTab;
  final Future<({String path, String name})?> Function()? pickAttachment;

  /// Replaces the platform image picker in note editors (tests).
  final Future<XFile?> Function(ImageSource source)? pickImage;
  const OurNetApp({
    super.key,
    required this.node,
    this.enablePlatform = true,
    this.initialTab,
    this.pickAttachment,
    this.pickImage,
  });
  @override
  State<OurNetApp> createState() => _OurNetAppState();
}

class _OurNetAppState extends State<OurNetApp> with WidgetsBindingObserver {
  Node get node => widget.node;
  late final Network network;
  late final Files files;
  late final DriveSync driveSync;
  late final FolderSync folderSync;
  bool connectingFolder = false;
  late final EverydaySync everydaySync;
  ShareInbox? shareInbox;
  late final Notes notes;
  NoteWidgets? noteWidgets;
  late final Speech speech;
  NoteReminders? reminders;
  bool savingNote = false;
  Future<List<DriveEntry>>? driveView;
  String? driveFolder;
  bool publicFiles = false;
  late final Calls calls;
  late final Notifications notifications;
  StreamSubscription<void>? _changes;
  late final CoalescedTask _dataRefresh;
  late final CoalescedTask _deliveryRefresh;
  bool addingAttachment = false;
  final imports = ValueNotifier<Map<Object, ({int completed, int total})>>({});
  final performance = PerformanceMonitor();
  int _badgeCount = -1;
  bool _ringing = false;
  Timer? _pausedStop;
  final messenger = GlobalKey<ScaffoldMessengerState>();
  final noteNavigator = GlobalKey<NavigatorState>();
  int tab = 9;
  bool showConversation = false;
  bool showForum = false;
  bool attachmentFiles = false;
  String notesFilter = 'All';
  final notesSearch = TextEditingController();
  bool notesGrid = true;

  /// Optimistic list state shown before summaries catch up.
  final hiddenNotes = <String>{};
  final selectedNotes = <String>{};
  final noteObjects = <String, SignedObject?>{};
  final notesSearchFocus = FocusNode();
  final noteChecks = <String, Map<String, bool>>{};
  final roomChecks = <String, bool>{};
  String fileQuery = '';
  final fileSearch = TextEditingController();
  String fileSort = 'Newest';
  String searchScope = 'All';
  Future<List<_SearchHit>>? searchIndex;
  EverydayItem? activeRoom;
  Future<List<EverydayItem>>? everydayView;
  Future<List<EverydayItem>>? roomsView;
  Future<List<(EverydayItem, String)>>? attachmentsView;
  final inboxComposer = TextEditingController();
  final listName = TextEditingController(text: 'Shopping');
  String everydaySection = 'Conversation';
  bool inboxDragging = false;
  bool dark = false, busy = false;
  bool compact = false;
  int accent = 0xff137d72;
  String space = 'general';
  String? selectedThread;
  String? contact;
  String? replyTo;
  final composer = TextEditingController();
  bool switchingDraft = false;
  late final DraftStore draftStore;
  final drafts = <String, TextEditingValue>{};
  String? composerContext;
  String? notesComposerContext;
  final deliveryLabels = <String, String>{};
  final conversationOlder = <String, List<SignedObject>>{};
  final conversationEnd = <String>{};
  final conversationPending = <String>{};
  final conversationScroll = <String, ScrollController>{};
  int conversationCursor = 0;
  final sendingMessages = <String>{};
  final messageErrors = <String, String>{};
  final fileProgress = <String, double>{};
  final fileErrors = <String, String>{};
  final search = TextEditingController();
  static const titles = [
    'Home',
    'Forums',
    'Direct messages',
    'Files',
    'Network',
    'Locations',
    'Voting',
    'Profile',
    'Settings',
    'Notes',
    'Private groups',
    'Search',
  ];
  static const icons = [
    Icons.home_outlined,
    Icons.forum_outlined,
    Icons.chat_bubble_outline,
    Icons.folder_outlined,
    Icons.hub_outlined,
    Icons.map_outlined,
    Icons.how_to_vote_outlined,
    Icons.person_outline,
    Icons.settings_outlined,
    Icons.note_alt_outlined,
    Icons.people_outline,
    Icons.search,
  ];

  @override
  void initState() {
    super.initState();
    if (widget.enablePlatform) performance.start();
    conversationCursor = node.store.insertionCursor;
    draftStore = DraftStore(node);
    notes = Notes(node);
    inboxComposer.addListener(
      () => rememberDraft(notesComposerContext, inboxComposer),
    );
    composer.addListener(() => rememberDraft(composerContext, composer));
    unawaited(
      draftStore.ready
          .then<void>((_) {
            if (!mounted) return;
            for (final entry in draftStore.values.entries) {
              drafts[entry.key] = TextEditingValue(
                text: entry.value,
                selection: TextSelection.collapsed(offset: entry.value.length),
              );
            }
            if (notesComposerContext != null && inboxComposer.text.isEmpty) {
              inboxComposer.value =
                  drafts[notesComposerContext] ?? TextEditingValue.empty;
            }
            if (composerContext != null && composer.text.isEmpty) {
              composer.value =
                  drafts[composerContext] ?? TextEditingValue.empty;
            }
          })
          .catchError((Object e) => notice('Could not restore drafts: $e')),
    );
    final saved = node.store.setting('lastDestination');
    tab =
        widget.initialTab ??
        (saved is int && [9, 2, 10, 1, 3, 8].contains(saved) ? saved : 9);
    if (tab == 0) tab = 9;
    dark = node.store.setting('dark') == true;
    compact = node.store.setting('compact') == true;
    notesGrid = node.store.setting('notesGrid') != false;
    accent = node.store.setting('accent') as int? ?? 0xff137d72;
    network = Network(node)..addListener(refresh);
    files = Files(node, network);
    speech = Speech(notes, files)..addListener(refresh);
    everydaySync = EverydaySync(
      network,
      refresh,
      onCached: (object, payload) {
        if (isImagePayload(payload)) {
          unawaited(Thumbnails.of(files).prepare(object).catchError((_) {}));
        }
      },
    );
    driveSync = DriveSync(network, onUpdate: refresh);
    folderSync = FolderSync(
      files,
      folderBackend,
      onUpdate: refresh,
      automatic: widget.enablePlatform,
    );
    calls = Calls(network)..addListener(refresh);
    notifications = Notifications(node)
      ..onError = notice
      ..onCallOpen = () {
        if (mounted) {
          update(() {
            tab = 2;
            showConversation = true;
          });
        }
      }
      ..onOpen = (id) {
        final object = node.store.get(id);
        if (object == null) return;
        setState(() {
          tab = object.kind == 'message' ? 2 : 1;
          showConversation = true;
          showForum = true;
          contact = object.author;
          space = object.space;
        });
      };
    _deliveryRefresh = CoalescedTask(loadDeliveryLabels, (e) => notice('$e'));
    _dataRefresh = CoalescedTask(() async {
      await refreshConversations();
      searchIndex = null;
      driveView = null;
      everydayView = null;
      roomsView = null;
      attachmentsView = null;
      refresh();
      _deliveryRefresh.schedule();
    }, (e) => notice('$e'));
    _changes = node.changes.stream.listen((_) => _dataRefresh.schedule());
    _deliveryRefresh.schedule();
    if (widget.enablePlatform) {
      if (node.store.setting('autoConnect') != false) {
        unawaited(
          network.start().catchError(
            (Object e) => notice('Connection unavailable: $e'),
          ),
        );
      }
      WidgetsBinding.instance.addObserver(this);
      if (Platform.isAndroid) {
        noteWidgets = NoteWidgets(notes, (id, mode) async {
          if (!mounted) return;
          update(() {
            tab = 9;
            activeRoom = null;
          });
          if (id != null && await notes.get(id) == null) {
            notice('This note is unavailable for this profile.');
            return;
          }
          if (!mounted) return;
          if (mode == 'voice') {
            await captureVoice();
            return;
          }
          // New notes are created once something is written.
          await openNote(id, checklist: mode == 'checklist');
        }, notice);
        unawaited(noteWidgets!.start());
        shareInbox = ShareInbox(
          node,
          (path, name) => addEverydayFile(path, name: name),
          (error) {
            update(() {
              tab = 9;
              activeRoom = null;
            });
            notice(error ?? 'Saved to Notes');
          },
        );
        unawaited(shareInbox!.start());
      }
      unawaited(
        speech.start().catchError(
          (Object e) => notice('Voice transcription unavailable: $e'),
        ),
      );
      reminders = NoteReminders(notes, notifications);
      notifications.onOpenNote = (id) {
        if (!mounted) return;
        update(() {
          tab = 9;
          activeRoom = null;
        });
        unawaited(openNote(id));
      };
      unawaited(
        reminders!.start().catchError(
          (Object e) => notice('Reminders unavailable: $e'),
        ),
      );
      unawaited(
        calls.initialise().catchError(
          (Object e) => notice('Calls unavailable: $e'),
        ),
      );
      unawaited(
        notifications.initialise().catchError(
          (Object e) => notice('Notifications unavailable: $e'),
        ),
      );
    }
  }

  void rememberDraft(String? key, TextEditingController controller) {
    if (key == null || switchingDraft) return;
    drafts[key] = controller.value;
    draftStore.put(
      key,
      controller.text,
      (e) => notice('Could not save draft: $e'),
    );
  }

  Future<void> finishDraft(
    String? key,
    String submitted, {
    bool notes = false,
  }) async {
    if (key == null) return;
    if (drafts[key]?.text == submitted) {
      drafts[key] = TextEditingValue.empty;
      draftStore.put(key, '', (e) => notice('Could not save draft: $e'));
    }
    if (mounted && key == (notes ? notesComposerContext : composerContext)) {
      final controller = notes ? inboxComposer : composer;
      if (controller.text == submitted) controller.clear();
    }
    await draftStore.flush();
  }

  // Values derived from local history, shared by every row of one build and
  // by lazily built list rows until the next state change.
  final _memo = <String, Object?>{};
  T memo<T>(String key, T Function() compute) =>
      _memo.containsKey(key) ? _memo[key] as T : _memo[key] = compute();

  @override
  void setState(VoidCallback fn) {
    _memo.clear();
    super.setState(fn);
  }

  void update(VoidCallback action) {
    if (mounted) {
      setState(() {
        final previousRoom = activeRoom?.object.id;
        action();
        // Filters, drag feedback and delivery labels do not change the data.
        // Keep the loaded items when only presentation state changes.
        if (previousRoom != activeRoom?.object.id) everydayView = null;
        node.store.set(
          'lastDestination',
          [4, 7].contains(tab)
              ? 8
              : tab == 5
              ? 2
              : tab,
        );
      });
    }
  }

  void redraw() {
    if (mounted) setState(() {});
  }

  void refresh() {
    if (!mounted) return;
    setState(() {});
    if (widget.enablePlatform) {
      final ringing = calls.phase == 'ringing';
      if (ringing != _ringing) {
        _ringing = ringing;
        unawaited(
          (ringing ? notifications.incomingCall() : notifications.clearCall())
              .catchError((Object e) => notice('$e')),
        );
      }
      final count = unread('post') + unread('message');
      if (count != _badgeCount) {
        _badgeCount = count;
        unawaited(AppBadgePlus.updateBadge(count).catchError((Object _) {}));
      }
    }
  }

  void notice(String text) {
    messenger.currentState?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> act(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      notice('$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> attachmentAct(Future<void> Function() action) async {
    if (addingAttachment) return;
    setState(() => addingAttachment = true);
    try {
      await action();
    } catch (e) {
      if (mounted) notice('$e');
    } finally {
      if (mounted) setState(() => addingAttachment = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.enablePlatform) {
      if (state == AppLifecycleState.resumed) {
        performance.start();
      } else {
        performance.stop();
      }
    }
    if (state != AppLifecycleState.resumed) {
      unawaited(
        draftStore.flush().catchError(
          (Object e) => notice('Could not save draft: $e'),
        ),
      );
    }
    if (state == AppLifecycleState.resumed && widget.enablePlatform) {
      // Speech settings may have changed outside the app.
      folderSync.schedule();
      unawaited(speech.checkLive());
      unawaited(shareInbox?.drain());
      noteWidgets?.schedule();
      unawaited(
        network.start().catchError((Object e) => notice('Sync will retry: $e')),
      );
    }
    // A deliberate low-power default: no background relay work on a sleeping
    // phone. Incoming calls while suspended need a future wakeup integration.
    // An open invitation keeps the connection so a friend or new device can
    // be approved after sending the invitation from another app; networking
    // still stops once it expires.
    _pausedStop?.cancel();
    if (state == AppLifecycleState.paused && calls.phase == 'idle') {
      final open =
          network.friendInvitation?.available == true ||
          network.pairing?.available == true;
      if (!open) {
        unawaited(network.stop());
      } else {
        final expires = [
          network.friendInvitation?.expires,
          network.pairing?.expires,
        ].whereType<DateTime>().reduce((a, b) => a.isAfter(b) ? a : b);
        _pausedStop = Timer(
          expires.difference(DateTime.now()) + const Duration(seconds: 5),
          () {
            if (calls.phase == 'idle') unawaited(network.stop());
          },
        );
      }
    }
  }

  @override
  void dispose() {
    unawaited(draftStore.flush().catchError((Object _) {}));
    WidgetsBinding.instance.removeObserver(this);
    _pausedStop?.cancel();
    _changes?.cancel();
    _dataRefresh.close();
    for (final controller in conversationScroll.values) {
      controller.dispose();
    }
    _deliveryRefresh.close();
    imports.dispose();
    performance.stop();
    everydaySync.close();
    shareInbox?.close();
    noteWidgets?.close();
    reminders?.close();
    speech
      ..removeListener(refresh)
      ..close();
    notesSearchFocus.dispose();
    network.removeListener(refresh);
    calls.removeListener(refresh);
    if (widget.enablePlatform) unawaited(calls.close());
    unawaited(network.stop());
    unawaited(driveSync.close());
    unawaited(folderSync.close());
    unawaited(notifications.close());
    inboxComposer.dispose();
    listName.dispose();
    composer.dispose();
    search.dispose();
    notesSearch.dispose();
    fileSearch.dispose();
    super.dispose();
  }

  String short(String id) => id.length > 12
      ? '${id.substring(0, 8)}…${id.substring(id.length - 4)}'
      : id;
  String name(String person) =>
      memo('names', () {
        final names = <String, String>{};
        // Newest first; keep the latest visible profile per person.
        for (final o in node.store.objects(kind: 'profile', limit: 1000)) {
          if (o.isPublic && node.visible(o)) {
            names.putIfAbsent(o.author, () => o.data['payload']['name']);
          }
        }
        return names;
      })[person] ??
      (person == node.person ? 'You' : short(person));

  List<String> get people => node.contacts.values
      .map((c) => c.person)
      .toSet()
      .where((p) => p != node.person)
      .toList();

  /// Visible unread objects of [kind], queried once per build.
  List<SignedObject> unreadObjects(String kind) => memo(
    'unread/$kind',
    () => node.store.unread(kind, node.person).where(node.visible).toList(),
  );
  int unread(String kind) => kind == 'message'
      ? node.store.conversationUnread(node.person, blocked: node.blocked)
      : unreadObjects(
          kind,
        ).where((o) => o.isPublic || o.audience.contains(node.person)).length;

  /// Recent objects of [kind] grouped by space, once per build.
  Map<String, List<SignedObject>> objectsBySpace(String kind) =>
      memo('spaces/$kind', () {
        final result = <String, List<SignedObject>>{};
        for (final o in node.store.objects(kind: kind)) {
          (result[o.space] ??= []).add(o);
        }
        return result;
      });
  Future<String?> ask(
    BuildContext context,
    String title, {
    String initial = '',
    String hint = '',
    int lines = 1,
  }) async {
    final input = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: input,
            autofocus: true,
            minLines: lines,
            maxLines: lines == 1 ? 1 : 8,
            decoration: InputDecoration(hintText: hint),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // Dialog route animations can still hold its text field briefly.
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    return result;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: noteNavigator,
    debugShowCheckedModeBanner: false,
    scaffoldMessengerKey: messenger,
    title: 'OurNet',
    theme: ThemeData(
      useMaterial3: true,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Color(accent),
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      cardTheme: const CardThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        elevation: 0,
        margin: EdgeInsets.symmetric(vertical: 6),
      ),
    ),
    home: Builder(
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 850;
          final navigation = Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(24, 28, 24, 4),
                      child: Text(
                        'OurNet',
                        style: TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
                      child: Text('Your things. Your people.'),
                    ),
                    for (final i in [9, 2, 10, 1, 3])
                      ListTile(
                        leading: Icon(icons[i]),
                        title: Text(titles[i]),
                        trailing: i == 1 || i == 2
                            ? Badge.count(
                                count: unread(i == 1 ? 'post' : 'message'),
                                isLabelVisible:
                                    unread(i == 1 ? 'post' : 'message') > 0,
                              )
                            : null,
                        selected: tab == i,
                        onTap: () {
                          update(() {
                            tab = i;
                            if (i == 9 || i == 10) activeRoom = null;
                            showConversation = false;
                            showForum = false;
                            everydayView = null;
                            replyTo = null;
                          });
                          if (!wide) Navigator.pop(context);
                        },
                      ),
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                selected: [8, 4, 7].contains(tab),
                onTap: () {
                  update(() => tab = 8);
                  if (!wide) Navigator.pop(context);
                },
              ),
            ],
          );
          final back = backDestination();
          return PopScope(
            canPop: back == null,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) update(back ?? () {});
            },
            child: Scaffold(
              appBar: AppBar(
                leading: [4, 5, 7].contains(tab)
                    ? BackButton(
                        onPressed: () => update(() => tab = tab == 5 ? 2 : 8),
                      )
                    : null,
                title: Text(
                  activeProfile == 'main'
                      ? titles[tab]
                      : '${titles[tab]} · $activeProfile',
                ),
                actions: [
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  if (wide)
                    TextButton.icon(
                      onPressed: busy
                          ? null
                          : () => act(() async {
                              if (network.running) {
                                await network.syncAll();
                              } else {
                                await network.start();
                              }
                            }),
                      icon: Icon(
                        network.running ? Icons.sync : Icons.power_settings_new,
                      ),
                      label: Text(network.running ? 'Sync now' : 'Connect'),
                    ),
                  if (!wide)
                    IconButton(
                      tooltip: network.running ? 'Sync now' : 'Connect',
                      onPressed: busy
                          ? null
                          : () => act(
                              network.running ? network.syncAll : network.start,
                            ),
                      icon: Icon(
                        network.running ? Icons.sync : Icons.power_settings_new,
                      ),
                    ),
                  if (wide)
                    IconButton(
                      tooltip: 'Toggle theme',
                      onPressed: () {
                        setState(() => dark = !dark);
                        node.store.set('dark', dark);
                      },
                      icon: Icon(dark ? Icons.light_mode : Icons.dark_mode),
                    ),
                  IconButton(
                    tooltip: 'Search everything',
                    onPressed: () => update(() => tab = 11),
                    icon: const Icon(Icons.search),
                  ),
                  if (wide)
                    IconButton(
                      tooltip: 'Your profile',
                      onPressed: () => update(() => tab = 7),
                      icon: const Icon(Icons.account_circle_outlined),
                    ),
                  const SizedBox(width: 12),
                ],
              ),
              drawer: wide ? null : Drawer(child: navigation),
              body: Row(
                children: [
                  if (wide) SizedBox(width: 244, child: navigation),
                  if (wide) const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      children: [
                        if (calls.phase != 'idle') callPanel(),
                        ValueListenableBuilder(
                          valueListenable: imports,
                          builder: (context, jobs, _) {
                            if (jobs.isEmpty) return const SizedBox.shrink();
                            final completed = jobs.values.fold(
                              0,
                              (n, j) => n + j.completed,
                            );
                            final total = jobs.values.fold(
                              0,
                              (n, j) => n + j.total,
                            );
                            return Column(
                              children: [
                                LinearProgressIndicator(
                                  value: total == 0 ? null : completed / total,
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(
                                    'Saving ${jobs.length == 1 ? 'attachment' : '${jobs.length} attachments'} locally…',
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.all(wide ? 24 : 12),
                            child: page(context),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: InkWell(
                            onTap: () => update(() => tab = 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: SyncHealthLine(network: network),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Network settings',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );

  /// Where Android back goes inside the app, or null to leave it from Notes.
  VoidCallback? backDestination() {
    if ([4, 5, 7].contains(tab)) return () => tab = tab == 5 ? 2 : 8;
    if (tab == 10 && activeRoom != null) return () => activeRoom = null;
    if (tab == 2 && showConversation) return () => showConversation = false;
    if (tab == 1 && showForum) return () => showForum = false;
    if (tab != 9) {
      return () {
        tab = 9;
        activeRoom = null;
      };
    }
    return null;
  }

  Widget page(BuildContext context) => switch (tab) {
    0 => everydayPage(context),
    1 => communities(context),
    2 => messages(context),
    3 => filePage(context),
    4 => networkPage(context),
    5 => locations(context),
    6 => voting(context),
    7 => profile(context),
    9 => everydayPage(context),
    10 => groupsPage(context),
    11 => searchPage(context),
    _ => settings(context),
  };
  Widget empty(String title, String detail, IconData icon) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 48, color: Colors.teal),
        const SizedBox(height: 16),
        Text(
          title,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(detail, textAlign: TextAlign.center),
      ],
    ),
  );
  Widget callPanel() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${calls.phase} · ${calls.peer == null ? '' : name(node.contacts[calls.peer]?.person ?? calls.peer!)}',
                ),
              ),
              if (calls.phase == 'ringing')
                FilledButton(
                  onPressed: () => act(calls.answer),
                  child: const Text('Answer'),
                ),
              IconButton(
                tooltip: 'Mute microphone',
                onPressed: calls.mute,
                icon: Icon(calls.muted ? Icons.mic_off : Icons.mic),
              ),
              IconButton(
                tooltip: 'Hang up',
                onPressed: () => act(calls.hangup),
                icon: const Icon(Icons.call_end, color: Colors.red),
              ),
            ],
          ),
          if (calls.error != null) Text(calls.error!),
          if (calls.phase == 'connected')
            SizedBox(
              height: 180,
              child: Row(
                children: [
                  Expanded(child: RTCVideoView(calls.remote)),
                  SizedBox(
                    width: 120,
                    child: RTCVideoView(calls.local, mirror: true),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

class NetworkPainter extends CustomPainter {
  final String person;
  final List<DeviceCertificate> contacts;
  NetworkPainter(this.person, this.contacts);
  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = Colors.teal.withValues(alpha: .3)
      ..strokeWidth = 2;
    final total = contacts.length.clamp(1, 100);
    for (var i = 0; i < contacts.length && i < 100; i++) {
      final point = Offset(
        24 + (size.width - 48) * (i + .5) / total,
        i.isEven ? 35 : size.height - 35,
      );
      canvas.drawLine(centre, point, paint);
      canvas.drawCircle(point, 9, Paint()..color = Colors.teal);
    }
    canvas.drawCircle(centre, 22, Paint()..color = Colors.teal);
    final text = TextPainter(
      text: const TextSpan(
        text: 'You',
        style: TextStyle(color: Colors.white, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, centre - Offset(text.width / 2, text.height / 2));
  }

  @override
  bool shouldRepaint(covariant NetworkPainter oldDelegate) => true;
}
