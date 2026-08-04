local colors = require("colors")

-- AeroSpace workspaces after the apple: plain numbers, the focused one in
-- purple on a soft rounded chip, the rest muted. Visible = non-empty or
-- focused. Fails soft: without AeroSpace no items are created.
sbar.add("event", "aerospace_workspace_change")

local aerospace = "/opt/homebrew/bin/aerospace"
if not os.execute("test -x " .. aerospace) then aerospace = "aerospace" end

local list = {}
local handle = io.popen(aerospace .. " list-workspaces --all 2>/dev/null")
if handle then
  for line in handle:lines() do
    local ws = line:match("^%s*(.-)%s*$")
    if ws ~= "" then list[#list + 1] = ws end
  end
  handle:close()
end

local spaces = {}
for _, sid in ipairs(list) do
  local space = sbar.add("item", "tokyonight.ws." .. sid, {
    position = "left",
    drawing = false,
    icon = { drawing = false },
    label = {
      string = sid,
      color = colors.muted,
      padding_left = 7,
      padding_right = 7,
    },
    padding_left = 1,
    padding_right = 1,
    background = { color = colors.transparent, corner_radius = 8, height = 22 },
    click_script = aerospace .. " workspace " .. sid,
  })
  spaces[sid] = space
end

local function refresh(focused)
  sbar.exec(aerospace .. " list-workspaces --monitor all --empty no 2>/dev/null", function(out)
    local visible = {}
    for raw in out:gmatch("[^\r\n]+") do
      local ws = raw:match("^%s*(.-)%s*$")
      if ws ~= "" then visible[ws] = true end
    end
    if focused and focused ~= "" then visible[focused] = true end
    for sid, space in pairs(spaces) do
      local selected = sid == focused
      space:set({
        drawing = visible[sid] == true,
        label = { color = selected and colors.purple or colors.muted },
        background = { color = selected and colors.chip or colors.transparent },
      })
    end
  end)
end

if next(spaces) then
  local observer = sbar.add("item", { drawing = false, updates = true, update_freq = 5 })
  observer:subscribe("aerospace_workspace_change", function(env)
    refresh(env.FOCUSED_WORKSPACE)
  end)
  observer:subscribe({ "routine", "system_woke", "front_app_switched" }, function()
    sbar.exec(aerospace .. " list-workspaces --focused 2>/dev/null", function(out)
      refresh(out:gsub("%s+", ""))
    end)
  end)
  sbar.exec(aerospace .. " list-workspaces --focused 2>/dev/null", function(out)
    refresh(out:gsub("%s+", ""))
  end)
end
