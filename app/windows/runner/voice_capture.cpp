#include "voice_capture.h"

#include <audioclient.h>
#include <ksmedia.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mmdeviceapi.h>

#include <winrt/base.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {

constexpr REFERENCE_TIME kBufferDuration = 2'000'000;  // 200 ms
constexpr UINT32 kAacBytesPerSecond = 12000;           // 96 kbps

// Averages one packet of the shared-mode mix format into mono 16-bit samples.
void ToMono(const BYTE* data, UINT32 frames, const WAVEFORMATEX* format,
            bool silent, std::vector<int16_t>& out) {
  out.assign(frames, 0);
  if (silent || data == nullptr) return;
  bool is_float = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto* extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    is_float = IsEqualGUID(extensible->SubFormat,
                           KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) != 0;
  }
  const int channels = format->nChannels;
  const int bytes = format->wBitsPerSample / 8;
  for (UINT32 frame = 0; frame < frames; ++frame) {
    double sum = 0;
    for (int channel = 0; channel < channels; ++channel) {
      const BYTE* p = data + (frame * channels + channel) * bytes;
      if (is_float && bytes == 4) {
        float value;
        std::memcpy(&value, p, 4);
        sum += value;
      } else if (bytes == 2) {
        int16_t value;
        std::memcpy(&value, p, 2);
        sum += value / 32768.0;
      } else if (bytes == 3) {
        const int32_t value = p[0] | (p[1] << 8) |
                              static_cast<int32_t>(static_cast<int8_t>(p[2])) *
                                  65536;
        sum += value / 8388608.0;
      } else if (bytes == 4) {
        int32_t value;
        std::memcpy(&value, p, 4);
        sum += value / 2147483648.0;
      }
    }
    out[frame] = static_cast<int16_t>(
        std::clamp(sum / channels * 32767.0, -32768.0, 32767.0));
  }
}

winrt::com_ptr<IMFMediaType> AudioType(const GUID& subtype, UINT32 rate) {
  winrt::com_ptr<IMFMediaType> type;
  winrt::check_hresult(MFCreateMediaType(type.put()));
  winrt::check_hresult(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio));
  winrt::check_hresult(type->SetGUID(MF_MT_SUBTYPE, subtype));
  winrt::check_hresult(type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16));
  winrt::check_hresult(type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate));
  winrt::check_hresult(type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1));
  return type;
}

void WriteWavHeader(FILE* file, UINT32 rate, uint32_t data) {
  auto put32 = [&](uint32_t v) { fwrite(&v, 4, 1, file); };
  auto put16 = [&](uint16_t v) { fwrite(&v, 2, 1, file); };
  fseek(file, 0, SEEK_SET);
  fwrite("RIFF", 1, 4, file);
  put32(36 + data);
  fwrite("WAVEfmt ", 1, 8, file);
  put32(16);
  put16(1);
  put16(1);
  put32(rate);
  put32(rate * 2);
  put16(2);
  put16(16);
  fwrite("data", 1, 4, file);
  put32(data);
}

}  // namespace

struct VoiceCapture::Impl {
  winrt::com_ptr<IAudioClient> client;
  winrt::com_ptr<IAudioCaptureClient> capture;
  winrt::com_ptr<IMFSinkWriter> writer;  // Null when writing WAV.
  FILE* wav = nullptr;
  DWORD stream = 0;
  WAVEFORMATEX* format = nullptr;
  UINT32 rate = 0;
  HANDLE event = nullptr;
  std::wstring path;
  std::string mime;
  std::function<void(double)> level;
  std::atomic<bool> running{true};
  std::thread thread;
  int64_t frames = 0;
  HRESULT error = S_OK;

  ~Impl() {
    if (wav != nullptr) fclose(wav);
    if (format != nullptr) CoTaskMemFree(format);
    if (event != nullptr) CloseHandle(event);
  }

  void Write(const std::vector<int16_t>& samples) {
    if (samples.empty()) return;
    const DWORD bytes = static_cast<DWORD>(samples.size() * 2);
    if (wav != nullptr) {
      fwrite(samples.data(), 2, samples.size(), wav);
    } else {
      winrt::com_ptr<IMFMediaBuffer> buffer;
      winrt::check_hresult(MFCreateMemoryBuffer(bytes, buffer.put()));
      BYTE* target = nullptr;
      winrt::check_hresult(buffer->Lock(&target, nullptr, nullptr));
      std::memcpy(target, samples.data(), bytes);
      buffer->Unlock();
      winrt::check_hresult(buffer->SetCurrentLength(bytes));
      winrt::com_ptr<IMFSample> sample;
      winrt::check_hresult(MFCreateSample(sample.put()));
      winrt::check_hresult(sample->AddBuffer(buffer.get()));
      winrt::check_hresult(sample->SetSampleTime(frames * 10'000'000 / rate));
      winrt::check_hresult(sample->SetSampleDuration(
          static_cast<LONGLONG>(samples.size()) * 10'000'000 / rate));
      winrt::check_hresult(writer->WriteSample(stream, sample.get()));
    }
    frames += samples.size();
  }

  // Reads every captured packet into the file. Returns false on failure.
  bool Drain(std::vector<int16_t>& mono, int& peak, int64_t& peak_frames) {
    UINT32 packet = 0;
    while (SUCCEEDED(error = capture->GetNextPacketSize(&packet)) &&
           packet > 0) {
      BYTE* data = nullptr;
      UINT32 count = 0;
      DWORD flags = 0;
      error = capture->GetBuffer(&data, &count, &flags, nullptr, nullptr);
      if (FAILED(error)) return false;
      ToMono(data, count, format, (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0,
             mono);
      capture->ReleaseBuffer(count);
      Write(mono);
      for (const auto sample : mono) peak = std::max(peak, std::abs(sample));
      peak_frames += count;
      if (peak_frames >= rate / 10) {
        if (level) level(20 * std::log10(std::max(peak, 1) / 32768.0));
        peak = 0;
        peak_frames = 0;
      }
    }
    return SUCCEEDED(error);
  }

  void Run() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    std::vector<int16_t> mono;
    int peak = 0;
    int64_t peak_frames = 0;
    try {
      while (running) {
        WaitForSingleObject(event, 50);
        if (!Drain(mono, peak, peak_frames)) break;
      }
      // Keep what arrived up to the moment Stop was pressed.
      Drain(mono, peak, peak_frames);
    } catch (const winrt::hresult_error& e) {
      error = e.code();
    }
  }
};

VoiceCapture::VoiceCapture(std::unique_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

std::unique_ptr<VoiceCapture> VoiceCapture::Start(
    const std::wstring& base, std::function<void(double)> level) {
  static const HRESULT started = MFStartup(MF_VERSION, MFSTARTUP_LITE);
  winrt::check_hresult(started);
  auto impl = std::make_unique<Impl>();
  impl->level = std::move(level);

  auto devices = winrt::create_instance<IMMDeviceEnumerator>(
      __uuidof(MMDeviceEnumerator), CLSCTX_ALL);
  winrt::com_ptr<IMMDevice> device;
  winrt::check_hresult(
      devices->GetDefaultAudioEndpoint(eCapture, eConsole, device.put()));
  winrt::check_hresult(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL,
                                        nullptr, impl->client.put_void()));
  winrt::check_hresult(impl->client->GetMixFormat(&impl->format));
  impl->rate = impl->format->nSamplesPerSec;
  impl->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (impl->event == nullptr) winrt::throw_last_error();
  winrt::check_hresult(impl->client->Initialize(
      AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
      kBufferDuration, 0, impl->format, nullptr));
  winrt::check_hresult(impl->client->SetEventHandle(impl->event));
  winrt::check_hresult(
      impl->client->GetService(__uuidof(IAudioCaptureClient),
                               impl->capture.put_void()));

  // Windows' AAC encoder takes only 44.1 and 48 kHz.
  if (impl->rate == 44100 || impl->rate == 48000) {
    impl->path = base + L".m4a";
    impl->mime = "audio/mp4";
    winrt::check_hresult(MFCreateSinkWriterFromURL(
        impl->path.c_str(), nullptr, nullptr, impl->writer.put()));
    auto output = AudioType(MFAudioFormat_AAC, impl->rate);
    winrt::check_hresult(output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                                           kAacBytesPerSecond));
    winrt::check_hresult(impl->writer->AddStream(output.get(), &impl->stream));
    auto input = AudioType(MFAudioFormat_PCM, impl->rate);
    winrt::check_hresult(input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 2));
    winrt::check_hresult(
        input->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, impl->rate * 2));
    winrt::check_hresult(
        impl->writer->SetInputMediaType(impl->stream, input.get(), nullptr));
    winrt::check_hresult(impl->writer->BeginWriting());
  } else {
    impl->path = base + L".wav";
    impl->mime = "audio/wav";
    if (_wfopen_s(&impl->wav, impl->path.c_str(), L"wb") != 0) {
      winrt::throw_hresult(E_ACCESSDENIED);
    }
    WriteWavHeader(impl->wav, impl->rate, 0);
  }

  winrt::check_hresult(impl->client->Start());
  impl->thread = std::thread([raw = impl.get()] { raw->Run(); });
  return std::unique_ptr<VoiceCapture>(new VoiceCapture(std::move(impl)));
}

VoiceCapture::~VoiceCapture() {
  if (impl_ && impl_->thread.joinable()) Cancel();
}

VoiceCapture::Saved VoiceCapture::Stop() {
  impl_->running = false;
  SetEvent(impl_->event);
  impl_->thread.join();
  impl_->client->Stop();
  HRESULT hr = impl_->error;
  if (impl_->wav != nullptr) {
    WriteWavHeader(impl_->wav, impl_->rate,
                   static_cast<uint32_t>(impl_->frames * 2));
    fclose(impl_->wav);
    impl_->wav = nullptr;
  } else if (SUCCEEDED(hr)) {
    hr = impl_->frames > 0 ? impl_->writer->Finalize() : MF_E_SINK_NO_SAMPLES_PROCESSED;
  }
  impl_->writer = nullptr;
  if (FAILED(hr)) {
    DeleteFileW(impl_->path.c_str());
    winrt::throw_hresult(hr);
  }
  return {impl_->path, impl_->mime, impl_->frames * 1000 / impl_->rate};
}

void VoiceCapture::Cancel() {
  impl_->running = false;
  SetEvent(impl_->event);
  if (impl_->thread.joinable()) impl_->thread.join();
  impl_->client->Stop();
  impl_->writer = nullptr;
  if (impl_->wav != nullptr) {
    fclose(impl_->wav);
    impl_->wav = nullptr;
  }
  DeleteFileW(impl_->path.c_str());
}
