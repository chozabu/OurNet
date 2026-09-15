// On-device transcription for OurNet: decodes a recording to 16 kHz mono
// float samples with the platform's own decoder, then runs whisper.cpp.
// Audio and text never leave this process. Every call is synchronous; Dart
// runs them on a background isolate and polls progress/cancellation.

#include "ournet_speech.h"

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "whisper.h"

#if defined(__ANDROID__)
#include <fcntl.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>
#include <unistd.h>
#elif defined(_WIN32)
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#endif

namespace {

constexpr int kRate = WHISPER_SAMPLE_RATE;

struct Session {
  whisper_context* ctx = nullptr;
  std::atomic<int> progress{0};
  std::atomic<bool> cancelled{false};
};

// Averages channels and linearly resamples interleaved samples to 16 kHz.
void Append(std::vector<float>& out, const float* data, size_t frames,
            int channels, int rate, double& position) {
  if (channels < 1 || rate < 1) return;
  const double step = static_cast<double>(rate) / kRate;
  auto sample = [&](size_t frame) {
    float sum = 0;
    for (int c = 0; c < channels; c++) sum += data[frame * channels + c];
    return sum / channels;
  };
  while (position < static_cast<double>(frames)) {
    const size_t i = static_cast<size_t>(position);
    const double t = position - i;
    const float a = sample(i);
    const float b = i + 1 < frames ? sample(i + 1) : a;
    out.push_back(static_cast<float>(a + (b - a) * t));
    position += step;
  }
  position -= static_cast<double>(frames);
}

#if defined(__ANDROID__)
int64_t Decode(const char* path, std::vector<float>& out, int64_t limit) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return OS_ERROR_OPEN;
  off_t length = lseek(fd, 0, SEEK_END);
  AMediaExtractor* extractor = AMediaExtractor_new();
  media_status_t status =
      AMediaExtractor_setDataSourceFd(extractor, fd, 0, length);
  int64_t result = OS_ERROR_FORMAT;
  AMediaCodec* codec = nullptr;
  if (status == AMEDIA_OK) {
    const size_t tracks = AMediaExtractor_getTrackCount(extractor);
    for (size_t t = 0; t < tracks && codec == nullptr; t++) {
      AMediaFormat* format = AMediaExtractor_getTrackFormat(extractor, t);
      const char* mime = nullptr;
      if (AMediaFormat_getString(format, AMEDIAFORMAT_KEY_MIME, &mime) &&
          strncmp(mime, "audio/", 6) == 0) {
        codec = AMediaCodec_createDecoderByType(mime);
        if (codec && AMediaCodec_configure(codec, format, nullptr, nullptr,
                                           0) == AMEDIA_OK &&
            AMediaCodec_start(codec) == AMEDIA_OK) {
          AMediaExtractor_selectTrack(extractor, t);
        } else if (codec) {
          AMediaCodec_delete(codec);
          codec = nullptr;
        }
      }
      AMediaFormat_delete(format);
    }
  }
  if (codec != nullptr) {
    int channels = 1, rate = kRate, encoding = 2;  // 2: PCM 16-bit
    double position = 0;
    bool inputDone = false, outputDone = false;
    std::vector<float> scratch;
    result = 0;
    while (!outputDone) {
      if (!inputDone) {
        ssize_t index = AMediaCodec_dequeueInputBuffer(codec, 10000);
        if (index >= 0) {
          size_t capacity = 0;
          uint8_t* buffer = AMediaCodec_getInputBuffer(codec, index, &capacity);
          ssize_t size = AMediaExtractor_readSampleData(extractor, buffer,
                                                        capacity);
          if (size < 0) {
            inputDone = true;
            AMediaCodec_queueInputBuffer(codec, index, 0, 0, 0,
                                         AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
          } else {
            AMediaCodec_queueInputBuffer(
                codec, index, 0, size,
                AMediaExtractor_getSampleTime(extractor), 0);
            AMediaExtractor_advance(extractor);
          }
        }
      }
      AMediaCodecBufferInfo info;
      ssize_t index = AMediaCodec_dequeueOutputBuffer(codec, &info, 10000);
      if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
        AMediaFormat* format = AMediaCodec_getOutputFormat(codec);
        AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &channels);
        AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_SAMPLE_RATE, &rate);
        AMediaFormat_getInt32(format, "pcm-encoding", &encoding);
        AMediaFormat_delete(format);
      } else if (index >= 0) {
        size_t capacity = 0;
        uint8_t* buffer = AMediaCodec_getOutputBuffer(codec, index, &capacity);
        if (buffer != nullptr && info.size > 0) {
          const uint8_t* data = buffer + info.offset;
          size_t frames;
          if (encoding == 4) {  // PCM float
            frames = info.size / (4 * channels);
            scratch.assign(frames * channels, 0);
            memcpy(scratch.data(), data, frames * channels * 4);
          } else {
            frames = info.size / (2 * channels);
            scratch.resize(frames * channels);
            for (size_t i = 0; i < frames * channels; i++) {
              int16_t v;
              memcpy(&v, data + i * 2, 2);
              scratch[i] = v / 32768.0f;
            }
          }
          Append(out, scratch.data(), frames, channels, rate, position);
        }
        AMediaCodec_releaseOutputBuffer(codec, index, false);
        if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) outputDone = true;
        if (static_cast<int64_t>(out.size()) > limit) {
          result = OS_ERROR_TOO_LONG;
          outputDone = true;
        }
      }
    }
    AMediaCodec_stop(codec);
    AMediaCodec_delete(codec);
  }
  AMediaExtractor_delete(extractor);
  close(fd);
  return result;
}
#elif defined(_WIN32)
template <typename T>
void Release(T*& value) {
  if (value) value->Release();
  value = nullptr;
}

int64_t Decode(const char* path, std::vector<float>& out, int64_t limit) {
  int wide = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
  std::wstring file(wide, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, path, -1, file.data(), wide);
  const bool com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    if (com) CoUninitialize();
    return OS_ERROR_FORMAT;
  }
  int64_t result = OS_ERROR_OPEN;
  IMFSourceReader* reader = nullptr;
  IMFMediaType* type = nullptr;
  if (SUCCEEDED(MFCreateSourceReaderFromURL(file.c_str(), nullptr, &reader))) {
    result = OS_ERROR_FORMAT;
    reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
    reader->SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);
    if (SUCCEEDED(MFCreateMediaType(&type))) {
      type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
      if (SUCCEEDED(reader->SetCurrentMediaType(
              MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, type))) {
        int channels = 1, rate = kRate;
        // The AAC decoder may announce its real output format only once
        // decoding starts, so the format is read again whenever it changes.
        auto format = [&]() {
          Release(type);
          reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM,
                                      &type);
          channels = static_cast<int>(
              MFGetAttributeUINT32(type, MF_MT_AUDIO_NUM_CHANNELS, 1));
          rate = static_cast<int>(
              MFGetAttributeUINT32(type, MF_MT_AUDIO_SAMPLES_PER_SECOND, kRate));
        };
        format();
        double position = 0;
        result = 0;
        while (true) {
          DWORD flags = 0;
          IMFSample* sample = nullptr;
          if (FAILED(reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0,
                                        nullptr, &flags, nullptr, &sample))) {
            result = OS_ERROR_FORMAT;
            break;
          }
          if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) format();
          if (sample) {
            IMFMediaBuffer* buffer = nullptr;
            if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer))) {
              BYTE* data = nullptr;
              DWORD size = 0;
              if (SUCCEEDED(buffer->Lock(&data, nullptr, &size))) {
                Append(out, reinterpret_cast<const float*>(data),
                       size / (sizeof(float) * channels), channels, rate,
                       position);
                buffer->Unlock();
              }
              Release(buffer);
            }
            Release(sample);
          }
          if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
          if (static_cast<int64_t>(out.size()) > limit) {
            result = OS_ERROR_TOO_LONG;
            break;
          }
        }
      }
    }
  }
  Release(type);
  Release(reader);
  MFShutdown();
  if (com) CoUninitialize();
  return result;
}
#else
int64_t Decode(const char*, std::vector<float>&, int64_t) {
  return OS_ERROR_UNSUPPORTED;
}
#endif

void Quiet(ggml_log_level, const char*, void*) {}

}  // namespace

int64_t os_decode(const char* path, float** samples, int32_t max_seconds) {
  *samples = nullptr;
  std::vector<float> out;
  const int64_t status =
      Decode(path, out, static_cast<int64_t>(max_seconds) * kRate);
  if (status < 0) return status;
  *samples = static_cast<float*>(malloc(sizeof(float) * (out.empty() ? 1 : out.size())));
  if (*samples == nullptr) return OS_ERROR_MEMORY;
  if (!out.empty()) memcpy(*samples, out.data(), sizeof(float) * out.size());
  return static_cast<int64_t>(out.size());
}

void* os_open(const char* model) {
  whisper_log_set(Quiet, nullptr);
  whisper_context_params params = whisper_context_default_params();
  params.use_gpu = false;
  whisper_context* ctx = whisper_init_from_file_with_params(model, params);
  if (ctx == nullptr) return nullptr;
  auto* session = new Session();
  session->ctx = ctx;
  return session;
}

int32_t os_progress(void* handle) {
  return handle ? static_cast<Session*>(handle)->progress.load() : 0;
}

void os_cancel(void* handle) {
  if (handle) static_cast<Session*>(handle)->cancelled = true;
}

int32_t os_transcribe(void* handle, const float* samples, int64_t count,
                      const char* language, int32_t threads, char** text) {
  *text = nullptr;
  auto* session = static_cast<Session*>(handle);
  if (session == nullptr || session->ctx == nullptr) return OS_ERROR_MODEL;
  session->progress = 0;
  whisper_full_params params =
      whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  params.n_threads = threads;
  params.language = language;
  params.translate = false;
  params.no_timestamps = true;
  params.print_progress = false;
  params.print_realtime = false;
  params.print_special = false;
  params.print_timestamps = false;
  params.suppress_nst = true;
  params.progress_callback = [](whisper_context*, whisper_state*, int progress,
                                void* data) {
    static_cast<Session*>(data)->progress = progress;
  };
  params.progress_callback_user_data = session;
  params.abort_callback = [](void* data) {
    return static_cast<Session*>(data)->cancelled.load();
  };
  params.abort_callback_user_data = session;
  if (whisper_full(session->ctx, params, samples, static_cast<int>(count)) != 0) {
    return session->cancelled ? OS_ERROR_CANCELLED : OS_ERROR_TRANSCRIBE;
  }
  std::string result;
  const int segments = whisper_full_n_segments(session->ctx);
  for (int i = 0; i < segments; i++) {
    const char* segment = whisper_full_get_segment_text(session->ctx, i);
    if (segment != nullptr) result += segment;
  }
  // Trim the leading space whisper places before each segment.
  const size_t start = result.find_first_not_of(" \t\n");
  result = start == std::string::npos ? "" : result.substr(start);
  *text = static_cast<char*>(malloc(result.size() + 1));
  if (*text == nullptr) return OS_ERROR_MEMORY;
  memcpy(*text, result.c_str(), result.size() + 1);
  session->progress = 100;
  return 0;
}

void os_close(void* handle) {
  auto* session = static_cast<Session*>(handle);
  if (session == nullptr) return;
  whisper_free(session->ctx);
  delete session;
}

void os_free(void* memory) { free(memory); }
