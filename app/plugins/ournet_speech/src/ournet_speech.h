#pragma once

#include <stdint.h>

#if defined(_WIN32)
#define OS_EXPORT __declspec(dllexport)
#else
#define OS_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define OS_ERROR_OPEN -1
#define OS_ERROR_FORMAT -2
#define OS_ERROR_TOO_LONG -3
#define OS_ERROR_MEMORY -4
#define OS_ERROR_UNSUPPORTED -5
#define OS_ERROR_MODEL -6
#define OS_ERROR_TRANSCRIBE -7
#define OS_ERROR_CANCELLED -8

// Decodes an audio file to 16 kHz mono samples. Returns the sample count, or
// a negative OS_ERROR. Free *samples with os_free.
OS_EXPORT int64_t os_decode(const char* path, float** samples,
                            int32_t max_seconds);

// Loads a whisper.cpp model. Returns null when it cannot be loaded.
OS_EXPORT void* os_open(const char* model);

// 0-100 while os_transcribe runs; safe to call from another thread.
OS_EXPORT int32_t os_progress(void* session);

// Stops a running os_transcribe; safe to call from another thread.
OS_EXPORT void os_cancel(void* session);

// Transcribes samples. language is a code such as "en", or "auto". Returns 0
// and a UTF-8 *text to free with os_free, or a negative OS_ERROR.
OS_EXPORT int32_t os_transcribe(void* session, const float* samples,
                                int64_t count, const char* language,
                                int32_t threads, char** text);

OS_EXPORT void os_close(void* session);
OS_EXPORT void os_free(void* memory);

#ifdef __cplusplus
}
#endif
