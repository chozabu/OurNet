#ifndef RUNNER_SYSTEM_TRAY_H_
#define RUNNER_SYSTEM_TRAY_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The "ournet/tray" channel on Linux (lib/services/system_tray.dart): a
// StatusNotifierItem icon where the desktop shows one (KDE, Steam Deck's
// desktop mode), closing to it, and starting on sign in through the
// Background portal under Flatpak or an autostart entry otherwise.
void system_tray_start(GtkApplication* application, GtkWindow* window,
                       FlBinaryMessenger* messenger);

// Brings the window back, from hidden or minimised.
void system_tray_show();

#endif  // RUNNER_SYSTEM_TRAY_H_
