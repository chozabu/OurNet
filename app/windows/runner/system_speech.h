#ifndef RUNNER_SYSTEM_SPEECH_H_
#define RUNNER_SYSTEM_SPEECH_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>

// Live dictation with Windows speech recognition while a voice note records.
// The recorder plugin keeps capturing the audio file; the recognizer listens
// to the same microphone in shared mode. Recognition callbacks arrive on
// thread-pool threads and are posted back to the window's thread before they
// reach Dart.
class SystemSpeech {
 public:
  static constexpr UINT kMessage = WM_APP + 0x51;

  SystemSpeech(flutter::BinaryMessenger* messenger, HWND window);
  ~SystemSpeech();

  // Runs work posted with kMessage. Returns true when the message was ours.
  static bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  struct State;
  std::shared_ptr<State> state_;
};

#endif  // RUNNER_SYSTEM_SPEECH_H_
