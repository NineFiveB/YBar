find_package(Catch2 3 CONFIG REQUIRED)

add_executable(ybar_tests
  audit_regression_tests.cpp
  color_tests.cpp
  command_handler_tests.cpp
  command_parser_tests.cpp
  curves_tests.cpp
  event_bus_tests.cpp
  font_spec_tests.cpp
  glyph_clip_tests.cpp
  icon_map_tests.cpp
  ink_metric_tests.cpp
  instances_tests.cpp
  item_store_tests.cpp
  jsonc_config_tests.cpp
  komorebi_protocol_tests.cpp
  layout_tests.cpp
  lua_tests.cpp
  popup_layout_tests.cpp
  property_setter_tests.cpp
  provider_tests.cpp
  scheduler_tests.cpp
  socket_tests.cpp
  width_animation_tests.cpp
  wire_format_tests.cpp
)
target_link_libraries(ybar_tests PRIVATE ybar_win Catch2::Catch2WithMain)
target_compile_definitions(ybar_tests PRIVATE
  YBAR_TEST_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/fixtures")

include(Catch)
catch_discover_tests(ybar_tests)
