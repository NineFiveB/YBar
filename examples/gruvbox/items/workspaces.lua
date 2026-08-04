local colors = require("colors")

-- Left: AeroSpace workspaces as full-height gruvbox blocks — the focused
-- workspace is a yellow block with dark text, the rest are gray blocks with
-- fg text, sitting flush against each other and the bar edge. Fails soft:
-- without the aerospace CLI no workspace items are created at all.
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
  spaces[sid] = sbar.add("item", "gruvbox.ws." .. sid, {
    position = "left",
    drawing = false,
    icon = { drawing = false },
    label = {
      string = sid,
      color = colors.fg,
      padding_left = 10,
      padding_right = 10,
    },
    background = { color = colors.gray, corner_radius = 0, height = 30 },
    click_script = aerospace .. " workspace " .. sid,
  })
end

-- Visible = non-empty or focused; focused turns into the yellow block.
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
        label = { color = selected and colors.dark or colors.fg },
        background = { color = selected and colors.yellow or colors.gray },
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
