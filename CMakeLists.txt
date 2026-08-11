cmake_minimum_required(VERSION 3.24)
project(ybar VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(MSVC)
  add_compile_options(/W4 /utf-8)
  # Static CRT for a self-contained ybar.exe (spec section 13).
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

option(YBAR_BUILD_TESTS "Build the Catch2 contract tests" ON)

find_package(nlohmann_json CONFIG REQUIRED)

# Platform-neutral engine code. Grows per docs/WINDOWS-PORT.md as milestones land.
add_library(ybar_core
  src/anim/curves.cpp
  src/events/event_bus.cpp
  src/ipc/command_handler.cpp
  src/ipc/command_parser.cpp
  src/ipc/wire_format.cpp
  src/model/bar_settings.cpp
  src/model/color.cpp
  src/model/font_spec.cpp
  src/model/item.cpp
  src/model/layout.cpp
  src/model/property_setter.cpp
  src/model/serialize.cpp
  src/model/style.cpp
)
target_include_directories(ybar_core PUBLIC src)
target_link_libraries(ybar_core PUBLIC nlohmann_json::nlohmann_json)

# Windows platform layer: transport, client role, daemon shell.
add_library(ybar_win
  src/app/client.cpp
  src/app/daemon.cpp
  src/ipc/socket.cpp
)
target_link_libraries(ybar_win PUBLIC ybar_core ws2_32)

add_executable(ybar src/main.cpp)
target_link_libraries(ybar PRIVATE ybar_win)

if(YBAR_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
