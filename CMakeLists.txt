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

# Platform-neutral engine code. Grows per docs/WINDOWS-PORT.md as milestones land.
add_library(ybar_core
  src/anim/curves.cpp
  src/ipc/command_parser.cpp
  src/ipc/wire_format.cpp
  src/model/color.cpp
  src/model/font_spec.cpp
  src/model/item.cpp
  src/model/property_setter.cpp
  src/model/style.cpp
)
target_include_directories(ybar_core PUBLIC src)

add_executable(ybar src/main.cpp)
target_link_libraries(ybar PRIVATE ybar_core)

if(YBAR_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
