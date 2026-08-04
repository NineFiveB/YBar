local colors = require("colors")

-- Left: AeroSpace workspaces, each its own rounded block — the focused one
-- a pink block with dark text, the rest "current line" grey with light
-- text. Visible = non-empty or focused. Fails soft: without the AeroSpace
-- CLI no workspace items are created.
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
  local space = sbar.add("item", "dracula.ws." .. sid, {
    position = "left",
    drawing = false,
    icon = { drawing = false },
    label = {
      string = sid,
      color = colors.fg,
      padding_left = 9,
      padding_right = 9,
    },
    padding_left = 3,
    padding_right = 3,
    background = { color = colors.line, corner_radius = 8, height = 24 },
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
        label = { color = selected and colors.bg or colors.fg },
        background = { color = selected and colors.pink or colors.line },
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
