-- Windows fonts standing in for the macOS pair: Segoe UI for text (the
-- system face), Cascadia Mono for numbers (ships with Windows 11).
-- Style names keep the macOS map; Heavy/Black fall back to Bold visually.
return {
  text = "Segoe UI",
  numbers = "Cascadia Mono",

  -- Unified font style map
  style_map = {
    ["Regular"] = "Regular",
    ["Semibold"] = "Semibold",
    ["Bold"] = "Bold",
    ["Heavy"] = "Bold",
    ["Black"] = "Bold",
  }
}
