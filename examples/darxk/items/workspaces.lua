local colors = require("colors")

-- Center: AeroSpace workspaces in the waybar style — a dark outer capsule,
-- each workspace a small rounded button, the focused one inverted (light
-- background, dark text, wider). Visible = non-empty or focused.
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
local names = {}
for _, sid in ipairs(list) do
  local space = sbar.add("item", "darxk.ws." .. sid, {
    position = "center",
    drawing = false,
    icon = { drawing = false },
    label = {
      string = sid,
      color = colors.text,
      padding_left = 8,
      padding_right = 8,
    },
    padding_left = 3,
    padding_right = 3,
    background = { color = colors.pill, corner_radius = 13, height = 20 },
    click_script = aerospace .. " workspace " .. sid,
  })
  spaces[sid] = space
  names[#names + 1] = space.name
end

if #names > 0 then
  sbar.add("bracket", "darxk.ws.capsule", names, {
    background = { color = colors.ws_bg, corner_radius = 17, height = 30 },
  })
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
        label = {
          color = selected and colors.text_dark or colors.text,
          padding_left = selected and 14 or 8,
          padding_right = selected and 14 or 8,
        },
        background = { color = selected and colors.light or colors.pill },
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
