local colors = require("colors")

-- Left edge: the apple, in Tokyo Night blue.
sbar.add("item", "tokyonight.apple", {
  position = "left",
  icon = {
    string = "\u{F0035}",
    color = colors.blue,
    padding_left = 8,
    padding_right = 8,
  },
  label = { drawing = false },
})
