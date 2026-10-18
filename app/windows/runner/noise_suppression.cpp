#include "noise_suppression.h"

#include <flutter/standard_method_codec.h>

#include <atomic>
#include <cstdint>

#include "flutter_webrtc.h"
#include "flutter_webrtc/flutter_web_r_t_c_plugin.h"
#include "rtc_audio_processing.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using DenoiseFn = int32_t (*)(float* buffer, size_t frames, int32_t rate);

// Runs on WebRTC's audio thread after its own echo cancelling and noise
// suppression, on the full-band first channel of each 10 ms frame. Lives
// for the whole process, so the hook never points at a freed object.
class Denoiser : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  std::atomic<DenoiseFn> process{nullptr};

  void Initialize(int sample_rate_hz, int) override { rate_ = sample_rate_hz; }

  void Process(int, int num_frames, int buffer_size, float* buffer) override {
    const auto run = process.load();
    if (run && buffer && num_frames > 0 && buffer_size >= num_frames) {
      run(buffer, static_cast<size_t>(num_frames), rate_.load());
    }
  }

  void Reset(int new_rate) override { rate_ = new_rate; }

  void Release() override {}

 private:
  std::atomic<int> rate_{48000};
};

Denoiser* denoiser = new Denoiser();
bool attached = false;

}  // namespace

NoiseSuppression::NoiseSuppression(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "ournet/denoise",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (call.method_name() != "attach") {
      result->NotImplemented();
      return;
    }
    int64_t address = 0;
    if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
      const auto found = args->find(EncodableValue("process"));
      if (found != args->end()) address = found->second.LongValue();
    }
    auto* webrtc = FlutterWebRTCPluginSharedInstance();
    if (address == 0 || webrtc == nullptr) {
      result->Error("unavailable", "No native library or WebRTC plugin");
      return;
    }
    denoiser->process = reinterpret_cast<DenoiseFn>(address);
    if (!attached) {
      auto processing = webrtc->audio_processing();
      if (!processing.get()) {
        result->Error("unavailable", "WebRTC has no audio processing");
        return;
      }
      processing->SetCapturePostProcessing(denoiser);
      attached = true;
    }
    result->Success();
  });
}

NoiseSuppression::~NoiseSuppression() {
  channel_->SetMethodCallHandler(nullptr);
}
