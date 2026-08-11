find_package(Catch2 3 CONFIG REQUIRED)

add_executable(ybar_tests
  color_tests.cpp
  command_handler_tests.cpp
  command_parser_tests.cpp
  curves_tests.cpp
  event_bus_tests.cpp
  font_spec_tests.cpp
  instances_tests.cpp
  item_store_tests.cpp
  jsonc_config_tests.cpp
  layout_tests.cpp
  lua_tests.cpp
  property_setter_tests.cpp
  scheduler_tests.cpp
  socket_tests.cpp
  wire_format_tests.cpp
)
target_link_libraries(ybar_tests PRIVATE ybar_win Catch2::Catch2WithMain)

include(Catch)
catch_discover_tests(ybar_tests)
