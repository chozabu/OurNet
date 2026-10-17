#include "system_tray.h"

#include <glib/gstdio.h>
#include <unistd.h>

#include <cerrno>

#include <string>

#ifdef HAVE_APPINDICATOR
#include <libayatana-appindicator/app-indicator.h>
#endif

namespace {

constexpr char kBackground[] = "--background";

GtkApplication* application_ = nullptr;
GtkWindow* window_ = nullptr;
FlMethodChannel* channel_ = nullptr;
bool keep_ = false;
#ifdef HAVE_APPINDICATOR
AppIndicator* indicator_ = nullptr;
#endif

bool InFlatpak() { return g_file_test("/.flatpak-info", G_FILE_TEST_EXISTS); }

// Whether a StatusNotifierItem host is running, so an icon would be seen.
bool TrayHosted() {
#ifdef HAVE_APPINDICATOR
  g_autoptr(GDBusConnection) bus =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (bus == nullptr) return false;
  g_autoptr(GVariant) owner = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner",
      g_variant_new("(s)", "org.kde.StatusNotifierWatcher"),
      G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
  gboolean has = FALSE;
  if (owner != nullptr) g_variant_get(owner, "(b)", &has);
  return has;
#else
  return false;
#endif
}

// Outside Flatpak: the XDG autostart entry. Under Flatpak the portal writes
// the real entry on the host, so this file only remembers the choice.
std::string StartupPath() {
  g_autofree gchar* path =
      InFlatpak()
          ? g_build_filename(g_get_user_config_dir(), "ournet-autostart",
                             nullptr)
          : g_build_filename(g_get_user_config_dir(), "autostart",
                             APPLICATION_ID ".desktop", nullptr);
  return path;
}

bool StartsOnSignIn() {
  return g_file_test(StartupPath().c_str(), G_FILE_TEST_EXISTS);
}

bool RememberStartup(bool on, GError** error) {
  const std::string path = StartupPath();
  if (!on) {
    if (g_file_test(path.c_str(), G_FILE_TEST_EXISTS) &&
        g_unlink(path.c_str()) != 0) {
      g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                  "Could not remove %s", path.c_str());
      return false;
    }
    return true;
  }
  g_autofree gchar* folder = g_path_get_dirname(path.c_str());
  g_mkdir_with_parents(folder, 0700);
  std::string contents = "1\n";
  if (!InFlatpak()) {
    g_autofree gchar* self = g_file_read_link("/proc/self/exe", nullptr);
    g_autofree gchar* quoted = g_shell_quote(self ? self : "ournet");
    contents = std::string("[Desktop Entry]\nType=Application\nName=OurNet\n") +
               "Exec=" + quoted + " " + kBackground + "\n" +
               "X-GNOME-Autostart-enabled=true\n";
  }
  return g_file_set_contents(path.c_str(), contents.c_str(), -1, error);
}

void Respond(FlMethodCall* call, FlValue* value) {
  fl_method_call_respond_success(call, value, nullptr);
}

// The Background portal answers on a request object once the person (or
// the desktop's policy) has decided.
struct StartupRequest {
  FlMethodCall* call;
  bool on;
  GDBusConnection* bus;
  guint subscription;
};

void StartupAnswered(GDBusConnection* bus, const gchar*, const gchar*,
                     const gchar*, const gchar*, GVariant* parameters,
                     gpointer data) {
  auto* request = static_cast<StartupRequest*>(data);
  guint32 response = 2;
  g_autoptr(GVariant) results = nullptr;
  g_variant_get(parameters, "(u@a{sv})", &response, &results);
  gboolean autostart = FALSE;
  if (response == 0) {
    g_variant_lookup(results, "autostart", "b", &autostart);
  }
  g_autoptr(GError) error = nullptr;
  if (response != 0 || (request->on && !autostart)) {
    fl_method_call_respond_error(
        request->call, "startup",
        "Your desktop did not allow OurNet to start when you sign in.",
        nullptr, nullptr);
  } else if (!RememberStartup(request->on, &error)) {
    fl_method_call_respond_error(request->call, "startup", error->message,
                                 nullptr, nullptr);
  } else {
    Respond(request->call, fl_value_new_null());
  }
  g_dbus_connection_signal_unsubscribe(bus, request->subscription);
  g_object_unref(request->call);
  g_object_unref(request->bus);
  delete request;
}

void SetStartup(FlMethodCall* call, bool on) {
  if (!InFlatpak()) {
    g_autoptr(GError) error = nullptr;
    if (RememberStartup(on, &error)) {
      Respond(call, fl_value_new_null());
    } else {
      fl_method_call_respond_error(call, "startup", error->message, nullptr,
                                   nullptr);
    }
    return;
  }
  g_autoptr(GError) error = nullptr;
  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus == nullptr) {
    fl_method_call_respond_error(call, "startup", error->message, nullptr,
                                 nullptr);
    return;
  }
  // The request's path is known in advance, so its answer cannot be missed.
  g_autofree gchar* token =
      g_strdup_printf("ournet%u", g_random_int_range(0, G_MAXINT32));
  g_autofree gchar* sender =
      g_strdup(g_dbus_connection_get_unique_name(bus) + 1);
  for (gchar* c = sender; *c; c++) {
    if (*c == '.') *c = '_';
  }
  g_autofree gchar* handle = g_strdup_printf(
      "/org/freedesktop/portal/desktop/request/%s/%s", sender, token);
  auto* request = new StartupRequest{
      FL_METHOD_CALL(g_object_ref(call)), on, bus, 0};
  request->subscription = g_dbus_connection_signal_subscribe(
      bus, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request",
      "Response", handle, nullptr, G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE,
      StartupAnswered, request, nullptr);

  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token));
  g_variant_builder_add(
      &options, "{sv}", "reason",
      g_variant_new_string("Stay connected to friends, so messages arrive."));
  g_variant_builder_add(&options, "{sv}", "autostart",
                        g_variant_new_boolean(on));
  const gchar* command[] = {"ournet", kBackground, nullptr};
  g_variant_builder_add(&options, "{sv}", "commandline",
                        g_variant_new_strv(command, -1));
  g_dbus_connection_call(
      bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
      "org.freedesktop.portal.Background", "RequestBackground",
      g_variant_new("(sa{sv})", "", &options), nullptr,
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
      [](GObject* source, GAsyncResult* result, gpointer data) {
        auto* request = static_cast<StartupRequest*>(data);
        g_autoptr(GError) error = nullptr;
        g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
            G_DBUS_CONNECTION(source), result, &error);
        if (reply != nullptr) return;
        fl_method_call_respond_error(request->call, "startup", error->message,
                                     nullptr, nullptr);
        g_dbus_connection_signal_unsubscribe(request->bus,
                                             request->subscription);
        g_object_unref(request->call);
        g_object_unref(request->bus);
        delete request;
      },
      request);
}

void Quit() {
  keep_ = false;
  g_application_quit(G_APPLICATION(application_));
}

void ShowIcon(bool on) {
#ifdef HAVE_APPINDICATOR
  if (on && indicator_ == nullptr) {
    indicator_ = app_indicator_new(APPLICATION_ID, APPLICATION_ID,
                                   APP_INDICATOR_CATEGORY_COMMUNICATIONS);
    // A bundle run outside an installed package ships its icon beside it.
    g_autofree gchar* self = g_file_read_link("/proc/self/exe", nullptr);
    if (self != nullptr) {
      g_autofree gchar* folder = g_path_get_dirname(self);
      g_autofree gchar* icons =
          g_build_filename(folder, "data", "icons", nullptr);
      if (g_file_test(icons, G_FILE_TEST_IS_DIR)) {
        app_indicator_set_icon_theme_path(indicator_, icons);
      }
    }
    app_indicator_set_title(indicator_, "OurNet");
    GtkWidget* menu = gtk_menu_new();
    GtkWidget* open = gtk_menu_item_new_with_label("Open OurNet");
    g_signal_connect(open, "activate",
                     G_CALLBACK(+[](GtkMenuItem*, gpointer) {
                       system_tray_show();
                     }),
                     nullptr);
    GtkWidget* quit = gtk_menu_item_new_with_label("Quit OurNet");
    g_signal_connect(quit, "activate",
                     G_CALLBACK(+[](GtkMenuItem*, gpointer) { Quit(); }),
                     nullptr);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), open);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit);
    gtk_widget_show_all(menu);
    app_indicator_set_menu(indicator_, GTK_MENU(menu));
    app_indicator_set_secondary_activate_target(indicator_, open);
  }
  if (indicator_ != nullptr) {
    app_indicator_set_status(indicator_, on ? APP_INDICATOR_STATUS_ACTIVE
                                            : APP_INDICATOR_STATUS_PASSIVE);
  }
#endif
}

void Unread(int count) {
#ifdef HAVE_APPINDICATOR
  if (indicator_ == nullptr) return;
  g_autofree gchar* title =
      count > 0 ? g_strdup_printf("OurNet · %d unread", count)
                : g_strdup("OurNet");
  app_indicator_set_title(indicator_, title);
#endif
}

void Hint(const gchar* title, const gchar* text) {
  g_autoptr(GNotification) notification = g_notification_new(title);
  g_notification_set_body(notification, text);
  g_application_send_notification(G_APPLICATION(application_), "tray",
                                  notification);
}

FlValue* Argument(FlMethodCall* call, const gchar* name) {
  FlValue* arguments = fl_method_call_get_args(call);
  if (arguments == nullptr ||
      fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(arguments, name);
}

bool BoolArgument(FlMethodCall* call, const gchar* name, bool fallback) {
  FlValue* value = Argument(call, name);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL
             ? fl_value_get_bool(value)
             : fallback;
}

const gchar* StringArgument(FlMethodCall* call, const gchar* name) {
  FlValue* value = Argument(call, name);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : "";
}

void HandleCall(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "claim") == 0) {
    // One window per profile is kept by GApplication (my_application.cc).
    Respond(call, fl_value_new_bool(TRUE));
  } else if (g_strcmp0(method, "available") == 0) {
    Respond(call, fl_value_new_bool(TrayHosted()));
  } else if (g_strcmp0(method, "keep") == 0) {
    keep_ = BoolArgument(call, "on", true) && TrayHosted();
    ShowIcon(keep_);
    Respond(call, nullptr);
  } else if (g_strcmp0(method, "unread") == 0) {
    FlValue* count = Argument(call, "count");
    Unread(count != nullptr && fl_value_get_type(count) == FL_VALUE_TYPE_INT
               ? static_cast<int>(fl_value_get_int(count))
               : 0);
    Respond(call, nullptr);
  } else if (g_strcmp0(method, "show") == 0) {
    system_tray_show();
    Respond(call, nullptr);
  } else if (g_strcmp0(method, "hint") == 0) {
    Hint(StringArgument(call, "title"), StringArgument(call, "text"));
    Respond(call, nullptr);
  } else if (g_strcmp0(method, "startup") == 0) {
    Respond(call, fl_value_new_bool(StartsOnSignIn()));
  } else if (g_strcmp0(method, "setStartup") == 0) {
    SetStartup(call, BoolArgument(call, "on", false));
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

// Closing the window while kept in the tray only hides it.
gboolean WindowClosing(GtkWidget* window, GdkEvent*, gpointer) {
  if (!keep_) return FALSE;
  gtk_widget_hide(window);
  fl_method_channel_invoke_method(channel_, "closed", nullptr, nullptr,
                                  nullptr, nullptr);
  return TRUE;
}

}  // namespace

void system_tray_start(GtkApplication* application, GtkWindow* window,
                       FlBinaryMessenger* messenger) {
  application_ = application;
  window_ = window;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel_ =
      fl_method_channel_new(messenger, "ournet/tray", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel_, HandleCall, nullptr,
                                            nullptr);
  g_signal_connect(window, "delete-event", G_CALLBACK(WindowClosing), nullptr);
}

void system_tray_show() {
  if (window_ == nullptr) return;
  gtk_widget_show(GTK_WIDGET(window_));
  gtk_window_deiconify(window_);
  gtk_window_present(window_);
}
