local colors = require("colors")
local settings = require("settings")

-- Now-playing pill: appears while any media session reports playback (the
-- engine's media_change event — GSMTC on Windows, a strict superset of the
-- macOS distributed-notification hack: Spotify, browsers, most players).
-- Long titles marquee-scroll inside the fixed label width; left-click opens
-- a now-playing popup (title, transport, volume), right-click keeps the old
-- play/pause toggle.
--
-- WINDOWS: everything is driven by the media_change env
-- (MEDIA_STATE/MEDIA_TITLE/MEDIA_ARTIST/MEDIA_ALBUM/MEDIA_APP) — there is
-- no AppleScript back-channel into a player, so the osascript status poll,
-- the per-app command guards, and the "Music"/"Spotify" whitelist are gone.
-- Transport is media-key synthesis (SendKeys), which steers whatever owns
-- the active media session. Dropped relative to macOS, with a note at each
-- site:
--   * album artwork — the engine's media_change carries no artwork,
--   * the seek slider — no MEDIA_POSITION/MEDIA_DURATION in the env,
--   * shuffle/repeat — no readable state and no media key to toggle them,
--   * per-app volume — the popup slider now drives SYSTEM volume via the
--     native volume_change event plus volume-key synthesis.

local popup_width = 264
local inset = 11
-- YBAR PORT: art_size/art_dir gone — no artwork surface on Windows, so no
-- per-user cache directory either.

local glyph_play = "sf:play.fill"
local glyph_pause = "sf:pause.fill"
-- YBAR PORT: the repeat/repeat.1 glyphs left with the shuffle/repeat
-- buttons (see the transport section).

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
    padding_left = 7,
    padding_right = 2,
  },
  label = {
    width = 132,
    color = colors.white,
    padding_left = 2,
    padding_right = 7,
  },
  padding_left = 2,
  padding_right = 2,
  -- Pins the content while the reveal/collapse animates the box width; see
  -- the note on reveal_media below.
  align = "right",
})

-- wrap_width (flow layout) instead of a fixed row height: the transport
-- controls form a 3-cell grid line (3 × 100 = wrap width), every other row
-- is exactly popup_width wide so it occupies a whole line.
-- auto_close=false: the engine's default closes auto-close popups on any
-- bar mouse-DOWN except on the popup's host — and the host here is this
-- BRACKET while the press lands on the member pill (hit-test prefers
-- members), so with auto-close the popup would vanish on mouse-down and the
-- click handler's toggle would instantly reopen it: the pill could never
-- close it. With it off, the only close paths are this widget's own
-- (toggle, global exit, playback stop).
local media_bracket = sbar.add("bracket", "widgets.media.bracket", { media.name }, {
  background = { color = colors.mica }, -- tint over the Mica material
  popup = { align = "center", wrap_width = popup_width, auto_close = false },
})

require("helpers.hover").pill(media_bracket, media)

local popup_pos = "popup." .. media_bracket.name

local media_padding = sbar.add("item", "widgets.media.padding", {
  position = "right",
  width = settings.group_paddings,
  drawing = false,
})

-- ── Popup rows ─────────────────────────────────────────────────────────────
-- YBAR PORT: row 1 (album artwork + placeholder, and all of the artwork
-- fetch/cache machinery) is dropped — the Windows media provider publishes
-- no artwork, only text metadata. The popup opens straight onto the title.

-- 1. Track title, centered.
local title_row = sbar.add("item", "widgets.media.title", {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  align = "center",
  icon = { drawing = false },
  label = {
    string = "—",
    font = { size = 12.5, style = settings.font.style_map["Bold"] },
    color = colors.white,
  },
})

-- 2. Artist — Album, centered; hidden when both are empty.
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
    font = { size = 10.5 },
    color = colors.grey,
  },
})

-- YBAR PORT: the seek row (elapsed | track | total slider) is dropped — the
-- media_change env has no MEDIA_POSITION/MEDIA_DURATION, and there is no
-- side channel to read or set a player position. GSMTC does expose a
-- timeline; if the engine ever publishes it, the macOS row ports 1:1.

-- 3. Transport: 3 fixed-width cells fill exactly one flow line.
-- YBAR PORT: shuffle and repeat are dropped — their state is unreadable
-- (nothing in the media_change env) and Windows has no shuffle/repeat media
-- key to synthesize, so the buttons could neither reflect nor change
-- anything. prev/play/next remain, each backed by a media key.
local btn_w = popup_width / 3

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

local prev_btn = transport_button("widgets.media.prev", "sf:backward.fill", 14, colors.white)
local play_btn = transport_button("widgets.media.play", glyph_play, 19.5, colors.white)
local next_btn = transport_button("widgets.media.next", "sf:forward.fill", 14, colors.white)

-- 4. Footer: separator, source app, system volume.
sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

-- YBAR PORT: the app-icon image ("app.Music"/"app.Spotify") is dropped —
-- MEDIA_APP is a raw app id, not something the image surface can resolve.
-- The label shows the id text instead; the inset the image used to provide
-- moves onto the label.
local source_row = sbar.add("item", "widgets.media.source", {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  align = "left",
  icon = { drawing = false },
  label = {
    string = "…",
    font = { size = 10.5, style = settings.font.style_map["Semibold"] },
    color = colors.grey,
    padding_left = inset,
  },
})

-- YBAR PORT: this slider drove the PLAYER's `sound volume` over AppleScript;
-- Windows has no per-app volume API worth shelling to, so it now mirrors and
-- sets SYSTEM volume — read via the native volume_change event, written as
-- volume-key ticks (2 % each).
local vol_slider = sbar.add("slider", "widgets.media.volume", 220, {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  align = "left",
  icon = {
    string = "sf:speaker.wave.2.fill",
    color = colors.grey,
    font = { size = 9.5 },
    padding_left = inset,
    padding_right = 7,
  },
  label = { drawing = false },
  slider = {
    percentage = 50,
    highlight_color = colors.white,
    background = {
      height = 5,
      corner_radius = 3,
      color = colors.bg2,
    },
    knob = {
      -- YBAR PORT: the macOS knob was a literal SF-Symbols circle glyph;
      -- Segoe Fluent Icons has no mapped circle, so a plain text bullet
      -- (rendered by the label font) stands in. 18pt for a 16px circle at
      -- 2x (the default 11.5 was flush with the track); its ink sits low
      -- in its em (unlike the SF circle), lift measured by the bluetooth
      -- flyout's held-open pixel sweep at this size.
      string = "●",
      font = { size = 18 },
      y_offset = 2.25,
      drawing = true,
    },
  },
})

-- ── State ──────────────────────────────────────────────────────────────────
-- YBAR PORT: the whitelist, artwork keys/paths, duration, shuffle/repeat and
-- the poll-generation/hold machinery are gone — media_change and
-- volume_change are push events, so nothing here polls.
local current_app = nil       -- MEDIA_APP app id while something plays/pauses
local current_key = nil       -- app|artist|album|title of the current track
local current_volume = 50     -- last volume_change INFO (kept for reference)

-- ── Small helpers ──────────────────────────────────────────────────────────
local function trunc(s, max_chars)
  if s == "" then return s end
  local ok, len = pcall(utf8.len, s)
  if not ok or not len then return s:sub(1, max_chars) end
  if len <= max_chars then return s end
  return s:sub(1, utf8.offset(s, max_chars) - 1) .. "…"
end

-- YBAR PORT: app_cmd/status_cmd/apply_status/fmt_time are gone with the
-- osascript back-channel. Their replacement is one-way: synthesized media
-- keys, with state flowing back through media_change.
--   [char]179 play/pause · [char]176 next · [char]177 prev
local function media_key(code)
  sbar.exec("powershell.exe -NoProfile -Command '"
    .. "$w=New-Object -ComObject WScript.Shell; $w.SendKeys([char]" .. code .. ")'")
end

-- YBAR PORT, second pass: absolute sets ride the in-process ybar.volume()
-- verb (the daemon already holds the audio endpoint), replacing the
-- volume-key SendKeys ladder — no shell spawn per drag, no 2 % quantization.
-- The volume_change push from the set still settles the slider on the real
-- value. (Scroll-to-adjust in helpers/win.lua keeps the key ticks: relative
-- nudges want the OS volume OSD that media keys bring.)
local function set_system_volume(target)
  ybar.volume(target)
end

-- ── Open / close ───────────────────────────────────────────────────────────
-- YBAR PORT: no start/stop_polling — the popup is repainted by media_change
-- and volume_change pushes, so opening it schedules nothing.
-- ── Reveal / collapse ──────────────────────────────────────────────────────
-- A ~155pt pill materialising beside the clock is the most abrupt thing the
-- strip does, and width animates for free: `width = "dynamic"` under animate
-- resolves the sentinel to the measured natural width at BOTH endpoints and
-- hands the sentinel back on natural completion, so the pill wipes open and
-- then goes back to tracking its own text.
--
-- `align = "right"` on the item is load-bearing, not cosmetic. A fixed-width
-- item clips its content to its box, and the box grows from the LEFT here
-- (right-positioned items lay out from the right cursor), so with the default
-- centre alignment the text would slide sideways as the box opens. Pinned
-- right, the box's left edge does the wiping and the text stays put.
local REVEAL_FRAMES = 10
local COLLAPSE_FRAMES = 8
local media_shown = false
local media_gen = 0   -- guards a collapse that a reveal has since overtaken

local function reveal_media()
  media_gen = media_gen + 1
  if media_shown then return end
  media_shown = true
  media:set({ drawing = true, width = 0 })
  media_padding:set({ drawing = true })
  sbar.animate("sin", REVEAL_FRAMES, function()
    media:set({ width = "dynamic" })
  end)
end

local function collapse_media()
  if not media_shown then return end
  media_shown = false
  media_gen = media_gen + 1
  local gen = media_gen
  sbar.animate("sin", COLLAPSE_FRAMES, function()
    media:set({ width = 0 })
  end)
  -- `drawing` is a bool and cannot animate, so the item is hidden once the
  -- collapse has run. The generation check drops this if playback resumed in
  -- the meantime and the pill is already opening again.
  sbar.delay(COLLAPSE_FRAMES / 60 + 0.05, function()
    if gen ~= media_gen then return end
    media:set({ drawing = false })
    media_padding:set({ drawing = false })
  end)
end

local function hide_popup()
  media_bracket:set({ popup = { drawing = false } })
end

local function toggle_popup(env)
  -- No player context (a media_change can hide the pill between the press
  -- and this handler): nothing to show or control.
  if not current_app then return end
  -- Right-click keeps the pill's old affordance: toggle play/pause.
  if env and env.BUTTON == "right" then
    media_key(179)
    return
  end
  local should_draw = media_bracket:query().popup.drawing == "off"
  if should_draw then
    media_bracket:set({ popup = { drawing = true } })
  else
    hide_popup()
  end
end

-- ── Media events ───────────────────────────────────────────────────────────
media:subscribe("media_change", function(env)
  local state = env.MEDIA_STATE or ""
  local playing = state == "playing"
  local app = env.MEDIA_APP or ""
  local artist = env.MEDIA_ARTIST or ""
  local album = env.MEDIA_ALBUM or ""
  local title = env.MEDIA_TITLE or ""
  -- GHOST SESSIONS (measured 2026-08-31, Chrome 1xx): closing a tab that was
  -- playing leaves Chrome's SMTC session REGISTERED and still reporting
  -- "playing" — GetCurrentSession() keeps returning it, no GSMTC event ever
  -- fires again, and the pill stayed up forever. The one thing the ghost does
  -- drop is its metadata, and metadata is the pill's entire content: an empty
  -- title/artist/album renders a blank pill regardless. So require some
  -- metadata to draw. (Timeline staleness is NOT usable here — measured: a
  -- genuinely playing Chrome session also stops updating LastUpdatedTime.)
  local has_meta = title ~= "" or artist ~= "" or album ~= ""
  local show = (playing or state == "paused") and has_meta

  -- Pill: unchanged from the pre-popup widget.
  local text = (artist ~= "" and (artist .. " — ") or "") .. title
  local color = playing and colors.white or colors.grey
  -- Marquee pace: the engine scrolls ONE cycle (ink + 24pt) per
  -- scroll_duration/60 s, so a fixed duration makes long titles whip past
  -- faster than short ones. Scale the duration with the text length instead,
  -- for a constant ~45pt/s reading pace at any title length (utf8.len so
  -- multi-byte chars like the em dash don't inflate the estimate).
  local chars = utf8.len(text) or #text
  local scroll_frames = math.max(240, math.floor(chars * 7.7 + 32))
  media:set({
    icon = { color = color },
    label = { string = text, color = color, scroll_duration = scroll_frames },
  })
  if show then reveal_media() else collapse_media() end

  if not show then
    current_app, current_key = nil, nil
    hide_popup()
    return
  end

  -- YBAR PORT: no "Music"/"Spotify" whitelist — GSMTC vets the session, so
  -- any MEDIA_APP id is a controllable player.
  current_app = app ~= "" and app or nil

  local key = app .. "|" .. artist .. "|" .. album .. "|" .. title
  if key ~= current_key then
    current_key = key
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
      -- MEDIA_APP is an app id, not a friendly name — shown as-is.
      source_row:set({ label = { string = current_app } })
    end
  end

  play_btn:set({ icon = { string = playing and glyph_pause or glyph_play } })
end)

-- YBAR PORT: the app_terminated linger-guard is dropped. GSMTC fires
-- CurrentSessionChanged when the player exits, which arrives as a
-- media_change with a non-playing state and takes the hide path above —
-- so the pill cannot linger. (Windows app_terminated INFO is an exe
-- FileDescription and would never match MEDIA_APP's app id anyway.)

media:subscribe("mouse.clicked", toggle_popup)
media:subscribe("mouse.exited.global", hide_popup)

-- ── Popup interactions ─────────────────────────────────────────────────────
-- Slider release delivers a plain mouse.clicked with PERCENTAGE (0–100).
vol_slider:subscribe("mouse.clicked", function(env)
  local pct = tonumber(env.PERCENTAGE or "")
  if not pct then return end
  -- Optimistic paint; the volume_change push from the set settles it.
  vol_slider:set({ slider = { percentage = pct } })
  set_system_volume(pct)
end)

vol_slider:subscribe("volume_change", function(env)
  local vol = tonumber(env.INFO)
  if not vol then return end
  current_volume = vol
  vol_slider:set({ slider = { percentage = vol } })
end)

-- YBAR PORT: no `sbar.delay(0.3, status_once)` after transport clicks — the
-- provider pushes the resulting state change as a fresh media_change.
play_btn:subscribe("mouse.clicked", function()
  if not current_app then return end
  media_key(179)
end)

prev_btn:subscribe("mouse.clicked", function()
  if not current_app then return end
  media_key(177)
end)

next_btn:subscribe("mouse.clicked", function()
  if not current_app then return end
  media_key(176)
end)

-- YBAR PORT: the source row's `open -a <app>` click is dropped — MEDIA_APP
-- is a GSMTC app id with no portable "launch this id" verb (packaged apps
-- would need shell:AppsFolder AUMID resolution). The row is display-only.

-- Boot/reload replay: the provider is notification-driven, so a config
-- (re)load mid-song would otherwise show no pill until the next playback
-- change. The daemon intercepts `--trigger media_change` and re-dispatches
-- the last seen MEDIA_* env (a no-op when nothing was ever playing).
sbar.exec("ybar --trigger media_change")
