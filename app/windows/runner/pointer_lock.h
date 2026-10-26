#ifndef RUNNER_POINTER_LOCK_H_
#define RUNNER_POINTER_LOCK_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>

// Pointer lock for remote desktop games (docs/REMOTE_DESKTOP.md): while
// locked, the cursor stays put inside the window and the mouse's raw
// movement goes to Dart as relative counts, coalesced to one message every
// few milliseconds. Losing focus unlocks it.
class PointerLock {
 public:
  PointerLock(flutter::BinaryMessenger* messenger, HWND window);
  ~PointerLock();

  std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  void Lock(bool on);
  void Clip();
  void Flush(bool force);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  bool locked_ = false;
  LONG dx_ = 0, dy_ = 0;
  ULONGLONG last_ = 0;
};

#endif  // RUNNER_POINTER_LOCK_H_
