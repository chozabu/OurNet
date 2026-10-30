import 'header_when_room.dart';
import 'app_notice.dart';
import 'chat_composer.dart';
import 'conversation_history.dart';
import 'conversation_search.dart';
import 'chat_bubble.dart';
import 'message_text.dart';
import '../services/relay_conditions.dart';
import '../services/noise_suppression.dart';
import '../services/typing.dart';
import '../services/windows_tun.dart';
import '../services/remote_desktop.dart';
import '../services/location_share.dart';
import '../services/map_tiles.dart';
import 'map_page.dart';
import 'place_links.dart';
import 'plugin_view.dart';
import 'wall_page.dart';
import 'transfers_view.dart';
import 'plugins_page.dart';
import 'remote_session_banner.dart';
import 'storage_page.dart';
import 'stats_page.dart';
import '../controllers/notes_home_controller.dart';
import '../controllers/conversation_controller.dart';
import '../services/background_sync.dart';
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
import '../services/clipboard_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:ournet_core/ournet_core.dart';
import 'package:ournet_transport/ournet_transport.dart'
    show
        DriveSync,
        FirstSyncChoice,
        FirstSyncItem,
        FirstSyncKind,
        FirstSyncPlan,
        FolderSync,
        FriendRelayPolicy,
        plainError;
import '../services/network.dart';
import '../services/files.dart';
import '../services/calls.dart';
import '../services/group_calls.dart';
import 'group_call_screen.dart';
import 'call_screen.dart';
import '../services/ringer.dart';
import '../services/messaging.dart';
import '../services/notifications.dart';
import '../services/connection_service.dart';
import '../services/system_tray.dart';
import '../services/undelivered.dart';
import '../services/wake.dart';
import '../services/session.dart';
import 'inline_image.dart';
import 'image_viewer.dart';
import 'friend_invite.dart';
import '../build_info.dart';
import 'add_device.dart';
import 'recovery_phrase.dart';
import 'onboarding.dart';
import 'sync_status.dart';
import 'sync_health.dart';
import 'update_banner.dart';
import 'storage_banner.dart';
import 'network_graph.dart';
import 'conversation_delivery.dart';
import 'note_editor.dart';
import 'forum_thread.dart';
import 'note_card.dart';
import 'note_colors.dart';
import 'keep_import.dart';
import 'backup.dart';
import 'package:animations/animations.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../services/note_widgets.dart';
import '../services/reminders.dart';
import '../services/calendar_reminders.dart';
import '../controllers/calendar_controller.dart';
import 'calendar_dates.dart' show eventTitle, daysBetween, dateKey;
import 'calendar_flows.dart';
import 'calendar_page.dart';
import 'event_links.dart';
import 'chat_links.dart';
import 'object_links.dart';
import '../services/speech.dart';
import 'drawing.dart';
import 'avatar.dart';
import 'avatar_editor.dart';
import 'note_markup.dart';
import 'note_organise.dart';
import 'speech_settings.dart';
import 'voice_recorder.dart';
import 'note_attachments.dart' show AudioClip;
import 'package:image_picker/image_picker.dart';

export '../controllers/notes_home_controller.dart' show notesPage, NotesView;

part 'home.dart';
part 'first_sync_review.dart';
part 'everyday.dart';
part 'group_chat.dart';
part 'group_forum.dart';
part 'group_notes.dart';
part 'calendar_screens.dart';
part 'social.dart';
part 'conversation.dart';
part 'objects.dart';
part 'network.dart';
part 'map_flows.dart';
part 'contact_details.dart';
part 'voting.dart';
part 'settings.dart';
part 'drive.dart';
part 'discovery.dart';
part 'group_members.dart';
part 'forum_features.dart';
part 'notes_home.dart';
part 'activity.dart';
part 'scopes.dart';
part 'public_chat.dart';
part 'browse.dart';
part 'wall_section.dart';

/// Places in the app. [id] is saved as the last destination; keep it stable.
enum Destination {
  forums(1, 'Forums', Icons.forum_outlined),
  messages(2, 'Chat', Icons.chat_bubble_outline),
  files(3, 'Files', Icons.folder_outlined),
  network(4, 'Network', Icons.hub_outlined),
  locations(5, 'Locations', Icons.map_outlined),
  voting(6, 'Voting', Icons.how_to_vote_outlined),
  profile(7, 'Profile', Icons.person_outline),
  settings(8, 'Settings', Icons.settings_outlined),
  notes(9, 'Notes', Icons.note_alt_outlined),
  groups(10, 'Groups', Icons.people_outline),
  search(11, 'Search', Icons.search),
  calendar(12, 'Calendar', Icons.calendar_month_outlined),
  maps(13, 'Maps', Icons.map_outlined),
  storage(14, 'Storage', Icons.storage),
  stats(15, 'Network stats', Icons.insights),
  activity(16, 'Activity', Icons.dynamic_feed_outlined),

  /// A plugin's section: which one is [_OurNetAppState.pluginSection].
  plugin(17, 'Plugin', Icons.extension_outlined),
  plugins(18, 'Plugins', Icons.extension_outlined);

  final int id;
  final String title;
  final IconData icon;
  const Destination(this.id, this.title, this.icon);

  /// The main navigation list, in order. Groups are not a place of their
  /// own: picking one as the scope shows its content in these (docs/SCOPES.md).
  static const navigation = [
    activity,
    notes,
    calendar,
    maps,
    messages,
    forums,
    files,
  ];

  /// The content this destination shows, filtered by the scope; null for
  /// places that ignore the scope (settings, search…).
  ScopedSection? get section => switch (this) {
    notes => ScopedSection.notes,
    calendar => ScopedSection.calendar,
    maps => ScopedSection.maps,
    messages => ScopedSection.chat,
    forums => ScopedSection.forums,
    files => ScopedSection.files,
    activity => ScopedSection.activity,
    _ => null,
  };

  /// Where back leads from a sub-page, which is also what is remembered.
  Destination? get parent => switch (this) {
    network || profile || storage || stats || plugins => settings,
    locations => messages,
    _ => null,
  };
}

class OurNetApp extends StatefulWidget {
  final Node node;
  final bool enablePlatform;
  final Destination? initialTab;
  final Future<({String path, String name})?> Function()? pickAttachment;

  /// Replaces the platform image picker in note editors (tests).
  final Future<XFile?> Function(ImageSource source)? pickImage;

  /// Replaces the platform folder picker for folder sync (tests).
  final Future<String?> Function()? pickFolder;
  const OurNetApp({
    super.key,
    required this.node,
    this.enablePlatform = true,
    this.initialTab,
    this.pickAttachment,
    this.pickImage,
    this.pickFolder,
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
  CalendarReminders? calendarReminders;

  /// The calendar, set up when first needed (the Calendar screen, a link to
  /// an event, or reminders): reading its history costs time on a large
  /// profile, and most sessions never ask.
  CalendarController? calendarControllerOrNull;
  final groupCalendars = <String, CalendarController>{};

  /// Sent messages without receipts; only where this isolate owns the
  /// profile (Android).
  Undelivered? undelivered;

  /// Push wake-up: this phone's registration (Android, where this isolate
  /// owns the profile), and waking friends' phones (everywhere).
  WakeRegistration? wakeRegistration;
  WakeSender? wakeSender;
  Undelivered? _wakeUndelivered;
  bool savingNote = false;
  Future<List<DriveEntry>>? driveView;
  String? driveFolder;
  bool publicFiles = false;
  late final Calls calls;
  late final GroupCalls groupCalls;
  bool callScreenOpen = false;

  /// Whether the one-to-one call screen is showing.
  bool directCallOpen = false;
  String _callPhase = 'idle';
  String? _callError;
  final ringer = Ringer();

  /// Group names by space, for the call bar; filled as membership is looked up.
  final groupNames = <String, String>{};
  late final Notifications notifications;

  /// Whether OurNet starts into the tray at sign-in (Windows, main profile).
  bool? startsWithWindows;
  StreamSubscription<void>? _changes;
  late final CoalescedTask _dataRefresh;

  /// Hands this person's other devices the keys to what they cannot read:
  /// history from before a device was added, and messages from friends who
  /// have not yet heard of it. Each pass covers only what arrived since.
  CoalescedTask? _keyGrants;

  /// Keeps this person's adverts for the public forums and chats they follow
  /// in step with what they follow: see [Listings].
  CoalescedTask? _listings;
  Timer? _listingsRenewal;
  String _listingsKey = '';

  /// Publishes who this person is connected to when that changes.
  CoalescedTask? _friendList;

  /// What happened lately (docs/ACTIVITY.md), kept current as things arrive.
  late final Activity activity = Activity(node, notes: notes);
  late final CoalescedTask _activityRefresh;
  StreamSubscription<Set<String>>? _activityChanges;

  /// Followed walls merged (docs/WALL.md): the posts Activity shows as cards.
  late final WallFeed wallFeed = WallFeed(node);
  bool wallLoadingMore = false;
  late final CoalescedTask _wallRefresh;
  StreamSubscription<Set<String>>? _wallChanges;

  /// The activity feed's sections switched off, saved.
  Set<ActivitySection> activityHidden = {ActivitySection.chat};
  bool activityLoadingMore = false;

  /// Arrivals seen before the Activity page was opened: rows after it stay
  /// marked new while the page is open. Cleared on leaving it.
  int? activityFloor;

  /// Folds the people members added into the records of groups this person
  /// owns: see [Everyday.settleInvites].
  CoalescedTask? _groupInvites;

  /// People asking to connect, read with the other data.
  List<ConnectRequest> connectRequests = const [];
  bool _offeringHistory = false;

  /// Recovery phrase changes made on other devices: see [offerRootChange].
  StreamSubscription<Set<String>>? _rootCopies;
  bool _offeringRootChange = false;
  int _rootChangeOffered = 0;
  late final CoalescedTask _deliveryRefresh;
  bool addingAttachment = false;
  final imports = ValueNotifier<Map<Object, ({int completed, int total})>>({});
  final performance = PerformanceMonitor(idleAfter: const Duration(seconds: 3));
  int _badgeCount = -1;
  bool _ringing = false;

  /// The call state Android was last told (see [_sendCallState]).
  String? _callState;
  Timer? _pausedStop;
  final messenger = GlobalKey<ScaffoldMessengerState>();
  final noteNavigator = GlobalKey<NavigatorState>();
  Destination tab = Destination.notes;
  bool showConversation = false;
  bool showForum = false;
  bool attachmentFiles = false;
  late final NotesHomeController personalNotesController;
  late final NotesHomeController groupNotesController;

  /// The group whose notes are on screen, or null for a person's own. The
  /// notes screen is shared: it filters, searches and selects within
  /// whichever of the two is showing.
  String? get notesScope => tab == Destination.notes && activeRoom != null
      ? activeRoom!.object.space
      : null;
  NotesHomeController get notesController =>
      notesScope == null ? personalNotesController : groupNotesController;
  final roomChecks = <String, bool>{};
  String fileQuery = '';
  final fileSearch = TextEditingController();
  String fileSort = 'Newest';
  String searchScope = 'All';
  Future<List<_SearchHit>>? searchIndex;

  /// The group picked as the scope: the scoped destinations show its
  /// content. See docs/SCOPES.md.
  EverydayItem? activeRoom;

  /// The scope when no group is picked: null is All.
  ScopeKind? viewScope;

  /// A group whose chat or forum is open beside a list in another scope (a
  /// group's chat among All's conversations), without making it the scope.
  EverydayItem? listRoom;

  late final PublicChats publicChats;
  late final Listings listings;

  /// Installed plugins; null where they cannot run (tests, in-memory
  /// profiles). See docs/PLUGINS.md.
  Plugins? plugins;
  RemoteDesktops? _desktops;

  /// The plugin section open, for [Destination.plugin].
  PluginSection? pluginSection;

  /// An object of [pluginSection]'s plugin to show, from search or the
  /// activity feed; its page is told once.
  String? pluginObject;
  StreamSubscription<PluginNotice>? _pluginNotices;
  StreamSubscription<PluginOffered>? _pluginOffers;
  StreamSubscription<void>? _pluginSections;

  /// Programs on this computer reaching plugins granted `local` (git).
  LocalBridge? _localBridge;
  StreamSubscription<String>? _localBridgeSync;

  /// The public chat open in Chat, instead of a direct conversation.
  String? publicChat;
  final publicComposer = TextEditingController();
  final publicFocus = FocusNode();

  /// Per public chat: how many of its newest messages are shown.
  final publicChatLimit = <String, int>{};

  /// Messages shown per public chat and limit, read once per change.
  final publicMessages = <String, List<ChatMessage>>{};

  /// In All, the group new notes go to; null is Personal.
  String? allNotesTarget;

  /// The groups as last read, for naming them where they are listed among
  /// other things (a group's notes in All).
  List<EverydayItem> knownRooms = const [];

  /// Unseen items per kind and space, for the scope lists' badges. Counted
  /// from where reading got to, and kept until data arrives or something is
  /// marked read.
  final unreadCounts = <String, int>{};

  /// The newest object per kind and space, for ordering groups among
  /// conversations; kept like [unreadCounts].
  final latestItems = <String, SignedObject?>{};
  Future<List<EverydayItem>>? everydayView;
  Future<List<EverydayItem>>? roomsView;

  /// Members' requests to add people, per group space; see [groupAddRequests].
  final addRequestsView = <String, Future<List<AddRequest>>>{};
  Future<List<(EverydayItem, String)>>? attachmentsView;
  final inboxComposer = TextEditingController();
  final inboxFocus = FocusNode();
  final groupChatScroll = ScrollController();

  bool inboxDragging = false;
  bool dark = false, busy = false;
  bool compact = false;
  int accent = 0xff137d72;

  /// Stands in for a forum id while the forums tab shows the latest
  /// discussions from every subscribed forum. Underscore ids are never forums.
  static const allForums = '_all';
  String space = 'general';
  String? selectedThread;
  String? contact;
  String? replyTo;
  final submittedForumThreads = <String>{};
  final composer = TextEditingController();
  final composerFocus = FocusNode();
  bool switchingDraft = false;
  late final DraftStore draftStore;
  final drafts = <String, TextEditingValue>{};
  String? composerContext;
  String? notesComposerContext;
  final deliveryLabels = <String, String>{};

  /// Devices seen to have received each item, and how far the receipts have
  /// been consumed. See `loadDeliveryLabels`.
  final deliveryDevices = <String, Set<String>>{};
  int deliveryCursor = 0;

  /// Every stored object of [kinds], newest first, a page at a time.
  ///
  /// Search has no index to narrow it, so it does have to look at the whole
  /// of history; what it must not do is read all of it at once, or read a
  /// fixed slice and present the result as though it were everything.
  Stream<SignedObject> scanHistory(List<String> kinds) async* {
    final slice = TimeSlice();
    (int, String)? after;
    while (true) {
      final page = node.store.objects(kinds: kinds, after: after, limit: 256);
      if (page.isEmpty) return;
      for (final object in page) {
        after = (object.created, object.id);
        await slice.pause();
        yield object;
      }
    }
  }

  late final ConversationController conversations;
  late final MessageUpdates messageUpdates;
  late final ForumVotes forumVotes;
  late final Typing typing;
  late final LocationShare locationShare;
  late final MapTiles mapTiles;
  final messageErrors = <String, String>{};

  /// Per conversation: messages shown at once while they are being saved
  /// and sent, in order; a failed one stays with its error until retried.
  final outgoing = <String, List<OutgoingMessage>>{};
  final _sendChains = <String, Future<void>>{};

  /// Per conversation: the message being replied to, or edited.
  final messageReply = <String, String>{};
  final messageEdit = <String, String>{};

  /// The open group's chat: a window onto its newest messages that grows
  /// backwards as the reader scrolls. Replaced when another group opens.
  RoomFeed? roomFeed;
  bool roomFeedReady = false;
  bool roomFeedLoadingOlder = false;
  Object? roomFeedError;

  /// Per group: the entry being replied to, or edited.
  final groupReply = <String, String>{};
  final groupEdit = <String, String>{};
  final groupKeys = <String, GlobalKey>{};

  /// The open group's forum, read once and kept current.
  RoomForum? roomForum;
  final allGroupForums = <String, RoomForum>{};
  Map<String, int> allGroupTopicTimes = const {};
  Future<List<SignedObject>>? allGroupTopics;
  Future<List<SignedObject>>? allGroupLoading;
  bool roomForumReady = false;
  Object? roomForumError;

  /// Per group (by room ID): the open discussion and the post being replied to.
  final groupThreads = <String, String>{};

  /// Per group (by room ID): lists from before groups had notes, found by a
  /// one-time read of the group, offered for import as notes.
  final groupLists = <String, List<EverydayItem>>{};
  final groupReplies = <String, String>{};

  /// Posts whose replies are folded away in the open discussion.
  final collapsedPosts = <String>{};

  /// How forum discussions are ordered: 'hot', 'new' or 'top'.
  String get forumSort => switch (node.store.setting('forumSort')) {
    'new' => 'new',
    'top' => 'top',
    _ => 'hot',
  };
  final groupDraftBeforeEdit = <String, TextEditingValue>{};

  /// Messages chosen in selection mode, in the open conversation.
  final selectedMessages = <String>{};
  String? highlightedMessage;
  bool searchingConversation = false;

  /// Whether a new profile picture is being compressed and published.
  bool savingAvatar = false;

  /// The network page's friend search and filter.
  final networkSearch = TextEditingController();

  /// The Settings page's own search, open while [settingsSearching].
  final settingsSearch = TextEditingController();
  bool settingsSearching = false;
  String networkFilter = 'all';
  bool showArchivedChats = false;
  bool showChatRequests = false;

  /// The oldest message unread when [unreadMarkerPeer]'s chat was opened.
  String? unreadMarkerPeer, unreadMarker;

  /// Messages seen on screen, marked read together after a short pause.
  final _pendingReads = <String>{};
  Timer? _readTimer;

  /// Per conversation: what adding attachments is doing.
  final attachProgress = <String, String>{};
  bool chatDragging = false;
  String _typedText = '';

  /// The draft set aside while a sent message is being edited.
  final _draftBeforeEdit = <String, TextEditingValue>{};

  /// Per conversation: what a voice message being prepared is doing.
  final voiceProgress = <String, String>{};
  final fileProgress = <String, double>{};

  /// Bumped as downloads advance, so only their progress labels redraw.
  final fileProgressTick = ValueNotifier(0);

  /// [build] from [id]'s download fraction, redrawn as it advances.
  Widget fileProgressOf(String id, Widget Function(double progress) build) =>
      ValueListenableBuilder(
        valueListenable: fileProgressTick,
        builder: (context, tick, child) => build(fileProgress[id] ?? 0),
      );
  final fileErrors = <String, String>{};
  final search = TextEditingController();

  @override
  void initState() {
    super.initState();
    groupChatScroll.addListener(groupChatScrolled);
    if (widget.enablePlatform) performance.start();
    conversations = ConversationController(node);
    messageUpdates = MessageUpdates(node);
    forumVotes = ForumVotes(node);
    draftStore = DraftStore(node);
    notes = Notes(node);
    personalNotesController = NotesHomeController(notes);
    publicChats = PublicChats(node, notes.state);
    listings = Listings(node, notes.state);
    groupNotesController = NotesHomeController(notes);
    inboxComposer.addListener(
      () => rememberDraft(notesComposerContext, inboxComposer),
    );
    composer.addListener(() => rememberDraft(composerContext, composer));
    composer.addListener(composerTyped);
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
        [
          ...Destination.navigation,
          Destination.settings,
          Destination.plugin,
        ].where((d) => d.id == saved).firstOrNull ??
        Destination.notes;
    // A test or a link that names where to open starts in All.
    if (widget.initialTab == null) restoreScope();
    dark = node.store.setting('dark') == true;
    compact = node.store.setting('compact') == true;
    notesController.notesGrid = node.store.setting('notesGrid') != false;
    accent = node.store.setting('accent') as int? ?? 0xff137d72;
    network = Network(node)..addListener(refresh);
    startPlugins();
    typing = Typing(network)..addListener(redraw);
    locationShare = LocationShare(
      network,
      state: notes.state,
      onReading: () {
        if (stayConnected) {
          unawaited(keepConnected(true).catchError((Object _) {}));
        }
      },
    )..addListener(redraw);
    final tilePath = node.store.path;
    mapTiles = MapTiles(
      TileStore(
        path: tilePath == null || !widget.enablePlatform
            ? null
            : '${tilePath.replaceFirst(RegExp(r'\.db$'), '')}-tiles.db',
      ),
      allowed: () => node.store.setting('mapOnline') != false,
    );
    // Only where the person has already allowed it: asking waits for the map.
    if (widget.enablePlatform &&
        (node.locations.sharing || node.locations.showToOwnDevices)) {
      unawaited(locationShare.start());
    }
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
    // A phone syncs large files by itself only with OurNet open and
    // charging, unless the person allows it always.
    if (widget.enablePlatform && Platform.isAndroid) {
      Files.largeTransfersAllowed = () async =>
          node.store.setting('files/largeAlways') == true ||
          (!folderSync.background && await isCharging());
    }
    calls = Calls(network)
      ..addListener(refresh)
      ..onWake = (device, kind, session) =>
          unawaited(wakeSender?.call(device, kind, session));
    groupCalls = GroupCalls(
      network,
      members: groupPeople,
      otherCallActive: () => calls.phase != 'idle',
    )..addListener(refresh);
    calls.busyElsewhere = () => groupCalls.active;
    // Rebuilding the endpoint would cut a call's signalling.
    network.canRestart = () => calls.phase == 'idle' && !groupCalls.active;
    if (widget.enablePlatform) network.relayConditions = relayConditions;
    if (widget.enablePlatform && Platform.isAndroid) {
      onNetworkChanged(network.networkChanged);
    }
    // Each call this device places goes in the chat's history.
    calls.onRecord = (record) => unawaited(
      sendCallRecord(
        node,
        record.person,
        video: record.video,
        outcome: record.outcome,
        seconds: record.seconds,
      ).then<void>((_) {}, onError: (Object e) => network.log('$e')),
    );
    notifications =
        Notifications(
            node,
            onAction: notificationActionDispatcher,
            updates: messageUpdates,
          )
          ..onError = notice
          ..showing = showingNotification
          ..onCallOpen = (action) {
            switch (action) {
              case 'answer':
                unawaited(callAct(calls.answer));
              case 'decline':
                unawaited(callAct(calls.hangup));
                return;
            }
            openCall();
          }
          ..onOpenChat = openConversation
          ..onOpenForum = openForum
          ..onOpenPublicChat = openPublicChat
          ..onOpenGroup = (space) {
            unawaited(openGroup(space));
          }
          ..onOpenEvent = (link) {
            unawaited(openEventLink(link));
          };
    _deliveryRefresh = CoalescedTask(loadDeliveryLabels, (e) => notice('$e'));
    activityHidden = restoreActivityHidden();
    _activityRefresh = CoalescedTask(() async {
      if (await activity.refresh()) redraw();
    }, (e) => notice('Activity: $e'));
    _activityChanges = node.onChangesWhere(
      activity.shows,
      _activityRefresh.schedule,
    );
    _activityRefresh.schedule();
    _wallRefresh = CoalescedTask(() async {
      if (await wallFeed.refresh()) redraw();
    }, (e) => notice('Wall: $e'));
    _wallChanges = node.onChangesTo(Walls.kinds, _wallRefresh.schedule);
    _wallRefresh.schedule();
    _dataRefresh = CoalescedTask(() async {
      await messageUpdates.catchUp();
      await forumVotes.catchUp();
      for (final person in await conversations.refreshConversations()) {
        typing.clear(person);
      }
      searchIndex = null;
      driveView = null;
      everydayView = null;
      roomsView = null;
      allGroupTopics = null;
      unreadCounts.clear();
      latestItems.clear();
      publicMessages.clear();
      attachmentsView = null;
      addRequestsView.clear();
      await refreshGroupChat();
      await refreshGroupForum();
      connectRequests = await node.connections.incoming();
      refresh();
      _deliveryRefresh.schedule();
    }, (e) => notice('$e'));
    _changes = node.changes.stream.listen((_) {
      _dataRefresh.schedule();
      _keyGrants?.schedule();
      // Only what is followed or switched off changes what is advertised.
      final key = '${node.subscriptions.length}/${notes.state.version}';
      if (key != _listingsKey) {
        _listingsKey = key;
        _listings?.schedule();
      }
      _friendList?.schedule();
      _groupInvites?.schedule();
      if (widget.enablePlatform) unawaited(offerHistory());
    });
    _deliveryRefresh.schedule();
    if (widget.enablePlatform) {
      _rootCopies = node.onChangesTo({
        Node.rootCopyKind,
      }, () => unawaited(offerRootChange()));
      unawaited(
        node.announceRootCopyOnce().catchError(
          (Object e) => network.log(
            'Could not tell your devices which recovery phrase this one uses: $e',
          ),
        ),
      );
      unawaited(offerRootChange());
    }
    unawaited(
      node.connections.incoming().then((requests) {
        if (mounted) update(() => connectRequests = requests);
      }, onError: (Object _) {}),
    );
    if (widget.enablePlatform) {
      _keyGrants = CoalescedTask(
        () async {
          await node.shareKeys();
          // Wall keys too, for a device linked since they were made.
          await node.wallKeys.shareOwn();
        },
        (e) => network.log('Could not share keys with your devices: $e'),
        delay: const Duration(seconds: 2),
      )..schedule();
      _listings = CoalescedTask(
        () => listings.refresh(),
        (e) => network.log('Could not update your public adverts: $e'),
        delay: const Duration(seconds: 20),
      )..schedule();
      // Adverts last 30 days and are renewed after 10.
      _listingsRenewal = Timer.periodic(
        const Duration(hours: 12),
        (_) => _listings?.schedule(),
      );
      _friendList = CoalescedTask(
        () => node.connections.publish(),
        (e) => network.log('Could not publish your friend list: $e'),
        delay: const Duration(seconds: 5),
      )..schedule();
      _groupInvites = CoalescedTask(
        () => Everyday(node).settleInvites(),
        (e) => network.log('Could not update your groups\' members: $e'),
        delay: const Duration(seconds: 5),
      )..schedule();
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
          update(showNotes);
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
            update(showNotes);
            notice(error ?? 'Saved to Notes');
          },
        );
        unawaited(shareInbox!.start());
        onBackgroundSync = _backgroundSync;
        profileOpened(node);
        if (ownsProfile) {
          undelivered = Undelivered(node)..start();
          wakeRegistration = WakeRegistration(node, onError: network.log)
            ..start();
          FcmChannel.listen(wakeRegistration!.tokenChanged);
          unawaited(
            keepConnected(stayConnected)
                .then((_) => checkConnectionService())
                .catchError(
                  (Object e) => network.log('Could not stay connected: $e'),
                ),
          );
        }
        unawaited(
          scheduleBackgroundSync(
            enabled: node.store.setting('backgroundSync') != false,
          ).catchError((Object e) => notice('Background sync unavailable: $e')),
        );
      }
      wakeSender = WakeSender(
        node,
        undelivered ?? (_wakeUndelivered = Undelivered(node)..start()),
        onError: network.log,
      )..start();
      if (SystemTray.supported) {
        notifications.onTap = () =>
            unawaited(SystemTray.show().catchError((Object _) {}));
        SystemTray.onClosed = _closedToTray;
        unawaited(
          SystemTray.keep(
            keepInTray,
          ).catchError((Object e) => network.log('Tray unavailable: $e')),
        );
        if (activeProfile == 'main') unawaited(_loadStartsWithWindows());
      }
      unawaited(
        speech.start().catchError(
          (Object e) => notice('Voice transcription unavailable: $e'),
        ),
      );
      reminders = NoteReminders(notes, notifications);
      notifications.onOpenNote = (id) {
        if (!mounted) return;
        update(showNotes);
        unawaited(openNote(id));
      };
      unawaited(
        reminders!.start().catchError(
          (Object e) => notice('Reminders unavailable: $e'),
        ),
      );
      // Event reminders wait a moment so opening the app is not slowed by
      // reading the calendar.
      unawaited(
        Future<void>.delayed(const Duration(seconds: 4), () async {
          if (!mounted) return;
          calendarReminders = CalendarReminders(
            calendarController,
            notifications,
          );
          await calendarReminders!.start();
        }).catchError((Object e) => notice('Event reminders unavailable: $e')),
      );
      unawaited(
        calls.initialise().catchError(
          (Object e) => notice('Calls unavailable: $e'),
        ),
      );
      unawaited(
        notifications
            .initialise()
            // Not when Android started OurNet to stay connected, with no
            // screen to ask on; the first resume asks instead.
            .then(
              (_) => foreground ? notifications.requestPermissionOnce() : null,
            )
            .catchError((Object e) => notice('Notifications unavailable: $e')),
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
        final previousRoom = activeRoom?.object.id, previousTab = tab;
        final previousScope = viewScope;
        final previousPlugin = pluginSection?.id;
        action();
        if (previousScope != viewScope ||
            previousRoom != activeRoom?.object.id) {
          rememberScope();
        }
        // All and Personal list different notes.
        if (previousScope != viewScope) everydayView = null;
        // Filters, drag feedback and delivery labels do not change the data.
        // Keep the loaded items when only presentation state changes.
        if (previousRoom != activeRoom?.object.id) {
          everydayView = null;
          // The scope header checks the group against these.
          roomsView = null;
        }
        if (tab == Destination.plugin &&
            (tab != previousTab || pluginSection?.id != previousPlugin)) {
          node.store.set('lastPluginSection', pluginSection?.id);
        }
        if (tab != previousTab) {
          node.store.set('lastDestination', (tab.parent ?? tab).id);
          unreadMarkerPeer = null;
          selectedMessages.clear();
        }
      });
    }
  }

  /// Whether the app is showing what a notification [payload] would open.
  bool showingNotification(String payload) =>
      foreground &&
      switch (tab) {
        Destination.messages when openRoom != null =>
          payload == 'group:${openRoom!.object.space}',
        Destination.messages when publicChat != null =>
          payload == 'pubchat:$publicChat',
        Destination.messages => payload == 'chat:$contact',
        Destination.forums => activeRoom == null && payload == 'forum:$space',
        _ => false,
      };

  /// Clears the notification for the chat or forum on screen.
  void dismissShownNotification() {
    final payload = switch (tab) {
      Destination.messages when openRoom != null =>
        'group:${openRoom!.object.space}',
      Destination.messages when publicChat != null => 'pubchat:$publicChat',
      Destination.messages when contact != null => 'chat:$contact',
      Destination.forums when activeRoom == null => 'forum:$space',
      _ => null,
    };
    if (payload != null && widget.enablePlatform) {
      unawaited(notifications.dismiss(payload).catchError((Object _) {}));
    }
  }

  void openConversation(String person) {
    if (!canChat(person)) return;
    // Opening a chat with new messages (e.g. from a notification) shows them:
    // a retained scroll position or held-back arrivals would hide them, and
    // unseen messages are never built, so never marked read.
    final hasNew = node.store.conversationUnread(node.person, peer: person) > 0;
    update(() {
      if (contact != person) {
        selectedMessages.clear();
        searchingConversation = false;
      }
      if (contact != person || !showConversation) unreadMarkerPeer = null;
      if (hasNew || conversations.hasPending(person)) {
        conversations.showLatest(person);
      }
      tab = Destination.messages;
      reveal(ScopeKind.personal);
      publicChat = null;
      listRoom = null;
      contact = person;
      showConversation = true;
      replyTo = null;
      node.store.set('chatUnread/$person', null);
    });
    if (hasNew) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final scroll = conversations.scrollFor(person);
        if (scroll.hasClients) scroll.jumpTo(0);
      });
    }
    dismissShownNotification();
  }

  void openForum(String forum) {
    update(() {
      tab = Destination.forums;
      reveal(ScopeKind.public);
      listRoom = null;
      space = forum;
      selectedThread = null;
      replyTo = null;
      showForum = true;
    });
    dismissShownNotification();
  }

  /// Whether OurNet stays online while in the background (Android), in a
  /// foreground service that keeps this app running with its notification.
  bool get stayConnected =>
      Platform.isAndroid &&
      widget.enablePlatform &&
      ownsProfile &&
      node.store.setting('stayConnected') != false &&
      node.store.setting('autoConnect') != false;

  /// OurNet is meant to stay running, so the first launch turns starting
  /// with Windows on; after that it is whatever the person last chose.
  Future<void> _loadStartsWithWindows() async {
    try {
      if (node.store.setting('startupDefaulted') != true) {
        node.store.set('startupDefaulted', true);
        await SystemTray.setStartsWithWindows(
          true,
        ).catchError((Object e) => network.log('Start with Windows: $e'));
      }
      final on = await SystemTray.startsWithWindows();
      update(() => startsWithWindows = on);
    } catch (_) {}
  }

  /// Whether closing the window leaves OurNet running in the notification
  /// area (Windows, and Linux desktops that show one), online and showing
  /// notifications.
  bool get keepInTray =>
      SystemTray.hosted &&
      widget.enablePlatform &&
      node.store.setting('keepInTray') != false;

  /// Says once where OurNet went.
  void _closedToTray() {
    if (node.store.setting('trayHinted') == true) return;
    node.store.set('trayHinted', true);
    unawaited(
      SystemTray.hint(
        'OurNet is still running',
        'Messages keep arriving and notifying. Quit from this icon’s menu.',
      ).catchError((Object _) {}),
    );
  }

  /// The person's own notes, leaving a scope that does not show them.
  void showNotes() {
    tab = Destination.notes;
    reveal(ScopeKind.personal);
  }

  void redraw() {
    if (mounted) setState(() {});
  }

  void refresh() {
    if (!mounted) return;
    setState(() {});
    final phase = calls.phase;
    if (phase != _callPhase) {
      // A call starting or coming in opens the call screen.
      if (_callPhase == 'idle' && (phase == 'calling' || phase == 'ringing')) {
        WidgetsBinding.instance.addPostFrameCallback((_) => openCall());
      }
      _callPhase = phase;
    }
    if (calls.error != _callError) {
      _callError = calls.error;
      if (_callError != null && !directCallOpen) notice(_callError!);
    }
    if (widget.enablePlatform) {
      ringer.play(switch (phase) {
        'ringing' => RingSound.incoming,
        'calling' when calls.rung => RingSound.ringback,
        _ => null,
      });
      final ringing = phase == 'ringing';
      // Before the incoming-call notification, whose full-screen intent
      // needs OurNet allowed over the lock screen.
      _sendCallState();
      if (ringing != _ringing) {
        _ringing = ringing;
        if (ringing && Platform.isAndroid) unawaited(_takePushCallAction());
        if (Platform.isWindows) {
          unawaited(SystemTray.flash(ringing).catchError((Object _) {}));
        }
        unawaited(
          (ringing
                  ? notifications.incomingCall(
                      node.contacts[calls.peer]?.person,
                      video: calls.video,
                    )
                  : notifications.clearCall())
              .catchError((Object e) => notice('$e')),
        );
      }
      final count = unread('post') + unread('message');
      if (count != _badgeCount) {
        _badgeCount = count;
        unawaited(AppBadgePlus.updateBadge(count).catchError((Object _) {}));
        if (SystemTray.supported) {
          unawaited(SystemTray.unread(count).catchError((Object _) {}));
        }
      }
    }
  }

  /// Answers or declines a call as the person already did on the ringing a
  /// push wake showed before the offer arrived (see PushWake.kt).
  Future<void> _takePushCallAction() async {
    final session = calls.session;
    if (session == null) return;
    final action = await FcmChannel.callAction(
      session,
    ).catchError((Object _) => null);
    if (calls.session != session || calls.phase != 'ringing') return;
    switch (action) {
      case 'answer':
        await callAct(calls.answer);
      case 'decline':
        await callAct(calls.hangup);
    }
  }

  /// Tells Android about a call ringing, starting or ending, so it shows
  /// over the lock screen and keeps the microphone and camera while the
  /// screen is off. [force] sends it again, as on returning to OurNet,
  /// where Android grants the microphone it refused in the background.
  void _sendCallState({bool force = false}) {
    if (!Platform.isAndroid || !widget.enablePlatform) return;
    final phase = calls.phase;
    final ringing = phase == 'ringing';
    final active = (phase != 'idle' && !ringing) || groupCalls.active;
    final video = groupCalls.active || calls.video;
    final state = '$ringing $active $video';
    if (state == _callState && !force) return;
    _callState = state;
    unawaited(
      callState(
        ringing: ringing,
        active: active,
        video: video,
      ).catchError((Object e) => network.log('Call state: $e')),
    );
  }

  void notice(String text) {
    messenger.currentState?.showNotice(AppNotice(content: Text(text)));
  }

  Future<void> act(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      notice(plainError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> callAct(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) notice('Call: $e');
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

  bool get foreground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// Background work handed over while this isolate owns the profile, after
  /// its [command] was carried out: a periodic sync, staying online after
  /// sending, or a notification button. The foreground app already syncs,
  /// so only a paused app acts.
  Future<void> _backgroundSync(String command) async {
    if (foreground ||
        node.store.setting('autoConnect') == false ||
        (command == 'sync' && node.store.setting('backgroundSync') == false)) {
      return;
    }
    if (!network.running) await network.start();
    await network.syncAll();
    // Answer peers that are retrying now, as a headless run would. After
    // sending, stay while messages have not reached their recipients.
    final until = DateTime.now().add(
      command == 'linger'
          ? const Duration(minutes: 3)
          : const Duration(seconds: 10),
    );
    do {
      await Future<void>.delayed(const Duration(seconds: 5));
    } while (DateTime.now().isBefore(until) &&
        (command != 'linger' || undelivered?.any == true));
    if (mounted &&
        !stayConnected &&
        !foreground &&
        calls.phase == 'idle' &&
        !groupCalls.active &&
        network.friendInvitation?.available != true &&
        network.pairing?.available != true) {
      await network.stop();
    }
  }

  /// What Android last said about the "stay connected" service.
  ConnectionStatus? serviceStatus;

  /// Reads the service's state, and starts it again while OurNet is open
  /// when Android has stopped it, or restarted it out of sight without
  /// background location (then the position stops updating once OurNet is
  /// in the background).
  Future<void> checkConnectionService() async {
    if (!Platform.isAndroid || !widget.enablePlatform || !ownsProfile) return;
    try {
      var status = await connectionStatus();
      if (stayConnected &&
          status != null &&
          (!status.running || locationShare.active && !status.location)) {
        network.log(
          status.running
              ? 'Stay connected had no background location; restarting it'
              : 'Stay connected had stopped; restarting it',
        );
        await keepConnected(true);
        await Future<void>.delayed(const Duration(seconds: 1));
        status = await connectionStatus();
      }
      if (!mounted) return;
      serviceStatus = status;
      redraw();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Messages on screen are marked read as they are shown, which only
    // counts while the app is in front: show them again on return.
    if (state == AppLifecycleState.resumed) redraw();
    // A window that has only lost focus keeps checking at the usual pace.
    if (state != AppLifecycleState.inactive) {
      folderSync.background = state != AppLifecycleState.resumed;
    }
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
      unawaited(
        notifications.requestPermissionOnce().catchError((Object _) {}),
      );
      dismissShownNotification();
      // Speech settings may have changed outside the app.
      folderSync.schedule();
      unawaited(speech.checkLive());
      unawaited(shareInbox?.drain());
      unawaited(noteWidgets?.start());
      noteWidgets?.schedule();
      unawaited(
        network.start().catchError((Object e) => notice('Sync will retry: $e')),
      );
      unawaited(checkConnectionService());
      if (_callState != null) _sendCallState(force: true);
    }
    // A deliberate low-power default: no background relay work on a sleeping
    // phone. Incoming calls while suspended need a future wakeup integration.
    // An open invitation keeps the connection so a friend or new device can
    // be approved after sending the invitation from another app; networking
    // still stops once it expires.
    _pausedStop?.cancel();
    if (state == AppLifecycleState.paused &&
        calls.phase == 'idle' &&
        !groupCalls.active &&
        !stayConnected &&
        !keepInTray) {
      final open =
          network.friendInvitation?.available == true ||
          network.pairing?.available == true;
      // Messages not yet delivered: stay online a little longer, in a task
      // Android lets run, which stops the network when they arrive.
      final sending = undelivered?.any == true;
      if (sending) {
        unawaited(scheduleLinger().catchError((Object e) => network.log('$e')));
      }
      if (!open) {
        if (!sending) unawaited(network.stop());
      } else {
        final expires = [
          network.friendInvitation?.expires,
          network.pairing?.expires,
        ].whereType<DateTime>().reduce((a, b) => a.isAfter(b) ? a : b);
        _pausedStop = Timer(
          expires.difference(DateTime.now()) + const Duration(seconds: 5),
          () {
            if (calls.phase == 'idle' && !groupCalls.active) {
              unawaited(network.stop());
            }
          },
        );
      }
    }
  }

  @override
  void dispose() {
    unawaited(draftStore.flush().catchError((Object _) {}));
    fileProgressTick.dispose();
    _pluginNotices?.cancel();
    _pluginOffers?.cancel();
    _pluginSections?.cancel();
    _localBridgeSync?.cancel();
    unawaited(_localBridge?.close());
    _desktops?.dispose();
    unawaited(plugins?.close());
    publicComposer.dispose();
    publicFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (SystemTray.supported && widget.enablePlatform) {
      SystemTray.onClosed = null;
    }
    if (onBackgroundSync == _backgroundSync) onBackgroundSync = null;
    _pausedStop?.cancel();
    _changes?.cancel();
    _rootCopies?.cancel();
    _dataRefresh.close();
    _keyGrants?.close();
    _listings?.close();
    _listingsRenewal?.cancel();
    _friendList?.close();
    _activityChanges?.cancel();
    _activityRefresh.close();
    _wallChanges?.cancel();
    _wallRefresh.close();
    _groupInvites?.close();
    _readTimer?.cancel();
    typing
      ..removeListener(redraw)
      ..dispose();
    locationShare
      ..removeListener(redraw)
      ..dispose();
    mapTiles.dispose();
    mapTiles.store.close();
    conversations.dispose();
    _deliveryRefresh.close();
    imports.dispose();
    performance.stop();
    everydaySync.close();
    shareInbox?.close();
    noteWidgets?.close();
    reminders?.close();
    calendarReminders?.close();
    calendarControllerOrNull?.dispose();
    for (final c in groupCalendars.values) {
      c.dispose();
    }
    undelivered?.close();
    unawaited(wakeSender?.close());
    _wakeUndelivered?.close();
    wakeRegistration?.close();
    speech
      ..removeListener(refresh)
      ..close();
    notesController.dispose();
    network.removeListener(refresh);
    calls.removeListener(refresh);
    groupCalls.removeListener(refresh);
    if (widget.enablePlatform) {
      unawaited(calls.close());
      unawaited(groupCalls.close());
      unawaited(ringer.close());
    }
    unawaited(network.stop());
    unawaited(driveSync.close());
    unawaited(folderSync.close());
    unawaited(notifications.close());
    inboxComposer.dispose();
    inboxFocus.dispose();
    groupChatScroll
      ..removeListener(groupChatScrolled)
      ..dispose();
    composer.dispose();
    composerFocus.dispose();
    search.dispose();
    networkSearch.dispose();
    settingsSearch.dispose();
    fileSearch.dispose();
    super.dispose();
  }

  String short(String id) => id.length > 12
      ? '${id.substring(0, 8)}…${id.substring(id.length - 4)}'
      : id;
  String _plainName(String person) =>
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

  /// A person's name, with a note when this device is ignoring them. Blocking
  /// is per device, and a blocked friend otherwise looks like a bare
  /// identifier with no messages.
  String name(String person) {
    final base = _plainName(person);
    return node.blocked.contains(person) ? '$base (blocked)' : base;
  }

  /// Whether chat bubbles from others carry the sender's name. Group chats
  /// always do; the setting covers direct messages and defaults to on.
  bool get showSenderNames => node.store.setting('chatNames') != false;

  List<String> get people => node.contacts.values
      .map((c) => c.person)
      .toSet()
      // Someone disconnected from may still share a group, which keeps
      // their devices known; they are not offered as a friend.
      .where((p) => p != node.person && !node.forgotten.contains(p))
      .toList();

  /// Conversations with people who are not friends, read once per build:
  /// see [DistantMessages].
  List<DistantPeer> get distantPeers =>
      memo('distantPeers', node.distant.conversations);

  /// Whether a direct conversation with [person] can be shown: a friend, or
  /// someone else reached through friends.
  bool canChat(String person) =>
      people.contains(person) ||
      (node.distant.isDistant(person) &&
          !node.blocked.contains(person) &&
          !node.forgotten.contains(person));

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

  // Only these three choose the theme; the root redraws far more often.
  (bool, bool, int)? _themeKey;
  ThemeData? _themeData;
  ThemeData _theme() {
    final key = (compact, dark, accent);
    if (key == _themeKey) return _themeData!;
    _themeKey = key;
    return _themeData = ThemeData(
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
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: noteNavigator,
    builder: (context, child) => EventLinks(
      controller: () => calendarController,
      open: (context, link) => calendarFlows.openLink(context, link),
      child: ChatLinks(
        joined: (space) => publicChats.isJoined(space),
        open: followChatLink,
        child: ObjectLinks(
          joined: (space) => node.subscriptions.contains(space),
          preview: (link) => Links.preview(node, link),
          open: followObjectLink,
          child: PlaceLinks(
            open: (place) {
              noteNavigator.currentState?.push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text(place.name)),
                    body: MapPage(
                      node: node,
                      tiles: mapTiles,
                      share: locationShare,
                      nameOf: name,
                      initialPlace: place,
                      onShare: sharePlaceLink,
                    ),
                  ),
                ),
              );
            },
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    ),
    debugShowCheckedModeBanner: false,
    scaffoldMessengerKey: messenger,
    title: 'OurNet',
    theme: _theme(),
    home: Builder(
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 850;
          final navigation = Column(
            children: [
              Expanded(
                child: HeaderWhenRoom(
                  // The name gives way when the menu has to scroll.
                  header: const Padding(
                    padding: EdgeInsets.fromLTRB(24, 28, 24, 20),
                    child: Text(
                      'OurNet',
                      style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  children: [
                    for (final d in Destination.navigation)
                      ListTile(
                        leading: Icon(d.icon),
                        title: Text(d.title),
                        trailing: switch (d) {
                          Destination.forums => countBadge(forumsUnread()),
                          Destination.messages => countBadge(chatsUnread()),
                          Destination.activity => countBadge(activityUnseen()),
                          _ => null,
                        },
                        selected: tab == d,
                        onTap: () {
                          // The scope stays: the section shows its part.
                          update(() {
                            if (d != tab) activityFloor = null;
                            tab = d;
                            showConversation = false;
                            showForum = false;
                            everydayView = null;
                            replyTo = null;
                          });
                          if (!wide) Navigator.pop(context);
                        },
                      ),
                    if (pluginSections.isNotEmpty) const Divider(),
                    for (final s in pluginSections)
                      ListTile(
                        leading: Icon(pluginIcon(s.icon)),
                        title: Text(s.title),
                        selected:
                            tab == Destination.plugin &&
                            pluginSection?.id == s.id,
                        onTap: () {
                          update(() {
                            tab = Destination.plugin;
                            pluginSection = s;
                            showConversation = false;
                            showForum = false;
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
                selected: (tab.parent ?? tab) == Destination.settings,
                onTap: () {
                  update(() => tab = Destination.settings);
                  if (!wide) Navigator.pop(context);
                },
              ),
            ],
          );
          final back = backDestination();
          final title = tab == Destination.plugin
              ? pluginSection?.title ?? tab.title
              : tab.title;
          final place = activeProfile == 'main'
              ? title
              : '$title · $activeProfile';
          final syncLabel = network.running ? 'Sync now' : 'Connect';
          final syncIcon = Icon(
            network.running ? Icons.sync : Icons.power_settings_new,
          );
          final VoidCallback? sync = busy
              ? null
              : () => act(network.running ? network.syncAll : network.start);
          return PopScope(
            canPop: back == null,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) update(back ?? () {});
            },
            child: Scaffold(
              appBar: AppBar(
                // Material 3 tints the bar when any scrollable under it is
                // scrolled, so it changed colour by section (chat history
                // counts, a map never reports). It stays plain everywhere.
                notificationPredicate: (_) => false,
                leading: tab.parent == null
                    ? null
                    : BackButton(
                        onPressed: () => update(() => tab = tab.parent!),
                      ),
                title: scopedTab
                    ? scopeTitle(context, place, wide: wide)
                    : Text(place),
                actions: [
                  // A group's buttons; a phone has them under the bar.
                  if (activeRoom case final room? when wide && scopedTab) ...[
                    ...groupButtons(context, room),
                    const SizedBox(width: 8),
                  ],
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
                      onPressed: sync,
                      icon: syncIcon,
                      label: Text(syncLabel),
                    )
                  else
                    IconButton(
                      tooltip: syncLabel,
                      onPressed: sync,
                      icon: syncIcon,
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
                  if (tab == Destination.settings)
                    IconButton(
                      tooltip: settingsSearching
                          ? 'Close search'
                          : 'Search settings',
                      onPressed: () => update(() {
                        settingsSearching = !settingsSearching;
                        settingsSearch.clear();
                      }),
                      icon: Icon(
                        settingsSearching ? Icons.search_off : Icons.search,
                      ),
                    )
                  else
                    IconButton(
                      tooltip: 'Search everything',
                      onPressed: () => update(() => tab = Destination.search),
                      icon: const Icon(Icons.search),
                    ),
                  if (wide)
                    IconButton(
                      tooltip: 'Your profile',
                      onPressed: () => update(() => tab = Destination.profile),
                      icon: node.avatars.of(node.person) == null
                          ? const Icon(Icons.account_circle_outlined)
                          : conversationAvatar(node.person, radius: 14),
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
                        if (calls.phase != 'idle' && !directCallOpen)
                          CallBar(
                            calls: calls,
                            name: callPeerName(),
                            onOpen: openCall,
                            act: callAct,
                          ),
                        if (groupCalls.active && !callScreenOpen)
                          GroupCallBar(
                            calls: groupCalls,
                            title: groupCallTitle(groupCalls.space),
                            onOpen: () => openGroupCall(context),
                            onLeave: () => callAct(groupCalls.leave),
                          ),
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
                        if (plugins case final plugins?)
                          RemoteSessionBanner(plugins: plugins),
                        UpdateBanner(network: network, nameOf: name),
                        StorageBanner(
                          network: network,
                          openSettings: () =>
                              update(() => tab = Destination.settings),
                        ),
                        if (connectRequests.isNotEmpty &&
                            tab != Destination.network)
                          connectRequestsBanner(context),
                        Expanded(
                          child: Padding(
                            padding: tab == Destination.maps
                                ? EdgeInsets.zero
                                : EdgeInsets.all(wide ? 24 : 12),
                            child: scopedPage(context, wide: wide),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: InkWell(
                            onTap: () =>
                                update(() => tab = Destination.network),
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
    if (tab.parent case final parent?) return () => tab = parent;
    return switch (tab) {
      Destination.messages when showConversation && activeRoom == null => () {
        showConversation = false;
        listRoom = null;
      },
      Destination.forums when showForum && activeRoom == null => () {
        showForum = false;
        listRoom = null;
      },
      // Back unwinds the scope after the section: Notes, then All.
      Destination.notes when scope != null => () => setScope(null),
      Destination.notes => null,
      _ => () => tab = Destination.notes,
    };
  }

  Widget page(BuildContext context) {
    final section = tab.section;
    if (section != null && !section.allows(scope)) {
      return scopeUnavailable(context, section);
    }
    // A group's content, in whichever section is open.
    if (section != null &&
        section != ScopedSection.activity &&
        section != ScopedSection.maps &&
        activeRoom != null) {
      return everydayPage(context);
    }
    return _page(context);
  }

  Widget _page(BuildContext context) => switch (tab) {
    Destination.forums => communities(context),
    Destination.messages => messages(context),
    Destination.files => filePage(context),
    Destination.network => networkPage(context),
    Destination.storage => StoragePage(
      node: node,
      nameOf: name,
      editLimits: () => editStorageLimits(context),
    ),
    Destination.stats => StatsPage(
      network: network,
      deviceName: (device) {
        final contact = node.contacts[device];
        if (contact == null) return 'Unknown device';
        return contact.person == node.person
            ? '${deviceLabel(contact)} (yours)'
            : '${name(contact.person)} · ${deviceLabel(contact)}';
      },
    ),
    Destination.voting => voting(context),
    Destination.profile => profile(context),
    Destination.settings => settings(context),
    Destination.notes => everydayPage(context),
    Destination.activity => activityPage(context),
    Destination.groups => groupsPage(context),
    Destination.search => searchPage(context),
    Destination.calendar =>
      scope == ScopeKind.personal
          ? personalCalendarView(context)
          : calendarScreen(context),
    Destination.plugin => pluginPage(context),
    Destination.plugins => PluginsPage(
      plugins: plugins!,
      notice: notice,
      pickPackage: pickPluginPackage,
      savePackage: (name, bytes) async {
        await FilePicker.saveFile(fileName: name, bytes: bytes);
      },
      nameOf: name,
    ),
    Destination.maps || Destination.locations => MapPage(
      node: node,
      tiles: mapTiles,
      share: locationShare,
      nameOf: name,
      onMessage: openConversation,
      onShare: sharePlaceLink,
      scope:
          activeRoom?.object.space ??
          (viewScope == ScopeKind.personal ? Places.personal : null),
    ),
  };

  /// Loads installed plugins beside the profile, where files can be kept.
  void startPlugins() {
    final path = node.store.path;
    if (!widget.enablePlatform || path == null) return;
    final everyday = Everyday(node);
    final plugins = this.plugins =
        Plugins(
            node,
            directory: '${path.replaceFirst(RegExp(r'\.db$'), '')}-plugins',
          )
          ..link = network
          ..fetch = ((o) => files.readBytes(o, limit: PluginPackage.maxBytes))
          ..readFile = ((o, limit) => files.readBytes(o, limit: limit))
          ..storeFileStream = ((source, size, name) =>
              files.storeFrom(source, size: size, name: name))
          ..openFileStream = ((o) => files.open(o))
          ..readFileRange = ((o, offset, length) =>
              files.readRange(o, offset, length))
          ..nameOf = name
          ..follow = notes.state.subscribe
          ..openTun = openPluginInterface
          ..confirmDesktop = confirmDesktop
          ..writeClipboard = (text) {
            return Clipboard.setData(ClipboardData(text: text));
          }
          ..closeTun = (_) {
            if (Platform.isAndroid) {
              unawaited(
                _vpn.invokeMethod<void>('close').catchError((Object _) {}),
              );
            }
          }
          ..groups = () async => [
            for (final room in await everyday.rooms())
              (
                space: room.object.space,
                name: '${room.data['name']}',
                members: await everyday.members(room),
              ),
          ];
    // Windows serves and views; Android views.
    if (Platform.isWindows || Platform.isAndroid) {
      _desktops = RemoteDesktops(network, plugins);
    }
    _pluginNotices = plugins.notices.listen((n) {
      if (n.kind == 'log') return;
      notice(
        n.kind == 'notify' ? '${n.title}: ${n.body}' : '${n.title}. ${n.body}',
      );
    });
    // A plugin (Git) offers a script plugin: the person decides.
    _pluginOffers = plugins.offered.listen((offered) {
      if (!mounted) return;
      unawaited(
        installOffered(
          context,
          offered,
          plugins: plugins,
          nameOf: name,
          notice: notice,
        ),
      );
    });
    void restorePluginSection() {
      if (tab != Destination.plugin || pluginSection != null) return;
      final saved = node.store.setting('lastPluginSection');
      pluginSection = pluginSections.where((s) => s.id == saved).firstOrNull;
    }

    _pluginSections = node.registry.changes.listen((_) {
      restorePluginSection();
      redraw();
    });
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final bridge = _localBridge = LocalBridge(plugins);
      _localBridgeSync = plugins.changes.listen((_) => bridge.sync());
    }
    unawaited(
      plugins.load().then((_) {
        restorePluginSection();
        if (tab == Destination.plugin && pluginSection == null) {
          tab = Destination.notes;
        }
        final folder = node.store.setting('pluginDevFolder');
        if (folder is String && !Platform.isAndroid) plugins.watch(folder);
        redraw();
        return _updateBundledPlugins(plugins);
      }, onError: (Object e) => notice('Plugins: $e')),
    );
  }

  /// A new build ships newer versions of its own plugins: installed ones
  /// take them without asking when they need no new grant.
  Future<void> _updateBundledPlugins(Plugins plugins) async {
    if (plugins.installed.isEmpty) return;
    try {
      final updated = await plugins.updateBundled(await bundledPlugins());
      for (final id in updated) {
        final p = plugins[id]!.manifest;
        notice('${p.name} updated to ${p.version}');
      }
    } catch (e) {
      notice('Plugins: $e');
    }
  }

  static const _vpn = MethodChannel('ournet/vpn');

  /// A virtual network interface for a plugin granted `tun`: Android's
  /// VpnService, which asks the person first, or on Windows the network
  /// helper service, installed once after Windows asks (see [WindowsTun]).
  /// A friend's device asks to see this screen and use its mouse and
  /// keyboard (Remote Desktop): the person here decides, each time. No
  /// answer in time is no.
  Future<bool> confirmDesktop(
    String plugin,
    String device,
    String person,
  ) async {
    if (!mounted) return false;
    final who = name(person);
    final where = plugins?.deviceName(device) ?? 'a device';
    final answer = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        // Gives up before the request does.
        final timer = Timer(
          Plugins.desktopAsk - const Duration(seconds: 2),
          () {
            if (context.mounted) Navigator.of(context).pop(false);
          },
        );
        return PopScope(
          onPopInvokedWithResult: (_, _) => timer.cancel(),
          child: AlertDialog(
            icon: const Icon(Icons.screen_share_outlined),
            title: Text('Let $who see this screen?'),
            content: Text(
              '$who ($where) asks to see this screen and use its mouse and '
              'keyboard through Remote Desktop. You can stop it at any time '
              'from the banner at the top. Clipboard text stays here.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Allow this time'),
              ),
            ],
          ),
        );
      },
    );
    return answer == true;
  }

  Future<Json> openPluginInterface(String plugin, Json settings) async {
    if (Platform.isAndroid) {
      try {
        final fd = await _vpn.invokeMethod<int>('open', settings);
        if (fd == null) throw StateError('Android opened no interface');
        return {'fd': fd};
      } on PlatformException catch (e) {
        throw StateError(e.message ?? 'Android refused');
      }
    }
    if (Platform.isWindows) {
      await WindowsTun.ensure();
      return {'pipe': WindowsTun.pipe};
    }
    throw StateError('VPNs do not run on this system yet');
  }

  /// Sections of plugins that are switched on, for navigation.
  List<PluginSection> get pluginSections => [
    for (final s in node.registry.sections)
      if (plugins?[s.plugin]?.enabled ?? false) s,
  ];

  /// The Material icon a manifest names; a generic one for others.
  static IconData pluginIcon(String name) => switch (name) {
    'menu_book' => Icons.menu_book_outlined,
    'source' => Icons.source_outlined,
    'article' => Icons.article_outlined,
    'campaign' => Icons.campaign_outlined,
    'casino' => Icons.casino_outlined,
    'grid' => Icons.grid_3x3,
    'sports' => Icons.sports_esports_outlined,
    'vpn' => Icons.vpn_lock_outlined,
    'devices' => Icons.devices_outlined,
    'chat' => Icons.chat_outlined,
    'bug_report' => Icons.bug_report_outlined,
    'poll' => Icons.poll_outlined,
    _ => Icons.extension_outlined,
  };

  Widget pluginPage(BuildContext context) {
    final section = pluginSection;
    final plugins = this.plugins;
    if (section == null || plugins == null) {
      return empty(
        'Nothing here',
        'Pick a plugin in the menu.',
        Icons.extension_outlined,
      );
    }
    // The scope stays on screen in the app bar, so another is a tap away.
    if (!section.allows(scope)) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(pluginIcon(section.icon), size: 48, color: Colors.teal),
              const SizedBox(height: 16),
              Text(
                '${section.title} has nothing in ${_Scopes(this).scopeLabel(scope).title}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => update(() => setScope(null)),
                child: const Text('Show all'),
              ),
            ],
          ),
        ),
      );
    }
    final room = activeRoom;
    // Told once: a later return to the page keeps where the person went.
    final object = pluginObject;
    pluginObject = null;
    return PluginView(
      key: ValueKey(section.id),
      plugins: plugins,
      plugin: section.plugin,
      surface: section.surface,
      context: room != null
          ? {
              'scope': 'group',
              'space': room.object.space,
              'name': '${room.data['name']}',
            }
          : {'scope': scope?.name ?? 'all'},
      object: object,
      nameOf: name,
      avatar: (person, size) => conversationAvatar(person, radius: size / 2),
      image: (plugin, id, height) => _PluginPicture(
        key: ValueKey(id),
        node: node,
        files: files,
        plugin: plugin,
        id: id,
        height: height,
        online: network.running,
      ),
      pickFile: pickPluginFile,
    );
  }

  /// Asks for a file for [plugin] to attach (see [PluginFilePicker]) and
  /// stores it encrypted, as a message's attachment is.
  Future<Json?> pickPluginFile(String plugin, String accept) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: accept == 'image' ? 'Choose a picture' : 'Choose a file',
      type: accept == 'image' ? FileType.image : FileType.any,
    );
    final path = picked.firstOrNull?.path;
    if (path == null) return null;
    try {
      final stored = await files.store(path);
      final handle = plugins?.addFile(plugin, stored);
      if (handle == null) throw StateError('The plugin is not running');
      return {'file': handle, 'name': stored['name'], 'size': stored['size']};
    } catch (e) {
      notice('Could not add the file: $e');
      return null;
    }
  }

  /// Opens [o], an object of a plugin's, in that plugin's page, in the
  /// scope it belongs to: from search or the activity feed.
  Future<void> openPluginObject(SignedObject o) async {
    final plugin = PluginKinds.pluginOf(o.kind);
    final sections = pluginSections.where((s) => s.plugin == plugin);
    final group = Activity.pluginGroup(o);
    final kind = group != null
        ? ScopeKind.group
        : o.isPublic
        ? ScopeKind.public
        : ScopeKind.personal;
    final section =
        sections.where((s) => s.allows(kind)).firstOrNull ??
        sections.firstOrNull;
    if (section == null) {
      notice('Switch its plugin on to open this');
      return;
    }
    final room = group == null ? null : await activityRoom(group);
    if (!mounted) return;
    update(() {
      if (room != null) {
        showGroup(room, section: Destination.plugin);
      } else if (kind == ScopeKind.public) {
        setScope(ScopeKind.public);
      } else {
        reveal(ScopeKind.personal);
      }
      tab = Destination.plugin;
      pluginSection = section;
      pluginObject = o.id;
      showConversation = false;
      showForum = false;
    });
  }

  Future<Uint8List?> pickPluginPackage() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose a plugin',
      type: FileType.custom,
      allowedExtensions: const ['ournet-plugin'],
    );
    return picked.singleOrNull?.readAsBytes();
  }

  /// Counts are capped where they are counted (see [Store.unreadIn]).
  Widget countBadge(int count) =>
      Badge.count(count: count, maxCount: 99, isLabelVisible: count > 0);

  /// A placeholder for nothing to show. Scrolls rather than overflows where
  /// the keyboard leaves it almost no height.
  Widget empty(String title, String detail, IconData icon) => Center(
    child: SingleChildScrollView(
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
    ),
  );

  /// Who the one-to-one call is with: one of your devices, or a friend.
  String callPeerName() {
    final peer = calls.peer;
    if (peer == null) return 'Call';
    if (calls.isOwnDevice(peer)) {
      final contact = node.contacts[peer];
      return contact == null ? 'Your device' : deviceLabel(contact);
    }
    return name(node.contacts[peer]?.person ?? peer);
  }

  /// Shows the one-to-one call full screen, until it ends or is put away.
  Future<void> openCall() async {
    final navigator = noteNavigator.currentState;
    if (directCallOpen || calls.phase == 'idle' || navigator == null) return;
    update(() => directCallOpen = true);
    final peer = calls.peer;
    try {
      await navigator.push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => CallScreen(
            calls: calls,
            name: callPeerName(),
            seed: node.contacts[peer]?.person ?? peer,
            avatar: node.contacts[peer] == null
                ? null
                : node.avatars.of(node.contacts[peer]!.person),
            act: callAct,
          ),
        ),
      );
    } finally {
      directCallOpen = false;
      redraw();
    }
  }
}

/// The picture attached to [plugin]'s object [id], as a plugin's `Picture`
/// widget or a `![…](id)` line draws it: through [InlineImage], so it is
/// decoded off the UI isolate and cached like a message's picture. Nothing
/// for an object that is not the plugin's, not here yet, or not a picture.
class _PluginPicture extends StatefulWidget {
  final Node node;
  final Files files;
  final String plugin, id;
  final double? height;
  final bool online;
  const _PluginPicture({
    super.key,
    required this.node,
    required this.files,
    required this.plugin,
    required this.id,
    required this.height,
    required this.online,
  });

  @override
  State<_PluginPicture> createState() => _PluginPictureState();
}

class _PluginPictureState extends State<_PluginPicture> {
  late final Future<(SignedObject, Json)?> _found = _find();

  Future<(SignedObject, Json)?> _find() async {
    final o = widget.node.store.get(widget.id);
    if (o == null || PluginKinds.pluginOf(o.kind) != widget.plugin) {
      return null;
    }
    final payload = await widget.node.content(o);
    return payload != null && isImagePayload(payload) ? (o, payload) : null;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<(SignedObject, Json)?>(
    future: _found,
    builder: (context, snapshot) {
      final found = snapshot.data;
      if (found == null) {
        return SizedBox(height: snapshot.hasData ? 0 : widget.height);
      }
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: widget.height ?? double.infinity,
        ),
        child: InlineImage(
          files: widget.files,
          object: found.$1,
          payload: found.$2,
          online: widget.online,
          height: widget.height,
          fit: BoxFit.contain,
        ),
      );
    },
  );
}
