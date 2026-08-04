local colors = require("colors")

-- Center-right of the workspaces: power/lock capsule and the updates +
-- github modules (waybar's custom/updates and custom/github, mapped to
-- `brew outdated` and `gh api notifications`). Both fail soft: no brew or
-- no authed gh means the module stays hidden.

sbar.add("item", "darxk.center.pad", { position = "center", width = 12 })

local lock = sbar.add("item", "darxk.lock", {
  position = "center",
  icon = { string = "󰌾", color = colors.violet, padding_left = 9, padding_right = 9 },
  label = { drawing = false },
  click_script = "pmset displaysleepnow",
})

sbar.add("bracket", "darxk.exit.capsule", { lock.name }, {
  background = { color = colors.pill, corner_radius = 17, height = 26 },
})

sbar.add("item", "darxk.center.pad2", { position = "center", width = 12 })

local updates = sbar.add("item", "darxk.updates", {
  position = "center",
  drawing = false,
  updates = true,
  update_freq = 1800,
  icon = { string = "󰚰", color = colors.green },
  label = { color = colors.green },
  background = { color = colors.pill, corner_radius = 17, height = 26 },
  click_script = "open -a Terminal",
})
updates:subscribe({ "forced", "routine", "system_woke" }, function()
  sbar.exec("/opt/homebrew/bin/brew outdated --quiet 2>/dev/null | wc -l", function(out)
    local count = tonumber(out:match("%d+")) or 0
    local color = count == 0 and colors.green
      or (count < 10 and colors.warn or colors.red)
    updates:set({
      drawing = count > 0,
      icon = { color = color },
      label = { string = tostring(count), color = color },
    })
  end)
end)

local github = sbar.add("item", "darxk.github", {
  position = "center",
  drawing = false,
  updates = true,
  update_freq = 300,
  icon = { string = "󰊤", color = colors.text },
  label = { color = colors.text },
  background = { color = colors.pill, corner_radius = 17, height = 26 },
  click_script = "open https://github.com/notifications",
})
github:subscribe({ "forced", "routine", "system_woke" }, function()
  sbar.exec("gh api notifications --jq length 2>/dev/null", function(out)
    local count = tonumber(out:match("%d+"))
    local color = (count or 0) == 0 and colors.green or colors.warn
    github:set({
      drawing = count ~= nil and count > 0,
      icon = { color = color },
      label = { string = tostring(count or 0), color = color },
    })
  end)
end)
