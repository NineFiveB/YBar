local colors = require("colors")
local settings = require("settings")

-- Now-playing pill: appears while Music or Spotify reports playback (the
-- engine's media_change event — distributed notifications, no MediaRemote).
-- Long titles marquee-scroll inside the fixed label width; left-click opens
-- a full now-playing popup (artwork, seek, transport, volume), right-click
-- keeps the old play/pause toggle.
--
-- Every osascript is wrapped in `if application "X" is running then ... end
-- if` so a command can never LAUNCH Music/Spotify; app names come from the
-- engine's MEDIA_APP whitelist ("Music"/"Spotify"), and track metadata never
-- reaches a shell or AppleScript string — artwork cache paths are built from
-- a hash, not the raw title/artist.

local popup_width = 300
local inset = 12
local art_size = 150
-- Per-user cache: TMPDIR is per-user mode-700 on macOS. A fixed /tmp path
-- would be owned by whichever user ran ybar first (silent placeholder-only
-- operation for everyone else) and is world-predictable.
local art_dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/ybar_media_art"

local glyph_play = "sf:play.fill"
local glyph_pause = "sf:pause.fill"
local glyph_repeat = "sf:repeat"
local glyph_repeat_one = "sf:repeat.1"

-- ── Bar pill (unchanged visuals) ───────────────────────────────────────────
local media = sbar.add("item", "widgets.media", {
  position = "right",
  drawing = false,
  -- updates=true: the default when_shown never delivers media_change to the
  -- initially-hidden pill, so nothing could ever reveal it.
  updates = true,
  scroll_texts = true,
  icon = {
    string = "sf:music.note",
    color = colors.grey,
    padding_left = 8,
    padding_right = 2,
  },
  label = {
    width = 150,
    color = colors.white,
    padding_left = 2,
    padding_right = 8,
  },
  padding_left = 2,
  padding_right = 2,
})

-- wrap_width (flow layout) instead of a fixed row height: the transport
-- controls form a 5-cell grid line (5 × 60 = wrap width), every other row is
-- exactly popup_width wide so it occupies a whole line, and tall rows
-- (artwork) size to their content.
-- auto_close=false: the engine's default closes auto-close popups on any
-- bar mouse-DOWN except on the popup's host — and the host here is this
-- BRACKET while the press lands on the member pill (hit-test prefers
-- members), so with auto-close the popup would vanish on mouse-down and the
-- click handler's toggle would instantly reopen it: the pill could never
-- close it, and engine-side closes would orphan the 1 Hz poll chain. With
-- it off, the only close paths are this widget's own (toggle, global exit,
-- playback stop), each of which also stops the polling.
local media_bracket = sbar.add("bracket", "widgets.media.bracket", { media.name }, {
  background = { color = colors.bg1 },
  popup = { align = "center", wrap_width = popup_width, auto_close = false },
})

local popup_pos = "popup." .. media_bracket.name

local media_padding = sbar.add("item", "widgets.media.padding", {
  position = "right",
  width = settings.group_paddings,
  drawing = false,
})

-- ── Popup rows ─────────────────────────────────────────────────────────────
-- 1. Album artwork, centered. The transparent background pins the row height
--    (battery's graph-row idiom) so swapping placeholder <-> artwork does not
--    make the panel jump. art_size stays small on purpose: the engine's glyph
--    atlas keys image entries by path and never evicts, so big per-track
--    bitmaps would fill the color page.
local art = sbar.add("item", "widgets.media.art", {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  align = "center",
  icon = {
    string = "sf:music.note",
    color = colors.with_alpha(colors.grey, 0.6),
    font = { size = 44 },
    padding_left = 0,
    padding_right = 0,
  },
  label = { drawing = false },
  background = {
    drawing = true,
    color = colors.transparent,
    height = art_size,
  },
  image = { drawing = false, size = art_size },
})

-- 2. Track title, centered.
local title_row = sbar.add("item", "widgets.media.title", {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  align = "center",
  icon = { drawing = false },
  label = {
    string = "—",
    font = { size = 14, style = settings.font.style_map["Bold"] },
    color = colors.white,
  },
})

-- 3. Artist — Album, centered; hidden when both are empty.
local subtitle_row = sbar.add("item", "widgets.media.subtitle", {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  align = "center",
  drawing = false,
  icon = { drawing = false },
  label = {
    string = "",
    font = { size = 12 },
    color = colors.grey,
  },
})

-- 4. Progress: elapsed | track | total. The time labels ride the slider item
--    itself (icon leads the track, label trails it). The icon keeps its
--    natural width — the engine's slider hit-test assumes padding + measured
--    ink for a leading icon, so a fixed icon width would skew seek clicks.
local seek_track_w = 200
local seek = sbar.add("slider", "widgets.media.seek", seek_track_w, {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  align = "left",
  icon = {
    string = "0:00",
    color = colors.grey,
    font = { family = settings.font.numbers, size = 10 },
    padding_left = inset,
    padding_right = 8,
  },
  label = {
    string = "0:00",
    color = colors.grey,
    font = { family = settings.font.numbers, size = 10 },
    padding_left = 8,
    padding_right = inset,
  },
  slider = {
    percentage = 0,
    highlight_color = colors.white,
    background = {
      height = 6,
      corner_radius = 3,
      color = colors.bg2,
    },
    knob = {
      string = "􀀁",
      drawing = true,
    },
  },
})

-- 5. Transport: 5 fixed-width cells fill exactly one flow line.
local btn_w = popup_width / 5

local function transport_button(name, glyph, size, color)
  return sbar.add("item", name, {
    position = popup_pos,
    width = btn_w,
    padding_left = 0,
    padding_right = 0,
    align = "center",
    icon = {
      string = glyph,
      font = { size = size },
      color = color,
      padding_left = 0,
      padding_right = 0,
    },
    label = { drawing = false },
  })
end

local shuffle_btn = transport_button("widgets.media.shuffle", "sf:shuffle", 13, colors.grey)
local prev_btn = transport_button("widgets.media.prev", "sf:backward.fill", 16, colors.white)
local play_btn = transport_button("widgets.media.play", glyph_play, 22, colors.white)
local next_btn = transport_button("widgets.media.next", "sf:forward.fill", 16, colors.white)
local repeat_btn = transport_button("widgets.media.repeat", glyph_repeat, 13, colors.grey)

-- 6. Footer: separator, source app, app volume.
sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

local source_row = sbar.add("item", "widgets.media.source", {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  align = "left",
  image = { drawing = false, size = 16, padding_left = inset, padding_right = 6 },
  icon = { drawing = false },
  label = {
    string = "…",
    font = { size = 12, style = settings.font.style_map["Semibold"] },
    color = colors.grey,
  },
})

local vol_slider = sbar.add("slider", "widgets.media.volume", 250, {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  align = "left",
  icon = {
    string = "sf:speaker.wave.2.fill",
    color = colors.grey,
    font = { size = 11 },
    padding_left = inset,
    padding_right = 8,
  },
  label = { drawing = false },
  slider = {
    percentage = 50,
    highlight_color = colors.white,
    background = {
      height = 6,
      corner_radius = 3,
      color = colors.bg2,
    },
    knob = {
      string = "􀀁",
      drawing = true,
    },
  },
})

-- ── State ──────────────────────────────────────────────────────────────────
local current_app = nil       -- "Music" | "Spotify" | nil (engine whitelist)
local current_key = nil       -- app|artist|album|title of the current track
local current_art_path = nil
local art_shown_for = nil     -- key whose artwork the popup displays
local art_fetching = nil      -- key with a fetch in flight
local duration_s = 0
local shuffle_on = false
local repeat_mode = "off"     -- "off" | "all" | "one"
local seek_track_now = seek_track_w
-- Poll generation: bumping it kills any pending delay-chain from a previous
-- popup open; holds skip N poll applications after a user seek/volume drag so
-- a stale read can't snap the slider back.
local poll_gen = 0
local seek_hold = 0
local vol_hold = 0

-- ── Small helpers ──────────────────────────────────────────────────────────
local function trunc(s, max_chars)
  if s == "" then return s end
  local ok, len = pcall(utf8.len, s)
  if not ok or not len then return s:sub(1, max_chars) end
  if len <= max_chars then return s end
  return s:sub(1, utf8.offset(s, max_chars) - 1) .. "…"
end

local function fmt_time(s)
  s = math.floor(math.max(0, s or 0))
  local h = s // 3600
  local m = (s % 3600) // 60
  local sec = s % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
  return string.format("%d:%02d", m, sec)
end

-- Unique path per track: the engine caches images by path string and never
-- re-reads a path it has seen, so reusing one file would show stale art.
local function art_path_for(app, key)
  local h = 5381
  for i = 1, #key do
    h = ((h * 33) + key:byte(i)) & 0xFFFFFFFF
  end
  local tag = (app or "media"):lower():gsub("%W", "")
  -- NSImage sniffs the content, so one extension covers JPEG and PNG alike.
  return art_dir .. "/" .. tag .. "-" .. string.format("%08x", h) .. ".img"
end

-- Guarded one-shot command against the current player. `is running` queries
-- the process table — it never launches the app.
local function app_cmd(app, body)
  return "osascript -e 'if application \"" .. app .. "\" is running then\n"
    .. "tell application \"" .. app .. "\"\n"
    .. body
    .. "\nend tell\nend if' 2>/dev/null"
end

-- ── Combined status poll (ONE osascript per tick) ──────────────────────────
-- state|position|duration|volume|shuffle|repeat, integers, every value that
-- can be missing wrapped in try so a stopped player still reports.
local status_script = {
  Music = table.concat({
    'if application "Music" is running then',
    'tell application "Music"',
    'set ps to (player state as text)',
    'set pos to 0',
    'set dur to 0',
    'set vol to 0',
    'set shuf to false',
    'set rep to "off"',
    'try',
    'set p to player position',
    'if p is not missing value then set pos to (p div 1)',
    'end try',
    'try',
    'set dur to ((duration of current track) div 1)',
    'end try',
    'try',
    'set vol to sound volume',
    'end try',
    'try',
    'set shuf to shuffle enabled',
    'end try',
    'try',
    'set rep to (song repeat as text)',
    'end try',
    'return (ps & "|" & pos & "|" & dur & "|" & vol & "|" & shuf & "|" & rep) as text',
    'end tell',
    'end if',
  }, "\n"),
  Spotify = table.concat({
    'if application "Spotify" is running then',
    'tell application "Spotify"',
    'set ps to (player state as text)',
    'set pos to 0',
    'set dur to 0',
    'set vol to 0',
    'set shuf to false',
    'set rep to "off"',
    'try',
    'set p to player position',
    'if p is not missing value then set pos to (p div 1)',
    'end try',
    'try',
    'set dur to (((duration of current track) / 1000) div 1)',
    'end try',
    'try',
    'set vol to sound volume',
    'end try',
    'try',
    'set shuf to shuffling',
    'end try',
    'try',
    'if repeating then set rep to "all"',
    'end try',
    'return (ps & "|" & pos & "|" & dur & "|" & vol & "|" & shuf & "|" & rep) as text',
    'end tell',
    'end if',
  }, "\n"),
}

local function status_cmd(app)
  return "osascript -e '" .. status_script[app] .. "' 2>/dev/null"
end

local function apply_status(out)
  local ps, pos, dur, vol, shuf, rep =
    (out or ""):match("^([^|]+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%a+)|(%a+)$")
  if not ps then return end

  duration_s = tonumber(dur) or 0
  local position = tonumber(pos) or 0
  local volume = math.max(0, math.min(100, tonumber(vol) or 0))
  shuffle_on = shuf == "true"
  repeat_mode = rep

  play_btn:set({
    icon = { string = ps == "playing" and glyph_pause or glyph_play },
  })

  -- Shrink the track once times grow to h:mm:ss so the total label still fits.
  local want_track = duration_s >= 3600 and 170 or seek_track_w
  if want_track ~= seek_track_now then
    seek_track_now = want_track
    seek:set({ slider = { width = want_track } })
  end

  if seek_hold > 0 then
    seek_hold = seek_hold - 1
  else
    local pct = duration_s > 0
      and math.min(100, position / duration_s * 100) or 0
    -- Safe to push during a scrub: the engine ignores percentage sets while
    -- the slider is dragged.
    seek:set({
      icon = { string = fmt_time(position) },
      label = { string = fmt_time(duration_s) },
      slider = { percentage = pct },
    })
  end

  if vol_hold > 0 then
    vol_hold = vol_hold - 1
  else
    vol_slider:set({ slider = { percentage = volume } })
  end

  shuffle_btn:set({
    icon = { color = shuffle_on and colors.white or colors.grey },
  })
  repeat_btn:set({
    icon = {
      string = repeat_mode == "one" and glyph_repeat_one or glyph_repeat,
      color = repeat_mode ~= "off" and colors.white or colors.grey,
    },
  })
end

local function status_once()
  local app = current_app
  if not app then return end
  sbar.exec(status_cmd(app), function(out) apply_status(out) end)
end

-- 1s cadence, only while the popup is open: start_polling on open bumps the
-- generation and starts a delay chain; stop_polling bumps it again so any
-- pending tick from the previous open dies on the gen check.
local function poll_tick(gen)
  if gen ~= poll_gen then return end
  -- Belt and braces beside the generation check: if anything else ever
  -- closes the popup (a future engine path, a config poking popup.drawing
  -- directly), the chain notices within a tick and dies.
  if media_bracket:query().popup.drawing ~= "on" then return end
  local app = current_app
  if not app then
    sbar.delay(1, function() poll_tick(gen) end)
    return
  end
  sbar.exec(status_cmd(app), function(out)
    if gen ~= poll_gen then return end
    apply_status(out)
    sbar.delay(1, function() poll_tick(gen) end)
  end)
end

local function start_polling()
  poll_gen = poll_gen + 1
  seek_hold = 0
  vol_hold = 0
  poll_tick(poll_gen)
end

local function stop_polling()
  poll_gen = poll_gen + 1
end

-- ── Artwork ────────────────────────────────────────────────────────────────
local function show_placeholder()
  art_shown_for = nil
  art:set({
    icon = { drawing = true },
    image = { drawing = false },
  })
end

local function show_artwork(path, key)
  art_shown_for = key
  -- image.string alone does not schedule a repaint; the size set (a float
  -- property) always invalidates, so pairing them makes the swap visible.
  art:set({
    icon = { drawing = false },
    image = { string = path, drawing = true, size = art_size },
  })
end

-- Async, never blocks: Music exports `raw data of artwork 1` straight to the
-- cache file from AppleScript; Spotify prints `artwork url` and curl fetches
-- it. Both shell commands short-circuit on an already-cached file, and both
-- osascripts carry the running guard.
local function fetch_artwork()
  local app, key, path = current_app, current_key, current_art_path
  if not app or not key or not path then return end
  if art_shown_for == key or art_fetching == key then return end
  art_fetching = key

  -- Atomic cache writes: export/download lands in a .part sibling and only a
  -- same-filesystem mv publishes it, so `[ -s path ]` can never see a
  -- truncated file — a partial write (curl --max-time abort, watchdog-killed
  -- osascript) would otherwise latch a corrupt file for the whole session.
  local part = path .. ".part"
  local cmd
  if app == "Music" then
    local script = table.concat({
      'if application "Music" is running then',
      'tell application "Music"',
      'try',
      'set d to raw data of artwork 1 of current track',
      'on error',
      'return ""',
      'end try',
      'end tell',
      'try',
      'set f to open for access (POSIX file "' .. part .. '") with write permission',
      'set eof f to 0',
      'write d to f',
      'close access f',
      'return "ok"',
      'on error',
      'try',
      'close access (POSIX file "' .. part .. '")',
      'end try',
      'return ""',
      'end try',
      'end if',
    }, "\n")
    cmd = "mkdir -p '" .. art_dir .. "'; if [ -s '" .. path .. "' ]; then echo ok; "
      .. "else o=$(osascript -e '" .. script .. "' 2>/dev/null); "
      .. "if [ \"$o\" = ok ] && [ -s '" .. part .. "' ]; then mv '" .. part .. "' '"
      .. path .. "' && echo ok; else rm -f '" .. part .. "'; fi; fi"
  else
    local script = table.concat({
      'if application "Spotify" is running then',
      'tell application "Spotify"',
      'try',
      'return artwork url of current track',
      'on error',
      'return ""',
      'end try',
      'end tell',
      'end if',
    }, "\n")
    cmd = "mkdir -p '" .. art_dir .. "'; if [ -s '" .. path .. "' ]; then echo ok; "
      .. 'else url=$(osascript -e \'' .. script .. '\' 2>/dev/null); '
      .. 'if [ -n "$url" ] && curl -fsSL --max-time 10 "$url" -o \'' .. part .. "'; "
      .. "then mv '" .. part .. "' '" .. path .. "' && echo ok; "
      .. "else rm -f '" .. part .. "'; fi; fi"
  end

  sbar.exec(cmd, function(out)
    if art_fetching == key then art_fetching = nil end
    -- The export reads `current track` at EXEC time while the cache path was
    -- keyed at EVENT time — if the track changed in that window the file
    -- holds the WRONG track's art under this key. Stale result: delete it so
    -- the next visit refetches instead of latching the mismatch.
    if key ~= current_key then
      os.remove(path)
      return
    end
    if (out or ""):match("ok") then
      show_artwork(path, key)
    end
  end)
end

-- ── Open / close ───────────────────────────────────────────────────────────
local function hide_popup()
  stop_polling()
  media_bracket:set({ popup = { drawing = false } })
end

local function toggle_popup(env)
  -- No player context (a media_change can hide the pill between the press
  -- and this handler): nothing to show or control.
  if not current_app then return end
  -- Right-click keeps the pill's old affordance: toggle play/pause.
  if env and env.BUTTON == "right" then
    if current_app then sbar.exec(app_cmd(current_app, "playpause")) end
    return
  end
  local should_draw = media_bracket:query().popup.drawing == "off"
  if should_draw then
    media_bracket:set({ popup = { drawing = true } })
    fetch_artwork()   -- no-op when already shown or in flight
    start_polling()
  else
    hide_popup()
  end
end

-- ── Media events ───────────────────────────────────────────────────────────
media:subscribe("media_change", function(env)
  local state = env.MEDIA_STATE or ""
  local playing = state == "playing"
  local show = playing or state == "paused"
  local app = env.MEDIA_APP
  local artist = env.MEDIA_ARTIST or ""
  local album = env.MEDIA_ALBUM or ""
  local title = env.MEDIA_TITLE or ""

  -- Pill: unchanged from the pre-popup widget.
  local text = (artist ~= "" and (artist .. " — ") or "") .. title
  local color = playing and colors.white or colors.grey
  media:set({
    drawing = show,
    icon = { color = color },
    label = { string = text, color = color },
  })
  media_padding:set({ drawing = show })

  if not show then
    current_app, current_key, current_art_path = nil, nil, nil
    hide_popup()
    return
  end

  current_app = (app == "Music" or app == "Spotify") and app or nil

  local key = (app or "") .. "|" .. artist .. "|" .. album .. "|" .. title
  if key ~= current_key then
    current_key = key
    current_art_path = art_path_for(app, key)
    show_placeholder()
    -- New track: the last-polled duration belongs to the PREVIOUS track and
    -- stays wrong for up to a tick. duration_s == 0 makes the seek handler
    -- bail until fresh status lands; zero the row so it doesn't show stale
    -- times meanwhile.
    duration_s = 0
    seek:set({
      icon = { string = "0:00" },
      label = { string = "0:00" },
      slider = { percentage = 0 },
    })
    title_row:set({ label = { string = trunc(title ~= "" and title or "—", 34) } })
    local sub
    if artist ~= "" and album ~= "" then
      sub = artist .. " — " .. album
    elseif artist ~= "" then
      sub = artist
    else
      sub = album
    end
    subtitle_row:set({ drawing = sub ~= "", label = { string = trunc(sub, 44) } })
    if current_app then
      source_row:set({
        image = { string = "app." .. current_app, drawing = true },
        label = { string = current_app },
      })
      fetch_artwork()
    end
  end

  play_btn:set({ icon = { string = playing and glyph_pause or glyph_play } })
end)

-- Music/Spotify post no final playback notification when they QUIT — only
-- on playback changes — so without this the pill and popup would linger
-- showing the dead app's last track until the next media_change. INFO is
-- the terminated app's localizedName; on a non-English macOS Music's
-- display name is localized and won't match, which degrades to exactly the
-- old lingering behavior, never a false positive... unless the localized
-- name happens to equal the other player's, which cannot happen for the
-- two whitelisted apps.
media:subscribe("app_terminated", function(env)
  if current_app and env.INFO == current_app then
    current_app, current_key, current_art_path = nil, nil, nil
    media:set({ drawing = false })
    media_padding:set({ drawing = false })
    hide_popup()
  end
end)

media:subscribe("mouse.clicked", toggle_popup)
media:subscribe("mouse.exited.global", hide_popup)

-- ── Popup interactions ─────────────────────────────────────────────────────
-- Slider release delivers a plain mouse.clicked with PERCENTAGE (0–100).
seek:subscribe("mouse.clicked", function(env)
  local pct = tonumber(env.PERCENTAGE or "")
  local app = current_app
  if not pct or not app or duration_s <= 0 then return end
  local target = math.floor(duration_s * pct / 100 + 0.5)
  if target >= duration_s then target = math.max(0, duration_s - 1) end
  -- Optimistic elapsed label; skip the next two poll applications so a read
  -- taken before the seek landed can't snap the knob back.
  seek_hold = 2
  seek:set({ icon = { string = fmt_time(target) } })
  sbar.exec(app_cmd(app, "set player position to " .. target))
end)

vol_slider:subscribe("mouse.clicked", function(env)
  local pct = tonumber(env.PERCENTAGE or "")
  local app = current_app
  if not pct or not app then return end
  vol_hold = 2
  sbar.exec(app_cmd(app, "set sound volume to " .. math.floor(pct)))
end)

play_btn:subscribe("mouse.clicked", function()
  local app = current_app
  if not app then return end
  sbar.exec(app_cmd(app, "playpause"))
  sbar.delay(0.3, status_once)
end)

prev_btn:subscribe("mouse.clicked", function()
  local app = current_app
  if not app then return end
  sbar.exec(app_cmd(app, "previous track"))
  sbar.delay(0.3, status_once)
end)

next_btn:subscribe("mouse.clicked", function()
  local app = current_app
  if not app then return end
  sbar.exec(app_cmd(app, "next track"))
  sbar.delay(0.3, status_once)
end)

shuffle_btn:subscribe("mouse.clicked", function()
  local app = current_app
  if not app then return end
  local target = not shuffle_on
  local body = app == "Music"
    and ("set shuffle enabled to " .. tostring(target))
    or ("set shuffling to " .. tostring(target))
  shuffle_on = target
  shuffle_btn:set({ icon = { color = target and colors.white or colors.grey } })
  sbar.exec(app_cmd(app, body))
  sbar.delay(0.3, status_once)
end)

repeat_btn:subscribe("mouse.clicked", function()
  local app = current_app
  if not app then return end
  local target, body
  if app == "Music" then
    -- Cycle like the Music app: off → all → one → off.
    if repeat_mode == "off" then
      target = "all"
    elseif repeat_mode == "all" then
      target = "one"
    else
      target = "off"
    end
    body = "set song repeat to " .. target
  else
    target = repeat_mode == "off" and "all" or "off"
    body = "set repeating to " .. tostring(target ~= "off")
  end
  repeat_mode = target
  repeat_btn:set({
    icon = {
      string = target == "one" and glyph_repeat_one or glyph_repeat,
      color = target ~= "off" and colors.white or colors.grey,
    },
  })
  sbar.exec(app_cmd(app, body))
  sbar.delay(0.3, status_once)
end)

source_row:subscribe("mouse.clicked", function()
  local app = current_app
  if not app then return end
  sbar.exec("open -a '" .. app .. "'")
  hide_popup()
end)

-- Boot/reload replay: the provider is notification-driven, so a config
-- (re)load mid-song would otherwise show no pill until the next playback
-- change. The daemon's media_change trigger handler re-dispatches the last
-- seen MEDIA_* env (and is a no-op when nothing was ever playing).
sbar.trigger("media_change")
