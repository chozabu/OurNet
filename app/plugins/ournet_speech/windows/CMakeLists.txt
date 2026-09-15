cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "ournet_speech")
project(${PROJECT_NAME} LANGUAGES C CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(ournet_speech_bundled_libraries
  $<TARGET_FILE:ournet_speech>
  PARENT_SCOPE
)
