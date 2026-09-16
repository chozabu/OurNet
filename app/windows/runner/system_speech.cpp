#include "system_speech.h"

#include "voice_capture.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Media.SpeechRecognition.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cwctype>
#include <functional>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Globalization::Language;
using namespace winrt::Windows::Media::SpeechRecognition;

using Result = std::shared_ptr<flutter::MethodResult<EncodableValue>>;

std::wstring Lower(std::wstring text) {
  std::transform(text.begin(), text.end(), text.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
  return text;
}

// Picks an installed dictation language for a code such as "en", preferring
// the system speech language when it matches.
Language Resolve(const std::string& code) {
  auto system = SpeechRecognizer::SystemSpeechLanguage();
  if (code.empty() || code == "auto") return system;
  const auto prefix = Lower(std::wstring(winrt::to_hstring(code)));
  const auto matches = [&](const Language& language) {
    const auto tag = Lower(std::wstring(language.LanguageTag()));
    return tag == prefix || tag.rfind(prefix + L"-", 0) == 0;
  };
  if (matches(system)) return system;
  for (const auto& language : SpeechRecognizer::SupportedTopicLanguages()) {
    if (matches(language)) return language;
  }
  throw std::runtime_error(
      "Windows speech recognition is not installed for this language. Add "
      "it in Windows Settings > Time & language > Speech, or choose another "
      "spoken language.");
}

std::string Describe(const winrt::hresult_error& error) {
  switch (static_cast<uint32_t>(error.code())) {
    case 0x80045509:
      return "Turn on Online speech recognition in Windows Settings > "
             "Privacy & security > Speech.";
    case 0x80070005:
      return "Allow desktop apps to use the microphone in Windows Settings > "
             "Privacy & security > Microphone.";
    default: {
      char code[16];
      snprintf(code, sizeof code, "0x%08X",
               static_cast<uint32_t>(error.code()));
      return std::string("Windows speech recognition is unavailable (") +
             code + ").";
    }
  }
}

std::string Describe(SpeechRecognitionResultStatus status) {
  switch (status) {
    case SpeechRecognitionResultStatus::MicrophoneUnavailable:
      return "The microphone is unavailable to Windows speech recognition.";
    case SpeechRecognitionResultStatus::NetworkFailure:
      return "Windows speech recognition lost its network connection.";
    case SpeechRecognitionResultStatus::AudioQualityFailure:
      return "Windows speech recognition could not hear clearly.";
    case SpeechRecognitionResultStatus::TimeoutExceeded:
      return "Windows speech recognition heard nothing for too long.";
    case SpeechRecognitionResultStatus::TopicLanguageNotSupported:
      return "Windows speech recognition does not support this language.";
    default:
      return "Windows speech recognition stopped (status " +
             std::to_string(static_cast<int>(status)) + ").";
  }
}

// Whether "Online speech recognition" is on in Windows privacy settings, which
// dictation needs. A person turning it on has agreed to Microsoft's terms.
bool OnlineSpeechAllowed() {
  DWORD accepted = 0;
  DWORD size = sizeof accepted;
  return RegGetValueW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Speech_OneCore\\Settings\\"
                      L"OnlineSpeechPrivacy",
                      L"HasAccepted", RRF_RT_REG_DWORD, nullptr, &accepted,
                      &size) == ERROR_SUCCESS &&
         accepted == 1;
}

std::string StringArgument(const flutter::MethodCall<EncodableValue>& call,
                           const char* name, std::string fallback) {
  if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
    const auto found = args->find(EncodableValue(name));
    if (found != args->end()) {
      if (const auto* value = std::get_if<std::string>(&found->second)) {
        return *value;
      }
    }
  }
  return fallback;
}

}  // namespace

struct SystemSpeech::State {
  HWND window;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  bool closed = false;  // Only touched on the window thread.

  std::mutex mutex;  // Guards everything below.
  std::condition_variable changed;  // Signalled as recognition progresses.
  std::unique_ptr<VoiceCapture> capture;
  SpeechRecognizer recognizer{nullptr};
  // Compiling dictation takes over a second, so one is kept ready for the
  // next recording rather than missing its first words.
  SpeechRecognizer prepared{nullptr};
  std::string preparedLanguage;
  bool preparing = false;
  std::string language;  // Of the current or last session.
  uint64_t session = 0;
  std::wstring committed, hypothesis;
  bool failed = false, stopping = false;
  int restarts = 0;

  // Runs [work] on the window thread, where the channel may be used.
  static void Post(const std::shared_ptr<State>& state,
                   std::function<void(State&)> work) {
    auto task = new std::function<void()>(
        [weak = std::weak_ptr<State>(state), work = std::move(work)] {
          if (auto s = weak.lock(); s && !s->closed) work(*s);
        });
    if (!PostMessage(state->window, kMessage, 0,
                     reinterpret_cast<LPARAM>(task))) {
      delete task;
    }
  }

  static void Reply(const std::shared_ptr<State>& state, Result result,
                    EncodableValue value) {
    Post(state, [result, value = std::move(value)](State&) {
      result->Success(value);
    });
  }

  static void Fail(const std::shared_ptr<State>& state, Result result,
                   std::string message) {
    Post(state, [result, message = std::move(message)](State&) {
      result->Error("speech", message);
    });
  }

  // Sends the transcript so far. Call with the mutex held.
  void Partial(const std::shared_ptr<State>& self) {
    auto text = committed;
    if (!hypothesis.empty()) text += (text.empty() ? L"" : L" ") + hypothesis;
    Post(self, [text = winrt::to_string(text)](State& s) {
      s.channel->InvokeMethod(
          "livePartial",
          std::make_unique<EncodableValue>(
              EncodableMap{{EncodableValue("text"), EncodableValue(text)}}));
    });
  }

  // Creates a dictation recognizer for [code] with timeouts long enough for
  // pauses in a voice note. Blocks while compiling.
  static SpeechRecognizer Create(const std::string& code) {
    SpeechRecognizer recognizer(Resolve(code));
    recognizer.Constraints().Append(SpeechRecognitionTopicConstraint(
        SpeechRecognitionScenario::Dictation, L"dictation"));
    const auto compiled = recognizer.CompileConstraintsAsync().get();
    if (compiled.Status() != SpeechRecognitionResultStatus::Success) {
      recognizer.Close();
      throw std::runtime_error(Describe(compiled.Status()));
    }
    recognizer.Timeouts().InitialSilenceTimeout(std::chrono::minutes(30));
    recognizer.Timeouts().BabbleTimeout(std::chrono::minutes(30));
    recognizer.ContinuousRecognitionSession().AutoStopSilenceTimeout(
        std::chrono::minutes(30));
    return recognizer;
  }

  // Compiles a recognizer for [code] in the background for the next Start.
  static void Prepare(std::shared_ptr<State> self, std::string code) {
    {
      std::lock_guard lock(self->mutex);
      if (self->preparing ||
          (self->prepared && self->preparedLanguage == code)) {
        return;
      }
      self->preparing = true;
    }
    std::thread([self, code] {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      SpeechRecognizer recognizer{nullptr};
      try {
        recognizer = Create(code);
      } catch (...) {
        // Start reports the problem when it creates one itself.
      }
      std::lock_guard lock(self->mutex);
      self->preparing = false;
      if (!recognizer) return;
      if (self->prepared) self->prepared.Close();
      self->prepared = recognizer;
      self->preparedLanguage = code;
    }).detach();
  }

  static void SendEvent(const std::shared_ptr<State>& self, const char* name,
                        EncodableMap arguments = {}) {
    Post(self, [name, arguments = std::move(arguments)](State& state) {
      state.channel->InvokeMethod(
          name, std::make_unique<EncodableValue>(arguments));
    });
  }

  // Starts a voice note: recording to [base] (when given) at once, replying
  // as soon as audio is being captured, while dictation connects (about a
  // second) and reports `liveReady` or `liveError`. Without [base], replies
  // once dictation listens.
  static void Start(std::shared_ptr<State> self, std::string code,
                    std::wstring base, Result result) {
    uint64_t id;
    SpeechRecognizer ready{nullptr};
    {
      std::lock_guard lock(self->mutex);
      id = ++self->session;
      self->language = code;
      self->committed.clear();
      self->hypothesis.clear();
      self->failed = self->stopping = false;
      self->restarts = 0;
      if (self->prepared && self->preparedLanguage == code) {
        std::swap(ready, self->prepared);
      }
    }
    std::thread([self, code, base, result, id, ready] {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      std::weak_ptr<State> weak = self;
      if (!base.empty()) {
        try {
          auto capture = VoiceCapture::Start(base, [weak](double decibels) {
            if (auto s = weak.lock()) {
              SendEvent(s, "liveLevel",
                        {{EncodableValue("level"), EncodableValue(decibels)}});
            }
          });
          std::lock_guard lock(self->mutex);
          if (self->session != id) {
            capture->Cancel();
            if (ready) ready.Close();
            Fail(self, result, "Recording was cancelled.");
            return;
          }
          self->capture = std::move(capture);
        } catch (const winrt::hresult_error& error) {
          if (ready) ready.Close();
          Fail(self, result,
               error.code() == E_ACCESSDENIED
                   ? Describe(error)
                   : "Recording is unavailable: " +
                         winrt::to_string(error.message()));
          return;
        }
        Reply(self, result, EncodableValue());
      }
      try {
        auto recognizer = ready ? ready : Create(code);
        auto session = recognizer.ContinuousRecognitionSession();
        recognizer.HypothesisGenerated(
            [weak, id](const auto&, const auto& args) {
              auto s = weak.lock();
              if (!s) return;
              std::lock_guard lock(s->mutex);
              if (s->session != id) return;
              s->hypothesis = args.Hypothesis().Text();
              s->Partial(s);
              s->changed.notify_all();
            });
        session.ResultGenerated([weak, id](const auto&, const auto& args) {
          auto s = weak.lock();
          if (!s) return;
          std::lock_guard lock(s->mutex);
          if (s->session != id) return;
          s->hypothesis.clear();
          const auto result = args.Result();
          if (result.Confidence() != SpeechRecognitionConfidence::Rejected &&
              !result.Text().empty()) {
            if (!s->committed.empty()) s->committed += L" ";
            s->committed += result.Text();
          }
          s->Partial(s);
          s->changed.notify_all();
        });
        session.Completed([weak, id, session](const auto&, const auto& args) {
          auto s = weak.lock();
          if (!s) return;
          std::lock_guard lock(s->mutex);
          if (s->session != id || s->stopping ||
              args.Status() == SpeechRecognitionResultStatus::Success) {
            return;
          }
          const auto status = args.Status();
          if ((status == SpeechRecognitionResultStatus::TimeoutExceeded ||
               status == SpeechRecognitionResultStatus::PauseLimitExceeded ||
               status == SpeechRecognitionResultStatus::UserCanceled) &&
              ++s->restarts <= 5) {
            // Windows ends dictation after long silences and occasionally on
            // its own; keep listening for the rest of the note.
            std::thread([weak, id, session] {
              winrt::init_apartment(winrt::apartment_type::multi_threaded);
              try {
                session.StartAsync().get();
              } catch (const winrt::hresult_error& error) {
                if (auto s = weak.lock()) Failed(s, id, Describe(error));
              }
            }).detach();
            return;
          }
          s->failed = true;
          s->changed.notify_all();
          Post(s, [message = Describe(status)](State& state) {
            state.channel->InvokeMethod(
                "liveError",
                std::make_unique<EncodableValue>(EncodableMap{
                    {EncodableValue("message"), EncodableValue(message)}}));
          });
        });
        {
          std::lock_guard lock(self->mutex);
          if (self->session != id) {
            recognizer.Close();
            if (base.empty()) Fail(self, result, "Dictation was cancelled.");
            return;
          }
          self->recognizer = recognizer;
        }
        session.StartAsync().get();
        if (base.empty()) {
          Reply(self, result, EncodableValue());
        } else {
          SendEvent(self, "liveReady");
        }
      } catch (const winrt::hresult_error& error) {
        Abandon(self, id);
        if (base.empty()) {
          Fail(self, result, Describe(error));
        } else {
          Failed(self, id, Describe(error));
        }
      } catch (const std::exception& error) {
        Abandon(self, id);
        if (base.empty()) {
          Fail(self, result, error.what());
        } else {
          Failed(self, id, error.what());
        }
      }
    }).detach();
  }

  // Reports that session [id] stopped listening part-way.
  static void Failed(const std::shared_ptr<State>& self, uint64_t id,
                     std::string message) {
    {
      std::lock_guard lock(self->mutex);
      if (self->session != id || self->stopping) return;
      self->failed = true;
    }
    self->changed.notify_all();
    Post(self, [message = std::move(message)](State& state) {
      state.channel->InvokeMethod(
          "liveError",
          std::make_unique<EncodableValue>(EncodableMap{
              {EncodableValue("message"), EncodableValue(message)}}));
    });
  }

  // Ends session [id] after a failed start.
  static void Abandon(const std::shared_ptr<State>& self, uint64_t id) {
    std::lock_guard lock(self->mutex);
    if (self->session != id || !self->recognizer) return;
    self->recognizer.Close();
    self->recognizer = nullptr;
  }

  // Stops recording and listening. Replies with the file and the text heard,
  // or null text if dictation failed. The audio stops within a capture
  // period. Dictation's last phrase is usually recognised already; otherwise
  // this waits at most [settle] for it. Windows takes over a second to close
  // a session, which happens in the background.
  static void Stop(std::shared_ptr<State> self, bool cancel,
                   std::chrono::milliseconds settle, Result result) {
    std::thread([self, cancel, settle, result] {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      std::unique_ptr<VoiceCapture> capture;
      SpeechRecognizer recognizer{nullptr};
      std::string language;
      {
        std::lock_guard lock(self->mutex);
        capture = std::move(self->capture);
        recognizer = self->recognizer;
        language = self->language;
        self->stopping = true;
      }
      EncodableMap reply;
      std::string recording_error;
      if (capture && cancel) {
        capture->Cancel();
      } else if (capture) {
        try {
          const auto saved = capture->Stop();
          reply[EncodableValue("path")] =
              EncodableValue(winrt::to_string(saved.path));
          reply[EncodableValue("mime")] = EncodableValue(saved.mime);
          reply[EncodableValue("duration")] =
              EncodableValue(static_cast<int32_t>(saved.duration_ms));
        } catch (const winrt::hresult_error& error) {
          recording_error =
              "Recording failed: " + winrt::to_string(error.message());
        }
      }
      EncodableValue text;
      winrt::Windows::Foundation::IAsyncAction ending{nullptr};
      if (recognizer) {
        try {
          auto session = recognizer.ContinuousRecognitionSession();
          ending = cancel ? session.CancelAsync() : session.StopAsync();
        } catch (const winrt::hresult_error&) {
          // The session already ended, e.g. after a failure reported earlier.
        }
      }
      {
        std::unique_lock lock(self->mutex);
        if (recognizer && !cancel) {
          self->changed.wait_for(lock, settle, [&] {
            return self->hypothesis.empty() || self->failed;
          });
          auto words = self->committed;
          if (!self->hypothesis.empty()) {
            words += (words.empty() ? L"" : L" ") + self->hypothesis;
          }
          if (!self->failed) text = EncodableValue(winrt::to_string(words));
        }
        // Ignores late results, and abandons dictation still connecting.
        ++self->session;
        if (self->recognizer == recognizer) self->recognizer = nullptr;
      }
      if (recognizer) {
        std::thread([self, recognizer, ending, cancel, language] {
          winrt::init_apartment(winrt::apartment_type::multi_threaded);
          try {
            if (ending) ending.wait_for(std::chrono::seconds(5));
          } catch (const winrt::hresult_error&) {
          }
          recognizer.Close();
          if (!cancel) Prepare(self, language);
        }).detach();
      }
      if (!recording_error.empty()) {
        Fail(self, result, recording_error);
      } else {
        reply[EncodableValue("text")] = text;
        Reply(self, result, reply);
      }
    }).detach();
  }
};

SystemSpeech::SystemSpeech(flutter::BinaryMessenger* messenger, HWND window)
    : state_(std::make_shared<State>()) {
  state_->window = window;
  state_->channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "ournet/speech",
      &flutter::StandardMethodCodec::GetInstance());
  std::weak_ptr<State> weak = state_;
  state_->channel->SetMethodCallHandler([weak](const auto& call,
                                               auto reply) {
    auto state = weak.lock();
    if (!state) return;
    Result result(std::move(reply));
    const auto& method = call.method_name();
    if (method == "liveStatus") {
      const auto language = StringArgument(call, "language", "auto");
      if (OnlineSpeechAllowed()) State::Prepare(state, language);
      std::thread([state, result] {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        bool available = false;
        try {
          available = SpeechRecognizer::SupportedTopicLanguages().Size() > 0;
        } catch (const winrt::hresult_error&) {
        }
        State::Reply(state, result,
                     EncodableMap{
                         {EncodableValue("available"), EncodableValue(available)},
                         {EncodableValue("allowed"),
                          EncodableValue(OnlineSpeechAllowed())},
                     });
      }).detach();
    } else if (method == "liveStart") {
      const auto base = StringArgument(call, "path", "");
      State::Start(state, StringArgument(call, "language", "auto"),
                   base.empty() ? std::wstring()
                                : std::wstring(winrt::to_hstring(base)),
                   result);
    } else if (method == "liveStop" || method == "liveCancel") {
      int settle = 1500;
      if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
        const auto found = args->find(EncodableValue("settle"));
        if (found != args->end()) {
          if (const auto* value = std::get_if<int32_t>(&found->second)) {
            settle = *value;
          }
        }
      }
      State::Stop(state, method == "liveCancel",
                  std::chrono::milliseconds(settle), result);
    } else {
      result->NotImplemented();
    }
  });
}

SystemSpeech::~SystemSpeech() {
  state_->closed = true;
  {
    std::lock_guard lock(state_->mutex);
    if (state_->prepared) state_->prepared.Close();
    state_->prepared = nullptr;
  }
  state_->channel->SetMethodCallHandler(nullptr);
  State::Stop(state_, true, std::chrono::milliseconds(0),
              std::make_shared<flutter::MethodResultFunctions<EncodableValue>>(
                  nullptr, nullptr, nullptr));
}

bool SystemSpeech::HandleMessage(UINT message, WPARAM, LPARAM lparam) {
  if (message != kMessage) return false;
  std::unique_ptr<std::function<void()>> task(
      reinterpret_cast<std::function<void()>*>(lparam));
  (*task)();
  return true;
}
