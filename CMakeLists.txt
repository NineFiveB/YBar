cmake_minimum_required(VERSION 3.24)
project(ybar VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(MSVC)
  add_compile_options(/W4 /utf-8)
  add_compile_definitions(_CRT_SECURE_NO_WARNINGS)
  # Static CRT for a self-contained ybar.exe (spec section 13).
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

option(YBAR_BUILD_TESTS "Build the Catch2 contract tests" ON)

find_package(nlohmann_json CONFIG REQUIRED)

# Vendored Lua 5.4 (ISO C; luaconf.h auto-detects _WIN32 — spec D6).
file(GLOB LUA_VENDOR_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/src/lua/vendor/*.c)
add_library(lua_vendor STATIC ${LUA_VENDOR_SOURCES})
target_include_directories(lua_vendor PUBLIC src/lua/vendor)
if(MSVC)
  target_compile_options(lua_vendor PRIVATE /W1) # vendored code, not ours
endif()

# Platform-neutral engine code. Grows per docs/WINDOWS-PORT.md as milestones land.
add_library(ybar_core
  src/anim/curves.cpp
  src/anim/scheduler.cpp
  src/events/event_bus.cpp
  src/ipc/command_handler.cpp
  src/ipc/command_parser.cpp
  src/ipc/wire_format.cpp
  src/model/bar_settings.cpp
  src/model/color.cpp
  src/model/font_spec.cpp
  src/model/item.cpp
  src/model/layout.cpp
  src/model/popup_layout.cpp
  src/model/property_setter.cpp
  src/model/serialize.cpp
  src/model/style.cpp
)
target_include_directories(ybar_core PUBLIC src)
target_link_libraries(ybar_core PUBLIC nlohmann_json::nlohmann_json)

# Windows platform layer: transport, client role, daemon shell, windowing,
# and the D3D11/DirectWrite render stack.
add_library(ybar_win
  src/app/client.cpp
  src/app/config.cpp
  src/app/daemon.cpp
  src/app/jsonc_config.cpp
  src/app/script_runner.cpp
  src/ipc/socket.cpp
  src/lua/runtime.cpp
  src/providers/komorebi.cpp
  src/providers/ytile.cpp
  src/render/font_cache.cpp
  src/render/glyph_atlas.cpp
  src/render/icon_map.cpp
  src/render/renderer.cpp
  src/render/scene_builder.cpp
  src/win/bar_surface.cpp
  src/win/popup_surface.cpp
  src/win/display_manager.cpp
)
target_link_libraries(ybar_win PUBLIC ybar_core lua_vendor
  ws2_32 d3d11 dxgi d3dcompiler dcomp dwrite shcore user32 gdi32
  windowscodecs ole32 shell32)

add_executable(ybar src/main.cpp)
target_link_libraries(ybar PRIVATE ybar_win)

if(YBAR_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
