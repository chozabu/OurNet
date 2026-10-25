#include "desktop_texture.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

using BindFn = int32_t (*)(uint64_t view, void (*notify)(void*), void* context);
using LockFn = const uint8_t* (*)(uint64_t view, uint32_t* width,
                                  uint32_t* height);
using CloseFn = int32_t (*)(uint64_t view);

// One texture over one decoder. Freed once Flutter has unregistered it,
// which is also when the decoder closes: until then the raster thread may
// still be copying the decoder's last picture.
struct Texture {
  FlutterDesktopTextureRegistrarRef registrar;
  int64_t id = -1;
  uint64_t view;
  BindFn bind;
  LockFn lock;
  CloseFn close;
  FlutterDesktopPixelBuffer buffer{};
};

// On the raster thread: the newest picture, or nothing new to show.
const FlutterDesktopPixelBuffer* Copy(size_t, size_t, void* user_data) {
  auto* texture = static_cast<Texture*>(user_data);
  uint32_t width = 0, height = 0;
  const uint8_t* pixels = texture->lock(texture->view, &width, &height);
  if (pixels == nullptr || width == 0 || height == 0) return nullptr;
  texture->buffer.buffer = pixels;
  texture->buffer.width = width;
  texture->buffer.height = height;
  return &texture->buffer;
}

// On the decoder's thread, as each picture is ready.
void Notify(void* context) {
  auto* texture = static_cast<Texture*>(context);
  FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
      texture->registrar, texture->id);
}

int64_t Int(const EncodableMap& args, const char* key) {
  const auto found = args.find(EncodableValue(key));
  return found == args.end() ? 0 : found->second.LongValue();
}

}  // namespace

DesktopTextures::DesktopTextures(flutter::BinaryMessenger* messenger,
                                 FlutterDesktopTextureRegistrarRef registrar)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "ournet/desktop",
          &flutter::StandardMethodCodec::GetInstance())),
      registrar_(registrar) {
  channel_->SetMethodCallHandler(
      [registrar](const flutter::MethodCall<EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<EncodableValue>>
                      result) {
        const auto* args = std::get_if<EncodableMap>(call.arguments());
        if (args == nullptr || registrar == nullptr) {
          result->Error("bad_args", "Arguments expected");
          return;
        }
        if (call.method_name() == "create") {
          auto* texture = new Texture();
          texture->registrar = registrar;
          texture->view = static_cast<uint64_t>(Int(*args, "view"));
          texture->bind = reinterpret_cast<BindFn>(Int(*args, "bind"));
          texture->lock = reinterpret_cast<LockFn>(Int(*args, "lock"));
          texture->close = reinterpret_cast<CloseFn>(Int(*args, "close"));
          if (texture->view == 0 || !texture->bind || !texture->lock ||
              !texture->close) {
            delete texture;
            result->Error("bad_args", "No decoder");
            return;
          }
          FlutterDesktopTextureInfo info{};
          info.type = kFlutterDesktopPixelBufferTexture;
          info.pixel_buffer_config.callback = Copy;
          info.pixel_buffer_config.user_data = texture;
          texture->id =
              FlutterDesktopTextureRegistrarRegisterExternalTexture(registrar,
                                                                    &info);
          if (texture->id < 0) {
            delete texture;
            result->Error("unavailable", "No texture");
            return;
          }
          texture->bind(texture->view, Notify, texture);
          // The address travels with the ID so dispose can find it again.
          result->Success(EncodableValue(EncodableMap{
              {EncodableValue("texture"), EncodableValue(texture->id)},
              {EncodableValue("handle"),
               EncodableValue(reinterpret_cast<int64_t>(texture))},
          }));
        } else if (call.method_name() == "dispose") {
          auto* texture = reinterpret_cast<Texture*>(Int(*args, "handle"));
          if (texture == nullptr) {
            result->Error("bad_args", "No texture");
            return;
          }
          // Stops notifications (waiting for one in progress), then lets
          // Flutter finish with the texture before the decoder goes.
          texture->bind(texture->view, nullptr, nullptr);
          FlutterDesktopTextureRegistrarUnregisterExternalTexture(
              registrar, texture->id,
              [](void* user_data) {
                auto* t = static_cast<Texture*>(user_data);
                t->close(t->view);
                delete t;
              },
              texture);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

DesktopTextures::~DesktopTextures() { channel_->SetMethodCallHandler(nullptr); }
