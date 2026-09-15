cmake_minimum_required(VERSION 3.14)

project(ournet_speech_library LANGUAGES C CXX)

# whisper.cpp and ggml are built as static CPU-only libraries into one plugin
# library. See vendor/README.md for the pinned upstream source.
# The plugin may be reached through a symlink or junction (Windows), so look
# upwards from both this file and the app for the vendored source.
if (NOT OURNET_WHISPER_DIR)
  foreach(start "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_SOURCE_DIR}")
    get_filename_component(dir "${start}" REALPATH)
    foreach(i RANGE 6)
      if (EXISTS "${dir}/vendor/whisper_cpp/CMakeLists.txt")
        set(OURNET_WHISPER_DIR "${dir}/vendor/whisper_cpp")
        break()
      endif()
      get_filename_component(dir "${dir}/.." ABSOLUTE)
    endforeach()
    if (OURNET_WHISPER_DIR)
      break()
    endif()
  endforeach()
endif()
if (NOT OURNET_WHISPER_DIR)
  message(FATAL_ERROR "vendor/whisper_cpp was not found")
endif()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
set(GGML_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
if (CMAKE_SYSTEM_PROCESSOR MATCHES "AMD64|x86_64" AND NOT ANDROID)
  # Desktop builds target AVX2-era processors (2013 onward).
  set(GGML_AVX ON CACHE BOOL "" FORCE)
  set(GGML_AVX2 ON CACHE BOOL "" FORCE)
  set(GGML_F16C ON CACHE BOOL "" FORCE)
  set(GGML_FMA ON CACHE BOOL "" FORCE)
  set(GGML_BMI2 OFF CACHE BOOL "" FORCE)
endif()
# Unoptimised whisper.cpp is many times slower than real time, so debug
# builds of the app still compile it with optimisation.
if (MSVC)
  foreach(lang C CXX)
    string(REPLACE "/RTC1" "" CMAKE_${lang}_FLAGS_DEBUG "${CMAKE_${lang}_FLAGS_DEBUG}")
    string(REPLACE "/Od" "" CMAKE_${lang}_FLAGS_DEBUG "${CMAKE_${lang}_FLAGS_DEBUG}")
    set(CMAKE_${lang}_FLAGS_DEBUG "${CMAKE_${lang}_FLAGS_DEBUG} /O2 /Ob2")
  endforeach()
endif()
add_subdirectory("${OURNET_WHISPER_DIR}" whisper EXCLUDE_FROM_ALL)

add_library(ournet_speech SHARED "ournet_speech.cpp")
set_target_properties(ournet_speech PROPERTIES
  OUTPUT_NAME "ournet_speech"
  CXX_STANDARD 17
)
target_link_libraries(ournet_speech PRIVATE whisper)
target_compile_definitions(ournet_speech PUBLIC DART_SHARED_LIB)

if (ANDROID)
  target_link_libraries(ournet_speech PRIVATE mediandk log)
  # Support Android 15 16k page size
  target_link_options(ournet_speech PRIVATE "-Wl,-z,max-page-size=16384")
elseif (WIN32)
  target_link_libraries(ournet_speech PRIVATE mfplat mfreadwrite mfuuid ole32)
endif()
