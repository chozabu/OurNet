#ifndef RUNNER_SYSTEM_TRAY_H_
#define RUNNER_SYSTEM_TRAY_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>
#include <optional>
#include <string>

// OurNet's notification area icon. While it is kept, closing the window hides
// it and OurNet keeps running, connected to friends and showing notifications;
// the icon opens the window again or quits. Also keeps one window per profile
// and starts OurNet with Windows.
class SystemTray {
 public:
  SystemTray(flutter::BinaryMessenger* messenger, HWND window);
  ~SystemTray();

  // Handles the icon's messages and closing the window while kept in the tray.
  std::optional<LRESULT> HandleMessage(HWND window, UINT message,
                                       WPARAM wparam, LPARAM lparam);

  // Whether the window should stay hidden after its first frame: OurNet was
  // started with Windows, into the tray.
  static bool StartHidden();

 private:
  NOTIFYICONDATAW IconData() const;
  void AddIcon();
  void RemoveIcon();
  void UpdateTip();
  void ShowWindow();
  void ShowMenu(POINT at);
  void Quit();
  void Hint(const std::wstring& title, const std::wstring& text);
  bool ClaimProfile(const std::string& profile);
  bool ShowHolder(const std::string& profile);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  UINT taskbar_created_;
  bool keep_;
  UINT show_message_ = 0;
  HANDLE instance_ = nullptr;
  HANDLE holder_record_ = nullptr;
  HICON icon_ = nullptr;
  bool added_ = false;
  bool quitting_ = false;
  int unread_ = 0;
};

#endif  // RUNNER_SYSTEM_TRAY_H_
