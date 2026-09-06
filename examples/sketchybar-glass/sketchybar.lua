-- SbarLua compatibility shim for YbarLua.
--
-- Implements the `sbar` API (FelixKratz/SbarLua) on top of the embedded `ybar`
-- runtime, so existing SbarLua configs run with minimal edits:
--
--   sbar = require("sketchybar")
--
-- Differences from real SbarLua:
--   * runs IN-PROCESS: callbacks are direct function calls, no mach IPC
--   * begin_config/end_config/event_loop are no-ops (there is no batching
--     to speak of and the daemon owns the event loop)
--   * unsupported sketchybar properties (background.image, scroll_texts
--     ...) are accepted and ignored by the engine. NOTE blur_radius is NOT
--     one of them on Windows: it is the material gate at every level (bar
--     Acrylic, item and popup-panel Mica -- spec 7.6)

local compat = {}
local anonymous_counter = 0

local function next_name()
  anonymous_counter = anonymous_counter + 1
  return "compat.item." .. anonymous_counter
end

-- ── Item handles ──────────────────────────────────────────────────────────

local item_methods = {}
item_methods.__index = item_methods

function item_methods:set(props)
  ybar.set(self.name, props)
end

function item_methods:subscribe(event, fn)
  ybar.subscribe(self.name, event, fn)
end

function item_methods:query()
  return ybar.query_table(self.name) or {}
end

function item_methods:push(values)
  ybar.push(self.name, values)
end

local function handle(name)
  return setmetatable({ name = name }, item_methods)
end

-- ── sbar.add: every SbarLua arg form ──────────────────────────────────────
--   add("item", props)                       anonymous
--   add("item", "name", props)
--   add("event", "name" [, notification])
--   add("bracket", members, props)           anonymous
--   add("bracket", "name", members, props)
--   add("slider", width, props)              anonymous
--   add("slider", "name", width, props)
--   add("graph", "name", width, props)
--   add("graph", width, props)               anonymous

local function split_position(props)
  local position = "left"
  if type(props) == "table" and props.position ~= nil then
    position = props.position
    props.position = nil
  end
  return position
end

function compat.add(kind, a, b, c)
  if kind == "event" then
    ybar.add_event(a, b)
    return
  end

  if kind == "bracket" then
    local name, members, props
    if type(a) == "string" then
      name, members, props = a, b, c
    else
      name, members, props = next_name(), a, b
    end
    local item = ybar.add("bracket", name, members) or handle(name)
    if props then item:set(props) end
    return item
  end

  if kind == "slider" or kind == "graph" then
    local name, width, props
    if type(a) == "string" then
      name, width, props = a, b, c
    else
      name, width, props = next_name(), a, b
    end
    props = props or {}
    local position = split_position(props)
    local item = ybar.add(kind, name, position, width) or handle(name)
    item:set(props)
    return item
  end

  -- plain items
  local name, props
  if type(a) == "string" then
    name, props = a, b
  else
    name, props = next_name(), a
  end
  props = props or {}
  local position = split_position(props)
  local item = ybar.add("item", name, position) or handle(name)
  item:set(props)
  return item
end

-- ── The rest of the sbar surface ──────────────────────────────────────────

function compat.bar(props) ybar.bar(props) end
function compat.default(props) ybar.default(props) end
function compat.set(name, props) ybar.set(name, props) end
function compat.exec(cmd, fn) ybar.exec(cmd, fn) end
function compat.trigger(event, env) ybar.trigger(event, env) end
function compat.animate(curve, frames, fn) ybar.animate(curve, frames, fn) end
function compat.delay(seconds, fn) ybar.delay(seconds, fn) end
function compat.query(name) return ybar.query_table(name) or {} end
-- WINDOWS ONLY: tray actions in-process, instead of shelling out to the CLI.
function compat.tray(name, action) return ybar.tray(name, action) end
function compat.remove(name) ybar.remove(name) end

-- No-ops: the daemon owns the lifecycle. end_config keeps SbarLua's
-- boot-population behavior: every subscribed handler runs once with
-- SENDER=forced so widgets appear immediately.
function compat.begin_config() end
function compat.end_config() ybar.update() end
function compat.event_loop() end
function compat.set_bar_name(_) end
function compat.hotload(_) end

return compat
