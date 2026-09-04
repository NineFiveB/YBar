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

-- The focus ring, in two stops.
--
-- There is no glow in this engine to switch on: a border is drawn as a hard
-- band between the shape edge and that edge inset by border_width, with only
-- a one-pixel analytic feather (shaders/ybar.hlsl, quad_fragment), and there
-- is no blur or bloom pass anywhere in the pipeline. So the falloff is built
-- from the two quads a workspace pill already owns — its own 23pt box and the
-- bracket's box one point outside it. Bright stroke on the pill edge, dim
-- stroke one point out; brightness dropping outward is what reads as a halo
-- at this size. Two stops is all the geometry affords, and at 1pt each on a
-- 35pt strip that is enough.
--
-- Both stops fade with the fill, so focus arrives as one gesture rather than
-- a ring appearing over a pill that is still changing colour.
local RING_INNER = colors.with_alpha(colors.white, 0.85)
local RING_OUTER = colors.with_alpha(colors.white, 0.28)
local RING_FRAMES = 8

-- The halo, which is now a real one. The two-stop trick above exists because
-- this engine had no blur anywhere: a border is a hard band with a one-pixel
-- analytic feather, so a falloff had to be faked from the two quads a pill
-- already owned. background.shadow.blur adds the falloff the pipeline was
-- missing -- a shadow quad grown by the blur radius with a squared ramp -- and
-- a LIGHT shadow at zero offset is exactly a glow. Kept alongside the two ring
-- stops rather than replacing them: the stops draw the crisp edge, the glow
-- carries it outward.
local GLOW = colors.with_alpha(colors.white, 0.32)
local GLOW_BLUR = 5

-- Paint one slot's WHOLE surface: fill, bevel, lift, and both ring stops,
-- from both inputs at once. Focus and hover used to own separate writes to
-- the same background, which was already a hazard for the fill alone; with
-- elevation on the same property it becomes a correctness bug, because a
-- workspace change would drop the lift out from under a pointer that has not
-- moved. One writer, every time.
--
-- The bracket lifts WITH the pill. It carries the outer ring stop one point
-- outside the pill's box, so leaving it behind would tear the halo in half
-- the moment the pill rose.
local function paint_space(i, frames)
  local on = (i == focused)
  local raised = hovered[i] or false
  local color = space_color(i)
  sbar.animate("sin", frames or RING_FRAMES, function()
    spaces[i]:set({
      background = {
        color = color,
        gradient_angle = 90,
        gradient_color = raised and colors.shade(color, hover.BEVEL) or color,
        y_offset = raised and hover.LIFT or 0,
        border_width = on and 1 or 0,
        border_color = on and RING_INNER or colors.transparent,
        -- drawing stays ON in both states so only the COLOUR animates: the
        -- shadow's alpha is animatable and its drawing flag is not, so
        -- toggling the flag would pop the halo in and out while the ring it
        -- belongs to eased.
        shadow = {
          drawing = true,
          color = on and GLOW or colors.transparent,
          distance = 0,
          blur = GLOW_BLUR,
        },
      },
    })
    brackets[i]:set({
      background = {
        y_offset = raised and hover.LIFT or 0,
        border_width = on and 1 or 0,
        border_color = on and RING_OUTER or colors.transparent,
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
