local colors = require("colors")

-- Left edge: AeroSpace workspaces as quiet dots — a filled foam circle for
-- the focused workspace, small muted outline circles for the rest.
-- Clickable. Fails soft: no AeroSpace, no dots.
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

local DOT       = "\u{F0765}"  -- circle
local DOT_FAINT = "\u{F0766}"  -- circle-outline

local spaces = {}
for _, sid in ipairs(list) do
  spaces[sid] = sbar.add("item", "rosepine.ws." .. sid, {
    position = "left",
    drawing = false,
    icon = {
      string = DOT_FAINT,
      color = colors.muted,
      font = { family = FONT, style = "Regular", size = 9.0 },
      padding_left = 3,
      padding_right = 3,
    },
    label = { drawing = false },
    padding_left = 1,
    padding_right = 1,
    click_script = aerospace .. " workspace " .. sid,
  })
end

-- Visible = non-empty or focused; the focused dot fills in foam and grows a
-- touch, the rest stay faint.
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
        icon = {
          string = selected and DOT or DOT_FAINT,
          color = selected and colors.foam or colors.muted,
          font = { family = FONT, style = "Regular", size = selected and 12.0 or 9.0 },
        },
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
