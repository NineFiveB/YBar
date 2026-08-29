local colors = require("colors")
local settings = require("settings")

-- komorebi integration --------------------------------------------------------
-- The macOS tree discovers AeroSpace workspaces with a synchronous CLI query
-- at config load and fights a documented boot race for it. Windows needs
-- none of that: the daemon owns komorebi detection (lazy re-attach included)
-- and publishes the focused monitor's full workspace list in the
-- komorebi_workspace_change env — WORKSPACES (newline-separated names, in
-- komorebi order) and FOCUSED_WORKSPACE / FOCUSED_WORKSPACE_INDEX.
--
-- Pills are a FIXED slot set created at load, bound to workspace names per
-- event. Creation order is bar order within a position, so slots created
-- now keep the strip left of front_app forever — an adapter that created
-- pills lazily would append them after every item loaded since.
--
-- Divergences from the macOS adapter, both data-driven:
--   * no empty-workspace hiding/collapse animation — komorebi runs a small
--     fixed workspace set per monitor (unlike AeroSpace's many named ones),
--     and the event env carries no per-workspace occupancy; every listed
--     workspace shows.
--   * no app-icon labels (sketchybar-app-font does not exist here); pills
--     show the workspace name/number only, label stays off.
-- The spaces/menus swap indicator is gone with items/menus.lua.

local MAX_SLOTS = 10

-- Leading spacer: mirrors the right edge's group-padding item so space 1
-- sits as far from the left monitor edge as the calendar pill sits from
-- the right one (bar padding + group padding on both sides).
sbar.add("item", "space.leading", { width = settings.group_paddings })

local spaces = {}    -- slot -> space item
local brackets = {}  -- slot -> bracket item

for i = 1, MAX_SLOTS do
  local space = sbar.add("item", "space." .. i, {
    icon = {
      font = { family = settings.font.numbers },
      string = tostring(i),
      padding_left = 11,
      padding_right = 11,
      color = colors.white,
      highlight_color = colors.red,
    },
    -- App-icon labels need the macOS icon font; pills show names only.
    label = { drawing = false },
    padding_right = 1,
    padding_left = 1,
    -- No background border: the bracket ring is the pill's only outline.
    background = {
      color = colors.bg1,
      border_width = 0,
      height = 23,
    },
    -- Focus by position on the focused monitor: index-based, so unnamed
    -- workspaces (published as "1","2",...) focus just as well as named.
    click_script = "ybar --komorebi '{\"type\":\"FocusWorkspaceNumber\",\"content\":"
      .. (i - 1) .. "}'",
    drawing = false,
  })
  spaces[i] = space

  -- Single item bracket for space items to achieve double border on highlight
  brackets[i] = sbar.add("bracket", { space.name }, {
    background = {
      color = colors.transparent,
      border_color = colors.bg2,
      height = 25,
      border_width = 0,
    },
  })

  -- Padding space (visibility tracks the workspace item).
  sbar.add("item", "space.padding." .. i, {
    script = "",
    width = settings.group_paddings,
    drawing = false,
  })
end

-- One repaint per event: bind names to slots, then apply the focus styling
-- (same palette as the macOS apply_focus: selected = half-grey pill + grey
-- ring, others = bg1 + bg2 ring).
local function update_spaces(env)
  local names = {}
  for name in (env.WORKSPACES or ""):gmatch("[^\n]+") do
    names[#names + 1] = name
  end
  local focused_index = tonumber(env.FOCUSED_WORKSPACE_INDEX) or 0

  for i = 1, MAX_SLOTS do
    local name = names[i]
    if name then
      local selected = (i == focused_index)
      spaces[i]:set({
        drawing = true,
        icon = { string = name, color = colors.white },
        background = {
          color = selected and colors.with_alpha(colors.grey, 0.5) or colors.bg1,
        },
      })
      brackets[i]:set({
        background = { border_color = selected and colors.grey or colors.bg2 },
      })
      sbar.set("space.padding." .. i, { drawing = true })
    else
      spaces[i]:set({ drawing = false })
      sbar.set("space.padding." .. i, { drawing = false })
    end
  end
end

local space_observer = sbar.add("item", {
  drawing = false,
  updates = true,
})

space_observer:subscribe("komorebi_workspace_change", function(env)
  update_spaces(env)
end)

-- Post-wake resync: the daemon's forced-query interception re-reads live
-- komorebi state and replays the event (spec 11.3).
space_observer:subscribe("system_woke", function()
  sbar.exec("ybar --trigger komorebi_workspace_change")
end)

-- Initial paint at config load — the same boot-population idiom, no CLI
-- probing and no retry loop: the daemon answers from live state, and if
-- komorebi is not running yet the strip simply stays hidden until the
-- daemon's lazy re-detect attaches and republishes.
sbar.exec("ybar --trigger komorebi_workspace_change")
