-- pulse v0.0.1 by loopmasta

engine.name = 'Pulse'

local cs = require 'controlspec'

local WAVES = {"sine", "triangle", "square", "saw", "white"}
local SWEEPS = {"off", "up", "down", "up-down"}
local TONE2 = {"off", "on"}
local VISIBLE = 3 -- the parameters in view at the bottom
-- frequencies worth a jump: voice band, 1200 / 2200 AFSK (APRS), the 1750 Hz
-- repeater burst
local PRESETS = {100, 300, 400, 1000, 1200, 1750, 2200, 3000, 5000}
local REPLY_PORT = 9000  -- where /pulse/get answers go (on the sender's address)

-- the parameters, in scroll order: id, label, kind (option, hz, db, ms, sec). A parameter
-- is a label with its value under it; VISIBLE of them are on the screen at a time
local KNOBS = {
  {id = "wave", label = "WAVE", kind = "option"},
  {id = "hz", label = "FREQ", kind = "hz"},
  {id = "level", label = "LEVEL", kind = "db"},
  {id = "tone2", label = "2TONE", kind = "option"},
  {id = "hz2", label = "FREQ2", kind = "hz"},
  {id = "burst_ms", label = "BURST", kind = "ms"},
  {id = "sweep", label = "SWEEP", kind = "option"},
  {id = "sweep_lo", label = "FROM", kind = "hz"},
  {id = "sweep_hi", label = "TO", kind = "hz"},
  {id = "sweep_time", label = "TIME", kind = "sec"},
  {id = "sweep_retrig", label = "RETRIG", kind = "option"},
}

local ready = false      -- init done: keys and encoders can come in before (the params don't exist yet)
local sel = 1            -- the selected parameter
local first = 1          -- the first parameter in view
local k1_held = false
local burst_until = 0 -- when the tone burst in progress ends
local sweep_pos = 0   -- where the sweep is in its cycle, 0..1 (from the engine)
local pos_poll
local scope = nil     -- the output signal over one cycle, 62 samples (from the engine)
local dirty = true
local redraw_metro

local function pset_file() return norns.state.data .. "last.pset" end

local function dbamp(db)
  if db <= -80 then return 0 end
  return 10 ^ (db / 20)
end

local function index_of(list, v)
  if type(v) == "number" then
    v = math.floor(v + 0.5)
    if v >= 1 and v <= #list then return v end
    return nil
  end
  for i, name in ipairs(list) do
    if name == tostring(v) then return i end
  end
  return nil
end

-- with RETRIG on, a sound that starts (the output on, a burst) starts the sweep from its
-- beginning
local function retrigger()
  if params:get("sweep_retrig") == 2 then engine.sweepreset() end
end

local function fire_burst()
  local ms = params:get("burst_ms")
  retrigger()
  engine.burst(ms / 1000)
  burst_until = util.time() + ms / 1000
  dirty = true
end

local function fmt_hz(v)
  if v >= 10000 then return string.format("%.1fk", v / 1000) end
  return string.format("%dHz", math.floor(v + 0.5))
end

-- a knob's value as text
local function value_text(k)
  if k.kind == "option" then return params:string(k.id) end
  local v = params:get(k.id)
  if k.kind == "hz" then return fmt_hz(v) end
  if k.kind == "db" then return string.format("%.1fdB", v) end
  if k.kind == "ms" then return string.format("%dms", math.floor(v + 0.5)) end
  return string.format("%.1fs", v)
end

-- slow turning: 1 Hz a tick; faster: 1 % a tick, times the speed
local function hz_delta(v, d)
  if math.abs(d) == 1 then return v + d end
  return v * (1 + 0.01 * d)
end

local function adjust(k, d)
  local id = k.id
  if k.kind == "option" then
    params:delta(id, d > 0 and 1 or -1)
  elseif k.kind == "hz" then
    params:set(id, hz_delta(params:get(id), d))
  elseif k.kind == "db" then
    params:set(id, params:get(id) + d * 0.5)
  elseif k.kind == "ms" then
    params:set(id, params:get(id) + d * 25)
  else
    params:set(id, params:get(id) + d * 0.5)
  end
end

local function next_preset(d)
  local f = params:get("hz")
  local i
  if d > 0 then
    for k = 1, #PRESETS do if PRESETS[k] > f + 0.5 then i = k break end end
    i = i or #PRESETS
  else
    for k = #PRESETS, 1, -1 do if PRESETS[k] < f - 0.5 then i = k break end end
    i = i or 1
  end
  params:set("hz", PRESETS[i])
end

-- the state as one flat OSC message, in this order
local function state_args()
  return {
    params:get("on"),
    WAVES[params:get("wave")],
    params:get("hz"),
    params:get("level"),
    params:get("tone2") - 1,
    params:get("hz2"),
    SWEEPS[params:get("sweep")],
    params:get("sweep_lo"),
    params:get("sweep_hi"),
    params:get("sweep_time"),
    params:get("burst_ms"),
    params:get("sweep_retrig") - 1,
  }
end

-- OSC (norns listens on port 10111):
--   /pulse/on 0|1            /pulse/toggle
--   /pulse/wave sine|...     /pulse/hz 1000          /pulse/level -20 (dB)
--   /pulse/amp 0.1 (linear)
--   /pulse/tone2 0|1         /pulse/hz2 2000
--   /pulse/sweep off|up|down|up-down [from to seconds]
--   /pulse/restart 0|1 (retrigger the sweep with every start)  /pulse/retrigger (now)
--   /pulse/burst [ms]        /pulse/get  (answers /pulse/state to port 9000)
local NUMERIC = {
  hz = "hz", hz2 = "hz2", level = "level", burst_ms = "burst_ms",
  from = "sweep_lo", to = "sweep_hi", time = "sweep_time",
}

local function osc_event(path, args, from)
  -- the output signal, from the engine: not a command
  if path == "/pulse_scope" then
    scope = args
    dirty = true
    return
  end
  local cmd = path:match("^/pulse/(.+)$")
  if not cmd then return end
  local a = args or {}
  if NUMERIC[cmd] then
    local v = tonumber(a[1])
    if v then params:set(NUMERIC[cmd], v) end
  elseif cmd == "amp" then
    local v = tonumber(a[1])
    if v then params:set("level", v > 0 and 20 * math.log(v, 10) or -80) end
  elseif cmd == "on" then
    -- no argument: on
    params:set("on", (a[1] == nil or tonumber(a[1]) == 1) and 1 or 0)
  elseif cmd == "toggle" then
    params:set("on", 1 - params:get("on"))
  elseif cmd == "wave" then
    local i = index_of(WAVES, a[1])
    if i then params:set("wave", i) end
  elseif cmd == "tone2" then
    params:set("tone2", tonumber(a[1]) == 1 and 2 or 1)
  elseif cmd == "sweep" then
    local i = index_of(SWEEPS, a[1])
    if i then params:set("sweep", i) end
    if tonumber(a[2]) then params:set("sweep_lo", tonumber(a[2])) end
    if tonumber(a[3]) then params:set("sweep_hi", tonumber(a[3])) end
    if tonumber(a[4]) then params:set("sweep_time", tonumber(a[4])) end
  elseif cmd == "restart" then
    params:set("sweep_retrig", tonumber(a[1]) == 1 and 2 or 1)
  elseif cmd == "retrigger" then
    engine.sweepreset()
  elseif cmd == "burst" then
    if tonumber(a[1]) then params:set("burst_ms", tonumber(a[1])) end
    fire_burst()
  elseif cmd == "get" then
    if from and from[1] then
      osc.send({from[1], REPLY_PORT}, "/pulse/state", state_args())
    end
  end
  dirty = true
end

function init()
  params:add_separator("PULSE")
  params:add_binary("on", "output", "toggle", 0)
  params:set_action("on", function(v)
    engine.on(v)
    -- (not while the settings are being loaded: the other parameters don't exist yet)
    if v == 1 and ready then retrigger() end
    dirty = true
  end)

  params:add_option("wave", "wave", WAVES, 1)
  params:set_action("wave", function(v) engine.wave(v - 1) dirty = true end)

  params:add_control("hz", "freq", cs.new(20, 20000, 'exp', 0, 1000, "Hz"))
  params:set_action("hz", function(v) engine.hz(v) dirty = true end)

  -- 0 dB is full scale. -30 dB to start: nothing is hurt by a mistake
  params:add_control("level", "level", cs.new(-80, 0, 'lin', 0, -30, "dB"))
  params:set_action("level", function(v) engine.amp(dbamp(v)) dirty = true end)

  params:add_option("tone2", "second tone", TONE2, 1)
  params:set_action("tone2", function(v) engine.tone2(v - 1) dirty = true end)

  params:add_control("hz2", "freq 2", cs.new(20, 20000, 'exp', 0, 2000, "Hz"))
  params:set_action("hz2", function(v) engine.hz2(v) dirty = true end)

  params:add_option("sweep", "sweep", SWEEPS, 1)
  params:set_action("sweep", function(v) engine.sweep(v - 1) dirty = true end)

  params:add_control("sweep_lo", "sweep from", cs.new(20, 20000, 'exp', 0, 300, "Hz"))
  params:set_action("sweep_lo", function(v) engine.lo(v) dirty = true end)

  params:add_control("sweep_hi", "sweep to", cs.new(20, 20000, 'exp', 0, 3000, "Hz"))
  params:set_action("sweep_hi", function(v) engine.hi(v) dirty = true end)

  params:add_control("sweep_time", "sweep time", cs.new(0.5, 120, 'lin', 0, 5, "s"))
  params:set_action("sweep_time", function(v) engine.swtime(v) dirty = true end)

  params:add_option("sweep_retrig", "sweep retrigger", {"off", "on"}, 1)
  params:set_action("sweep_retrig", function() dirty = true end)

  params:add_control("burst_ms", "burst length", cs.new(1, 5000, 'lin', 0, 500, "ms"))
  params:set_action("burst_ms", function() dirty = true end)

  -- the last settings come back, but never an output that was left on
  if util.file_exists(pset_file()) then params:read(pset_file()) end
  params:set("on", 0)
  params:bang()

  osc.event = osc_event
  redraw_metro = metro.init(function()
    if burst_until > 0 and util.time() > burst_until then
      burst_until = 0
      dirty = true
    end
    if dirty then
      redraw()
      dirty = false
    end
  end, 1 / 30)
  redraw_metro:start()

  -- the engine tells where the sweep is, for the marker in the sweep view
  pos_poll = poll.set("sweep_pos")
  if pos_poll then
    pos_poll.time = 1 / 15
    pos_poll.callback = function(v)
      sweep_pos = v
      if params:get("sweep") > 1 then dirty = true end
    end
    pos_poll:start()
  end
  ready = true
end

function key(n, z)
  if not ready then return end
  -- norns only sends K1 to the script once it's held (0.25 s)
  if n == 1 then
    k1_held = (z == 1)
    dirty = true
    return
  end
  if z == 0 then return end

  if n == 3 then
    if not k1_held then params:set("on", 1 - params:get("on")) end
  elseif n == 2 then
    if k1_held then
      -- through the presets, from the last one back to the first
      if params:get("hz") >= PRESETS[#PRESETS] - 0.5 then
        params:set("hz", PRESETS[1] - 1)
      end
      next_preset(1)
    else
      fire_burst()
    end
  end
  dirty = true
end

function enc(n, d)
  if not ready then return end
  if n == 2 then
    sel = util.clamp(sel + (d > 0 and 1 or -1), 1, #KNOBS)
    -- scroll just far enough to keep the selected one in view
    if sel < first then first = sel end
    if sel > first + VISIBLE - 1 then first = sel - VISIBLE + 1 end
  elseif n == 3 then
    adjust(KNOBS[sel], d)
  end
  dirty = true
end

-- one sample of the wave: ph in cycles. noise is a fixed pattern, so it stands still
local function sample(w, ph, px)
  local x = ph % 1
  if w == 1 then return math.sin(2 * math.pi * x)
  elseif w == 2 then return x < 0.5 and 4 * x - 1 or 3 - 4 * x
  elseif w == 3 then return x < 0.5 and 1 or -1
  elseif w == 4 then return 2 * x - 1
  end
  return ((px * 7919 + 13) % 97) / 48.5 - 1
end

local function is_playing()
  return params:get("on") == 1 or util.time() < burst_until
end

-- the two views at the top, side by side over the full width: the signal on the left, the
-- sweep on the right
local WAVE_VIEW = {x = 0, y = 0, w = 62, h = 36}
local SWEEP_VIEW = {x = 66, y = 0, w = 62, h = 36}

-- the combined waveform, one cycle of the first tone (with two tones the sum). While a sound
-- plays: the actual output signal of the engine, scaled to fill the view. Otherwise the
-- wave as set, drawn from the settings
local function draw_wave_view()
  local v = WAVE_VIEW
  local top, bottom = v.y + 1, v.y + v.h - 2
  local mid, half = (top + bottom) / 2, (bottom - top) / 2

  local peak = 0
  if scope then
    for i = 1, #scope do peak = math.max(peak, math.abs(scope[i])) end
  end
  local live = is_playing() and scope and peak > 1e-5

  local wave = params:get("wave")
  local two = params:get("tone2") == 2
  local ratio = util.clamp(params:get("hz2") / params:get("hz"), 0.25, 4)
  screen.level(15)
  for px = 0, v.w - 1 do
    local y
    if live then
      y = (scope[px + 1] or 0) / peak
    else
      local ph = px / (v.w - 1)
      y = sample(wave, ph, px)
      if two then y = (y + sample(wave, ph * ratio, px + 40)) / 2 end
    end
    local yy = math.floor(mid - y * half + 0.5)
    if px == 0 then screen.move(v.x, yy) else screen.line(v.x + px, yy) end
  end
  screen.stroke()
end

-- the position on the frequency scale (0 FROM .. 1 TO) at c, 0..1 into the sweep
local function sweep_phase(mode, c)
  if mode == 2 then return c end
  if mode == 3 then return 1 - c end
  return 1 - math.abs(2 * c - 1)
end

-- the sweep: the frequency over one sweep on a log scale, 20 Hz at the bottom to 20 kHz
-- on top, with a marker where the sweep is now (it runs while the output is off, too).
-- no sweep: a dim line at the signal's frequency
local function draw_sweep_view()
  local v = SWEEP_VIEW
  local mode = params:get("sweep")
  local top, bottom = v.y + 1, v.y + v.h - 2
  local function y_of(f)
    f = util.clamp(f, 20, 20000)
    return math.floor(bottom - (bottom - top) * math.log(f / 20) / math.log(1000) + 0.5)
  end

  if mode == 1 then
    local yy = y_of(params:get("hz"))
    screen.level(6)
    screen.move(v.x, yy)
    screen.line(v.x + v.w - 1, yy)
    screen.stroke()
    return
  end

  local lo, hi = params:get("sweep_lo"), params:get("sweep_hi")
  local function y_at(c) return y_of(lo * (hi / lo) ^ sweep_phase(mode, c)) end
  screen.level(15)
  for px = 0, v.w - 1 do
    local yy = y_at(px / (v.w - 1))
    if px == 0 then screen.move(v.x, yy) else screen.line(v.x + px, yy) end
  end
  screen.stroke()

  local c = util.clamp(sweep_pos, 0, 1)
  screen.rect(v.x + math.floor(c * (v.w - 1)) - 1, y_at(c) - 1, 3, 3)
  screen.fill()
end

function redraw()
  if not ready then return end
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)

  draw_wave_view()
  draw_sweep_view()

  -- the parameters at the bottom: VISIBLE of them, scrolled with E2
  local cw = 128 / VISIBLE
  for j = 0, VISIBLE - 1 do
    local i = first + j
    local k = KNOBS[i]
    if k then
      local x = math.floor(j * cw)
      screen.level(i == sel and 15 or 4)
      screen.move(x + 2, 46)
      screen.text(k.label)
      screen.move(x + 2, 58)
      screen.text(value_text(k))
    end
  end

  -- a little square in the bottom right corner while a sound plays
  if is_playing() then
    screen.level(15)
    screen.rect(122, 58, 5, 5)
    screen.fill()
  end
  screen.update()
end

function cleanup()
  osc.event = nil
  if redraw_metro then redraw_metro:stop() end
  if pos_poll then pos_poll:stop() end
  params:write(pset_file())
end
