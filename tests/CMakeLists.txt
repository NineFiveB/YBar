find_package(Catch2 3 CONFIG REQUIRED)

add_executable(ybar_tests
  wire_format_tests.cpp
)
target_link_libraries(ybar_tests PRIVATE ybar_core Catch2::Catch2WithMain)

include(Catch)
catch_discover_tests(ybar_tests)
