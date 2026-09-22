-- Glass theme font map: Apple's system font everywhere. The port pairs
-- SF Pro with SF Mono for numerals; the native menu bar uses SF Pro for
-- both, so the glass theme does too (shadows the port's helpers/ module
-- via package.path precedence).
return {
  text = "SF Pro",
  numbers = "SF Pro",

  style_map = {
    ["Regular"] = "Regular",
    ["Semibold"] = "Semibold",
    ["Bold"] = "Bold",
    ["Heavy"] = "Heavy",
    ["Black"] = "Black",
  }
}
