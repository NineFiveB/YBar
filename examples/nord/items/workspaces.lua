local colors = require("colors")

-- Left edge: AeroSpace workspaces as plain Nord numbers. The focused one is
-- bright snow-storm white on a subtly raised polar-night chip (rounded 4);
-- the rest are muted bare digits with no chip. Fails soft when AeroSpace is
-- absent: the workspace list comes back empty and nothing draws.
sbar.add("event", "aerospace_workspace_change")

local aerospace = "/opt/homebrew/bin/aerospace"
if not os.execute("test -x " .. aerospace) then
  aerospace = "/usr/local/bin/aerospace"
  if not os.execute("test -x " .. aerospace) then aerospace = "aerospace" end
end

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
  local space = sbar.add("item", "nord.ws." .. sid, {
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
    background = { color = colors.transparent, corner_radius = 4, height = 20 },
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
        label = { color = selected and colors.bright or colors.muted },
        background = { color = selected and colors.chip or colors.transparent },
      })
    end
  end)
end

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
