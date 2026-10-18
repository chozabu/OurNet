#ifndef RUNNER_NOISE_SUPPRESSION_H_
#define RUNNER_NOISE_SUPPRESSION_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Puts the native library's RNNoise denoiser (native/rust/src/denoise.rs) in
// flutter_webrtc's capture hook when Dart asks ("attach", with the address
// of ournet_denoise_process). The denoiser itself does nothing while it is
// switched off in Dart.
class NoiseSuppression {
 public:
  explicit NoiseSuppression(flutter::BinaryMessenger* messenger);
  ~NoiseSuppression();

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_NOISE_SUPPRESSION_H_
