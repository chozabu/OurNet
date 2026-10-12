import 'package:flutter/material.dart';

/// Transient feedback, including Undo. Flutter otherwise makes action
/// snackbars persistent by default. [AppNotices.showNotice] gives accessible
/// navigation users time to use actions; a close button allows dismissal
/// without a gesture.
class AppNotice extends SnackBar {
  const AppNotice({
    super.key,
    required super.content,
    super.action,
    super.duration = const Duration(seconds: 4),
  }) : super(persist: false, showCloseIcon: true);
}

extension AppNotices on ScaffoldMessengerState {
  /// Replace stale feedback rather than accumulating a queue of notices.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showNotice(
    AppNotice notice,
  ) {
    clearSnackBars();
    // Give screen-reader users time to reach Undo, with an explicit way to
    // dismiss it. The current Flutter SDK does not apply this exemption itself.
    final accessible = MediaQuery.accessibleNavigationOf(context);
    return showSnackBar(
      accessible && notice.action != null
          ? SnackBar(
              key: notice.key,
              content: notice.content,
              action: notice.action,
              duration: notice.duration,
              persist: true,
              showCloseIcon: true,
            )
          : notice,
    );
  }
}
