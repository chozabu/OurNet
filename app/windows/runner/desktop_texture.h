#ifndef RUNNER_DESKTOP_TEXTURE_H_
#define RUNNER_DESKTOP_TEXTURE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter_plugin_registrar.h>
#include <flutter_texture_registrar.h>

#include <memory>

// Shows remote desktop pictures (native/rust/src/desktop.rs) as Flutter
// textures. Dart opens a decoder and hands over where its functions are;
// the raster thread copies the newest picture straight from the decoder,
// so frames never pass through Dart. See docs/REMOTE_DESKTOP.md.
class DesktopTextures {
 public:
  DesktopTextures(flutter::BinaryMessenger* messenger,
                  FlutterDesktopTextureRegistrarRef registrar);
  ~DesktopTextures();

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  FlutterDesktopTextureRegistrarRef registrar_;
};

#endif  // RUNNER_DESKTOP_TEXTURE_H_
