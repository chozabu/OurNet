/// Who content is for, as the app's scope switcher sees it (see docs/SCOPES.md).
///
/// "All" is not a kind: it is every kind a section allows at once.
enum ScopeKind {
  /// Not in a group and not public: a person's own things and what they
  /// share with individual friends.
  personal,

  /// One private group's content.
  group,

  /// Public: an empty audience.
  public,
}

/// A place in navigation that holds content, and the scopes it may hold:
/// one of [ScopedSection], or a plugin's (`PluginSection`).
abstract interface class Section {
  /// Stable: saved as the last place visited.
  String get id;
  Set<ScopeKind> get scopes;

  /// Whether this section has anything in [scope]; null is All, which every
  /// section has.
  bool allows(ScopeKind? scope);
}

/// The sections that hold content, and the scopes each may hold. The app
/// reads this for navigation and empty states; code that writes or checks
/// content reads it too, so allowing a scope is a change here, not across
/// screens.
enum ScopedSection implements Section {
  notes({ScopeKind.personal, ScopeKind.group}),
  calendar({ScopeKind.personal, ScopeKind.group}),
  chat({ScopeKind.personal, ScopeKind.group, ScopeKind.public}),
  forums({ScopeKind.group, ScopeKind.public}),
  files({ScopeKind.personal, ScopeKind.group, ScopeKind.public}),
  maps({ScopeKind.personal}),

  /// What happened lately, across the other sections (docs/ACTIVITY.md).
  activity({ScopeKind.personal, ScopeKind.group, ScopeKind.public});

  @override
  final Set<ScopeKind> scopes;
  const ScopedSection(this.scopes);

  @override
  String get id => name;

  @override
  bool allows(ScopeKind? scope) => scope == null || scopes.contains(scope);
}
