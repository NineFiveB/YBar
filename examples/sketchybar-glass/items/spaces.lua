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

  -- The outer half of the focus ring. Inset 1pt taller than the pill (25 vs
  -- 23) AND 1pt wider on each side, so its stroke sits one point outside the
  -- pill's own stroke on all four edges rather than only above and below —
  -- without the padding the two rings share the left and right edges and the
  -- dimmer one paints over the brighter, so the ring reads uneven.
  brackets[i] = sbar.add("bracket", { space.name }, {
    background = {
      color = colors.transparent,
      border_color = colors.transparent,
      height = 25,
      border_width = 0,
    },
    padding_left = 1,
    padding_right = 1,
  })

  -- Padding space (visibility tracks the workspace item).
  sbar.add("item", "space.padding." .. i, {
    script = "",
    width = settings.group_paddings,
    drawing = false,
  })
end

-- A workspace pill's fill has TWO inputs — focus and hover — so both go
-- through one function. Painting them independently would let a workspace
-- change repaint a pill the pointer is still sitting on, dropping the
-- highlight until the pointer moved again.
local hover = require("helpers.hover")
local hovered = {}   -- slot -> pointer is over this pill
local focused = 0    -- slot index of the focused workspace, 0 = none

local function space_color(i)
  -- Focus outranks hover: the selected pill is already the brightest state
  -- in the strip, and lifting it further would read as a second selection.
  if i == focused then return colors.with_alpha(colors.grey, 0.5) end
  return hovered[i] and colors.bg2 or colors.bg1
end

-- Focus is fill + halo. There is deliberately no outline.
--
-- This used to be a ring in two stops -- a bright 1pt stroke on the pill edge
-- and a dim one on the bracket's box a point outside it -- and that existed
-- ONLY because the engine had no blur: a border is a hard band with a
-- one-pixel analytic feather, and there was no bloom pass anywhere, so a
-- falloff had to be faked out of the two quads a pill already owned.
--
-- background.shadow.blur supplies the real falloff now (a shadow quad grown by
-- the blur radius, squared ramp; a LIGHT colour at zero offset IS a glow), so
-- the fake one was drawing the same idea a second time. Keeping both put three
-- treatments on one edge -- crisp stroke, dim stroke, halo -- on top of the
-- bevel rim that already lights that edge, which is what made the focused pill
-- read as busy against its flat neighbours. The strokes go; the halo stays.
local FOCUS_FRAMES = 8
-- Two focus cues, each one flag. Bevel is the shipped one: the active
-- workspace is the glass pill -- on Windows a Mica material under its 50%
-- grey fill, with the quarter-round rim lit from above -- and every other
-- pill stays flat, so focus reads as material rather than as decoration on
-- top of it. The halo is kept for one-line return. glass is a bool and cannot
-- ease, so it flips at the moment of switch while the fill still animates
-- underneath it.
local FOCUS_BEVEL = true
local FOCUS_HALO = false
local GLOW = colors.with_alpha(colors.white, 0.42)
local GLOW_BLUR = 6

-- Paint one slot's WHOLE surface: fill and halo, from both
-- inputs at once. Focus and hover used to own separate writes to the same
-- background, which was already a hazard for the fill alone; with elevation on
-- the same property it becomes a correctness bug, because a workspace change
-- would drop the lift out from under a pointer that has not moved. One
-- writer, every time.
--
-- Flat by design: hover changes the fill only. The elevation variant (bevel
-- gradient + lift, with the bracket lifting alongside so the hover seam's two
-- boxes stay aligned) is what the README's depth GIFs show, not what ships.
local function paint_space(i, frames)
  local on = (i == focused)
  local color = space_color(i) -- hover is folded into the colour; no lift
  sbar.animate("sin", frames or FOCUS_FRAMES, function()
    spaces[i]:set({
      background = {
        color = color,
        glass = on and FOCUS_BEVEL,
        -- drawing stays ON in both states so only the COLOUR animates: the
        -- shadow's alpha is animatable and its drawing flag is not, so
        -- toggling the flag would pop the halo in and out instead of easing
        -- it alongside the fill.
        shadow = {
          drawing = true,
          color = (on and FOCUS_HALO) and GLOW or colors.transparent,
          distance = 0,
          blur = GLOW_BLUR,
        },
      },
    })
  end)
end

for i = 1, MAX_SLOTS do
  local function set_hover(on)
    hovered[i] = on or nil
    paint_space(i, on and hover.ENTER_FRAMES or hover.EXIT_FRAMES)
  end
  -- Both the pill and its ring bracket, for the seam described in helpers/hover.
  for _, w in ipairs({ spaces[i], brackets[i] }) do
    w:subscribe("mouse.entered", function() set_hover(true) end)
    w:subscribe("mouse.exited", function() set_hover(false) end)
  end
end

-- One repaint per event: bind names to slots, then ease every slot's focus
-- state. The fill used to snap here while the decorative hover on the same
-- property eased — backwards, since the fill is the load-bearing signal.
local function update_spaces(env)
  local names = {}
  for name in (env.WORKSPACES or ""):gmatch("[^\n]+") do
    names[#names + 1] = name
  end
  focused = tonumber(env.FOCUSED_WORKSPACE_INDEX) or 0

  for i = 1, MAX_SLOTS do
    local name = names[i]
    if name then
      -- Text and visibility snap; only the focus paint eases. A pill whose
      -- name changed should read as its new workspace at once.
      spaces[i]:set({ drawing = true, icon = { string = name, color = colors.white } })
      paint_space(i)
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
