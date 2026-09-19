#include "system_tray.h"

#include <appmodel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <windowsx.h>
#include <winrt/Windows.ApplicationModel.Activation.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.h>

#include <cstdint>
#include <functional>
#include <string>
#include <thread>

#include "resource.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr UINT kIconMessage = WM_APP + 0x52;
constexpr UINT kIconId = 1;
constexpr UINT kOpen = 1, kQuit = 2;
constexpr wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"OurNet";
constexpr wchar_t kBackground[] = L"--background";
// The Store package's startup task; see msix_config in pubspec.yaml.
constexpr wchar_t kStartupTaskId[] = L"OurNetStartup";
// How long a running copy has to come forward before it counts as stuck.
constexpr UINT kShowTimeoutMs = 5000;

using winrt::Windows::ApplicationModel::StartupTask;
using winrt::Windows::ApplicationModel::StartupTaskState;

std::wstring HolderRecordName(const std::wstring& profile) {
  return L"Local\\OurNet.Window." + profile;
}

// The window of the copy holding a profile, as it recorded in ClaimProfile.
HWND HolderWindow(const std::wstring& profile) {
  HANDLE record =
      OpenFileMappingW(FILE_MAP_READ, FALSE, HolderRecordName(profile).c_str());
  if (record == nullptr) return nullptr;
  HWND window = nullptr;
  if (const auto* view = static_cast<const uint64_t*>(
          MapViewOfFile(record, FILE_MAP_READ, 0, 0, sizeof(uint64_t)))) {
    window = reinterpret_cast<HWND>(static_cast<uintptr_t>(*view));
    UnmapViewOfFile(view);
  }
  CloseHandle(record);
  return IsWindow(window) ? window : nullptr;
}

std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()),
                                         nullptr, 0);
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      wide.data(), length);
  return wide;
}

template <typename T>
T Argument(const EncodableValue* arguments, const char* key, T fallback) {
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return fallback;
  const auto found = map->find(EncodableValue(key));
  if (found == map->end()) return fallback;
  const auto* value = std::get_if<T>(&found->second);
  return value == nullptr ? fallback : *value;
}

// What the Run key starts: this executable, into the tray.
std::wstring StartupCommand() {
  wchar_t path[MAX_PATH];
  const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (length == 0 || length == MAX_PATH) return {};
  return L"\"" + std::wstring(path, length) + L"\" " + kBackground;
}

// Installed from an MSIX package, where Windows keeps the package's registry
// writes to itself, so the Run key has no effect and a startup task is used.
bool Packaged() {
  UINT32 length = 0;
  return GetCurrentPackageFullName(&length, nullptr) !=
         APPMODEL_ERROR_NO_PACKAGE;
}

// Runs [work] on a multithreaded apartment and waits, as WinRT's blocking
// calls may not wait on the window's single-threaded one.
template <typename T>
T OnWorker(T fallback, const std::function<T()>& work) {
  T result = fallback;
  std::thread([&] {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    try {
      result = work();
    } catch (const winrt::hresult_error&) {
    }
    winrt::uninit_apartment();
  }).join();
  return result;
}

bool Enabled(StartupTaskState state) {
  return state == StartupTaskState::Enabled ||
         state == StartupTaskState::EnabledByPolicy;
}

bool PackageStartsWithWindows() {
  return OnWorker<bool>(false, [] {
    return Enabled(StartupTask::GetAsync(kStartupTaskId).get().State());
  });
}

// Null when it was changed, else why not.
const char* SetPackageStartsWithWindows(bool on) {
  return OnWorker<const char*>(
      "Windows did not allow changing startup apps.", [on]() -> const char* {
        const auto task = StartupTask::GetAsync(kStartupTaskId).get();
        if (!on) {
          if (task.State() == StartupTaskState::EnabledByPolicy) {
            return "Your organisation starts OurNet with Windows.";
          }
          task.Disable();
          return nullptr;
        }
        const auto state = task.RequestEnableAsync().get();
        if (Enabled(state)) return nullptr;
        return state == StartupTaskState::DisabledByUser
                   ? "OurNet is turned off in Task Manager's Startup apps; "
                     "turn it on there."
                   : "Your organisation does not allow OurNet to start with "
                     "Windows.";
      });
}

bool StartsWithWindows() {
  if (Packaged()) return PackageStartsWithWindows();
  wchar_t value[MAX_PATH * 2];
  DWORD size = sizeof value;
  if (RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ,
                   nullptr, value, &size) != ERROR_SUCCESS) {
    return false;
  }
  // A copy of OurNet elsewhere does not count; turning it on again points
  // the entry here.
  return StartupCommand() == value;
}

bool SetStartsWithWindows(bool on) {
  HKEY key;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  LSTATUS status;
  if (on) {
    const auto command = StartupCommand();
    status = command.empty()
                 ? ERROR_BAD_PATHNAME
                 : RegSetValueExW(
                       key, kRunValue, 0, REG_SZ,
                       reinterpret_cast<const BYTE*>(command.c_str()),
                       static_cast<DWORD>((command.size() + 1) *
                                          sizeof(wchar_t)));
  } else {
    status = RegDeleteValueW(key, kRunValue);
    if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

void CopyTruncated(wchar_t* target, size_t capacity,
                   const std::wstring& text) {
  wcsncpy_s(target, capacity, text.c_str(), _TRUNCATE);
}

}  // namespace

NOTIFYICONDATAW SystemTray::IconData() const {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof data;
  data.hWnd = window_;
  data.uID = kIconId;
  return data;
}

SystemTray::SystemTray(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "ournet/tray",
          &flutter::StandardMethodCodec::GetInstance())),
      taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")),
      keep_(StartHidden()) {
  icon_ = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0));
  // A window started hidden needs its icon before Dart has started; others
  // wait for Dart to keep it.
  AddIcon();
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    const auto* arguments = call.arguments();
    if (method == "claim") {
      const auto profile = Argument<std::string>(arguments, "profile", "main");
      const auto show = Argument<bool>(arguments, "show", true);
      bool claimed = ClaimProfile(profile);
      if (!claimed && show) claimed = ShowHolder(profile);
      result->Success(EncodableValue(claimed));
    } else if (method == "keep") {
      keep_ = Argument<bool>(arguments, "on", true);
      if (keep_) {
        AddIcon();
      } else {
        RemoveIcon();
        // Nothing left to reopen a hidden window from.
        ShowWindow();
      }
      result->Success();
    } else if (method == "unread") {
      unread_ = Argument<int>(arguments, "count", 0);
      UpdateTip();
      result->Success();
    } else if (method == "show") {
      ShowWindow();
      result->Success();
    } else if (method == "hint") {
      Hint(Wide(Argument<std::string>(arguments, "title", "")),
           Wide(Argument<std::string>(arguments, "text", "")));
      result->Success();
    } else if (method == "startup") {
      result->Success(EncodableValue(StartsWithWindows()));
    } else if (method == "setStartup") {
      const bool on = Argument<bool>(arguments, "on", false);
      const char* refused =
          Packaged() ? SetPackageStartsWithWindows(on)
          : SetStartsWithWindows(on)
              ? nullptr
              : "Windows did not allow changing startup apps.";
      if (refused == nullptr) {
        result->Success();
      } else {
        result->Error("startup", refused);
      }
    } else {
      result->NotImplemented();
    }
  });
}

SystemTray::~SystemTray() {
  channel_->SetMethodCallHandler(nullptr);
  RemoveIcon();
  if (icon_ != nullptr) DestroyIcon(icon_);
  if (holder_record_ != nullptr) CloseHandle(holder_record_);
  if (instance_ != nullptr) CloseHandle(instance_);
}

bool SystemTray::StartHidden() {
  // The package's startup task passes --background too; this also covers a
  // Windows that drops its parameters.
  static const bool by_startup_task = Packaged() && [] {
    try {
      const auto activated = winrt::Windows::ApplicationModel::AppInstance::
          GetActivatedEventArgs();
      return activated != nullptr &&
             activated.Kind() == winrt::Windows::ApplicationModel::Activation::
                                     ActivationKind::StartupTask;
    } catch (const winrt::hresult_error&) {
      return false;
    }
  }();
  if (by_startup_task) return true;
  int count = 0;
  wchar_t** arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  if (arguments == nullptr) return false;
  bool hidden = false;
  for (int i = 1; i < count; i++) {
    if (wcscmp(arguments[i], kBackground) == 0) hidden = true;
  }
  LocalFree(arguments);
  return hidden;
}

// One window per profile: a second copy asks the first to show itself and
// leaves, rather than failing to open the profile it holds.
bool SystemTray::ClaimProfile(const std::string& profile) {
  const auto name = Wide(profile);
  show_message_ = RegisterWindowMessageW((L"OurNet.Show." + name).c_str());
  if (instance_ != nullptr) return true;
  HANDLE mutex =
      CreateMutexW(nullptr, FALSE, (L"Local\\OurNet.Profile." + name).c_str());
  if (mutex == nullptr) return true;
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    CloseHandle(mutex);
    return false;
  }
  instance_ = mutex;
  // Lets a later copy reach this window directly, and tell if it is stuck.
  // Like the mutex, the record goes when this process does, however it ends.
  holder_record_ = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr,
                                      PAGE_READWRITE, 0, sizeof(uint64_t),
                                      HolderRecordName(name).c_str());
  if (holder_record_ != nullptr) {
    if (auto* view = static_cast<uint64_t*>(MapViewOfFile(
            holder_record_, FILE_MAP_WRITE, 0, 0, sizeof(uint64_t)))) {
      *view = reinterpret_cast<uintptr_t>(window_);
      UnmapViewOfFile(view);
    }
  }
  return true;
}

// Brings forward the copy holding [profile]. If it has stopped responding,
// offers to end it; true once it has and this copy holds the profile instead.
bool SystemTray::ShowHolder(const std::string& profile) {
  const HWND holder = HolderWindow(Wide(profile));
  if (holder == nullptr) {
    // Still starting up, or just quitting: nothing recorded to wait on.
    AllowSetForegroundWindow(ASFW_ANY);
    PostMessageW(HWND_BROADCAST, show_message_, 0, 0);
    return false;
  }
  DWORD process_id = 0;
  GetWindowThreadProcessId(holder, &process_id);
  AllowSetForegroundWindow(process_id);
  DWORD_PTR reply = 0;
  if (SendMessageTimeoutW(holder, show_message_, 0, 0, SMTO_ABORTIFHUNG,
                          kShowTimeoutMs, &reply) != 0) {
    return false;
  }
  // It quit while we asked; the profile is free.
  if (!IsWindow(holder)) return ClaimProfile(profile);
  const int answer = MessageBoxW(
      nullptr,
      L"OurNet is already running but has stopped responding.\n\n"
      L"End it and open OurNet again?",
      L"OurNet", MB_YESNO | MB_ICONWARNING | MB_SETFOREGROUND);
  if (answer != IDYES) return false;
  HANDLE process =
      OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, process_id);
  if (process == nullptr) return false;
  const bool ended = TerminateProcess(process, 1) &&
                     WaitForSingleObject(process, kShowTimeoutMs) ==
                         WAIT_OBJECT_0;
  CloseHandle(process);
  return ended && ClaimProfile(profile);
}

void SystemTray::AddIcon() {
  if (added_ || !keep_) return;
  auto data = IconData();
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kIconMessage;
  data.hIcon = icon_;
  CopyTruncated(data.szTip, ARRAYSIZE(data.szTip), L"OurNet");
  if (!Shell_NotifyIconW(NIM_ADD, &data)) return;
  data.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &data);
  added_ = true;
  UpdateTip();
}

void SystemTray::RemoveIcon() {
  if (!added_) return;
  auto data = IconData();
  Shell_NotifyIconW(NIM_DELETE, &data);
  added_ = false;
}

void SystemTray::UpdateTip() {
  if (!added_) return;
  auto data = IconData();
  data.uFlags = NIF_TIP | NIF_SHOWTIP;
  CopyTruncated(data.szTip, ARRAYSIZE(data.szTip),
                unread_ > 0 ? L"OurNet · " + std::to_wstring(unread_) +
                                  L" unread"
                            : L"OurNet");
  Shell_NotifyIconW(NIM_MODIFY, &data);
}

void SystemTray::Hint(const std::wstring& title, const std::wstring& text) {
  if (!added_) return;
  auto data = IconData();
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_NONE | NIIF_RESPECT_QUIET_TIME;
  CopyTruncated(data.szInfoTitle, ARRAYSIZE(data.szInfoTitle), title);
  CopyTruncated(data.szInfo, ARRAYSIZE(data.szInfo), text);
  Shell_NotifyIconW(NIM_MODIFY, &data);
}

void SystemTray::ShowWindow() {
  if (IsIconic(window_)) {
    ::ShowWindow(window_, SW_RESTORE);
  } else {
    ::ShowWindow(window_, SW_SHOW);
  }
  SetForegroundWindow(window_);
}

void SystemTray::ShowMenu(POINT at) {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kOpen, L"Open OurNet");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kQuit, L"Quit OurNet");
  SetMenuDefaultItem(menu, kOpen, FALSE);
  // Without being foreground the menu would not close on clicking away.
  SetForegroundWindow(window_);
  const UINT flags = TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON |
                     (GetSystemMetrics(SM_MENUDROPALIGNMENT) ? TPM_RIGHTALIGN
                                                              : TPM_LEFTALIGN);
  const UINT chosen =
      TrackPopupMenuEx(menu, flags, at.x, at.y, window_, nullptr);
  PostMessageW(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (chosen == kOpen) ShowWindow();
  if (chosen == kQuit) Quit();
}

void SystemTray::Quit() {
  quitting_ = true;
  RemoveIcon();
  PostMessageW(window_, WM_CLOSE, 0, 0);
}

std::optional<LRESULT> SystemTray::HandleMessage(HWND window, UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) {
  if (message == taskbar_created_) {
    // Explorer restarted and forgot the icon.
    added_ = false;
    AddIcon();
    return std::nullopt;
  }
  if (show_message_ != 0 && message == show_message_) {
    ShowWindow();
    return 0;
  }
  switch (message) {
    case kIconMessage:
      switch (LOWORD(lparam)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
          ShowWindow();
          break;
        case WM_CONTEXTMENU:
          ShowMenu({GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)});
          break;
      }
      return 0;
    case WM_CLOSE:
      if (keep_ && added_ && !quitting_) {
        ::ShowWindow(window, SW_HIDE);
        channel_->InvokeMethod("closed", nullptr);
        return 0;
      }
      break;
    case WM_QUERYENDSESSION:
      // Signing out or shutting down closes OurNet rather than hiding it.
      quitting_ = true;
      break;
  }
  return std::nullopt;
}
