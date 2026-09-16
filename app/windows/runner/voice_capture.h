#ifndef RUNNER_VOICE_CAPTURE_H_
#define RUNNER_VOICE_CAPTURE_H_

#include <windows.h>

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>

// Records the default microphone to a file for a voice note. Built on WASAPI
// and a Media Foundation sink writer because the recorder plugin's source
// reader takes about a second to shut down, which held every note back.
// Stopping here returns within a capture period.
class VoiceCapture {
 public:
  struct Saved {
    std::wstring path;
    std::string mime;
    int64_t duration_ms;
  };

  // Starts recording to [base] plus ".m4a" (AAC), or ".wav" when the device
  // rate cannot be encoded. [level] receives the peak in dBFS about every
  // 100 ms on the capture thread. Throws winrt::hresult_error on failure.
  static std::unique_ptr<VoiceCapture> Start(
      const std::wstring& base, std::function<void(double)> level);

  ~VoiceCapture();

  // Stops and finishes the file. Throws winrt::hresult_error if it failed.
  Saved Stop();

  // Stops and deletes the file.
  void Cancel();

 private:
  struct Impl;
  explicit VoiceCapture(std::unique_ptr<Impl> impl);
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_VOICE_CAPTURE_H_
