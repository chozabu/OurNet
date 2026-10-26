#include "pointer_lock.h"

#include <flutter/standard_method_codec.h>

#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableValue;

constexpr UINT_PTR kFlushTimer = 0x0D35;

}  // namespace

PointerLock::PointerLock(flutter::BinaryMessenger* messenger, HWND window)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "ournet/pointer",
          &flutter::StandardMethodCodec::GetInstance())),
      window_(window) {
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == "lock") {
          Lock(true);
          result->Success(EncodableValue(locked_));
        } else if (call.method_name() == "unlock") {
          Lock(false);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

PointerLock::~PointerLock() {
  Lock(false);
  channel_->SetMethodCallHandler(nullptr);
}

void PointerLock::Lock(bool on) {
  if (on == locked_) return;
  RAWINPUTDEVICE mouse{};
  mouse.usUsagePage = 0x01;  // generic desktop
  mouse.usUsage = 0x02;      // mouse
  mouse.dwFlags = on ? 0 : RIDEV_REMOVE;
  mouse.hwndTarget = on ? window_ : nullptr;
  if (!RegisterRawInputDevices(&mouse, 1, sizeof(mouse)) && on) return;
  locked_ = on;
  dx_ = dy_ = 0;
  if (on) {
    Clip();
    SetTimer(window_, kFlushTimer, 10, nullptr);
  } else {
    ClipCursor(nullptr);
    KillTimer(window_, kFlushTimer);
  }
}

// Holds the cursor on a point at the window's centre, so it neither leaves
// the window nor runs into an edge while the raw movement is read.
void PointerLock::Clip() {
  RECT client;
  if (!GetClientRect(window_, &client)) return;
  POINT centre{(client.left + client.right) / 2,
               (client.top + client.bottom) / 2};
  ClientToScreen(window_, &centre);
  RECT point{centre.x, centre.y, centre.x + 1, centre.y + 1};
  ClipCursor(&point);
}

void PointerLock::Flush(bool force) {
  if (dx_ == 0 && dy_ == 0) return;
  const ULONGLONG now = GetTickCount64();
  if (!force && now - last_ < 4) return;
  last_ = now;
  channel_->InvokeMethod(
      "moved", std::make_unique<EncodableValue>(EncodableList{
                   EncodableValue(static_cast<int32_t>(dx_)),
                   EncodableValue(static_cast<int32_t>(dy_))}));
  dx_ = dy_ = 0;
}

std::optional<LRESULT> PointerLock::HandleMessage(HWND hwnd, UINT message,
                                                  WPARAM wparam,
                                                  LPARAM lparam) {
  if (!locked_) return std::nullopt;
  switch (message) {
    case WM_INPUT: {
      UINT size = 0;
      auto input = reinterpret_cast<HRAWINPUT>(lparam);
      GetRawInputData(input, RID_INPUT, nullptr, &size, sizeof(RAWINPUTHEADER));
      std::vector<BYTE> buffer(size);
      if (size > 0 &&
          GetRawInputData(input, RID_INPUT, buffer.data(), &size,
                          sizeof(RAWINPUTHEADER)) == size) {
        const auto* raw = reinterpret_cast<const RAWINPUT*>(buffer.data());
        if (raw->header.dwType == RIM_TYPEMOUSE &&
            !(raw->data.mouse.usFlags & MOUSE_MOVE_ABSOLUTE)) {
          dx_ += raw->data.mouse.lLastX;
          dy_ += raw->data.mouse.lLastY;
          Flush(false);
        }
      }
      // Default processing still cleans up after the message.
      return std::nullopt;
    }
    case WM_TIMER:
      if (wparam == kFlushTimer) {
        Flush(true);
        return 0;
      }
      break;
    case WM_MOVE:
    case WM_SIZE:
      Clip();
      break;
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) {
        Lock(false);
        channel_->InvokeMethod("unlocked", nullptr);
      }
      break;
  }
  return std::nullopt;
}
