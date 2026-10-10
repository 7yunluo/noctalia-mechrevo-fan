--!nonstrict
-- One operation at a time. WUJIE firmware overwrites direct fan values even
-- with custom tables enabled, so unchanged targets need a one-second heartbeat.
local SNAPSHOT = "mechrevo_fan.status"
local COMMAND = "mechrevo_fan.command"
local SCALE = 200
local TICK_MS = 250
local KEEPALIVE_MS = 1000
local TIMEOUT_MS = 8000
local STALE_MS = 15000
local CURVES = {
  quiet = {{45, 0}, {55, 50}, {65, 70}, {75, 100}, {85, 130}, {95, 170}, {105, 200}},
  balanced = {{45, 0}, {50, 50}, {60, 80}, {70, 110}, {80, 150}, {90, 180}, {100, 200}},
  performance = {{40, 50}, {50, 70}, {60, 100}, {70, 130}, {80, 160}, {90, 190}, {100, 200}},
}
local desired = {mode = "auto", raw = 100, curve = nil}
local actual = {fan0 = -1, fan1 = -1, temp0 = -1, temp1 = -1, mode = 0, minSpeed = 25}
local lastReadAt = nil
local inFlight = nil
local stopped = false
local ready = false
local autoNeeded = true
local nextReadAt = 0
local nextWriteAt = 0
local retryAt = 0
local failures = 0
local errorCode = ""
local confirmed = false
local appliedRaw = nil
local mismatchCount = 0
local safetyReason = nil
local generation = 0
local lastSignature = nil
local pump

local function cfg(key) return noctalia.getConfig(key) end
local function now() return noctalia.nowMs() end
local function clamp(value, low, high, fallback)
  local n = tonumber(value)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then n = fallback end
  return math.max(low, math.min(high, n))
end
local function curveName()
  local name = desired.curve or cfg("curve")
  return CURVES[name] and name or "balanced"
end
local function sensorTemp()
  if cfg("sensor") == "max" then return math.max(actual.temp0, actual.temp1) end
  return actual.temp0
end
local function validTemp(t) return t > 0 and t <= 125 end
local function safetyTemp() return clamp(cfg("safety_temp_c"), 70, 105, 95) end
local function targetRaw()
  if desired.mode == "auto" then return nil end
  if desired.mode == "manual" then return desired.raw end
  local t = sensorTemp()
  if not validTemp(t) then return nil end
  local points = CURVES[curveName()]
  local raw = points[#points][2]
  if t <= points[1][1] then raw = points[1][2] end
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    if t >= a[1] and t < b[1] then
      raw = a[2] + (b[2] - a[2]) * (t - a[1]) / (b[1] - a[1])
      break
    end
  end
  raw = math.max(raw, SCALE * clamp(cfg("min_fan_percent"), 0, 60, 0) / 100)
  return math.floor(clamp(raw, 0, SCALE, 100) + 0.5)
end
local function helperPath()
  local path = cfg("helper_path")
  if type(path) ~= "string" or path == "" then path = "~/.local/bin/mechrevo-fanctl" end
  return noctalia.expandPath(path)
end
local function statePath() return noctalia.pluginDataDir() .. "/state.json" end
local function save()
  local ok, err = pcall(function()
    noctalia.writeFile(statePath(), noctalia.json.encode({raw = desired.raw, curve = desired.curve}))
  end)
  if not ok then noctalia.log("fan preferences: " .. tostring(err)) end
end
local function publish()
  local healthy = lastReadAt ~= nil and now() - lastReadAt < STALE_MS and ready
  local snap = {
    ok = healthy, fan0 = actual.fan0, fan1 = actual.fan1,
    temp0 = actual.temp0, temp1 = actual.temp1, mode = actual.mode,
    minSpeed = actual.minSpeed, scale = SCALE, modeName = desired.mode,
    targetRaw = targetRaw() or 0, manualRaw = desired.raw,
    appliedRaw = appliedRaw, curve = curveName(), sensor = cfg("sensor") or "cpu",
    safetyTempC = safetyTemp(), live = desired.mode ~= "auto" and confirmed and healthy,
    pending = autoNeeded or (desired.mode ~= "auto" and not confirmed),
    writable = healthy and errorCode ~= "helper-stuck",
    error = errorCode ~= "" and noctalia.tr("error." .. errorCode) or "",
    safetyReason = safetyReason,
  }
  local signature = noctalia.json.encode(snap)
  if signature ~= lastSignature then
    lastSignature = signature
    noctalia.state.set(SNAPSHOT, snap)
  end
end
local function returnAuto(reason)
  generation = generation + 1
  desired.mode = "auto"
  confirmed = false
  appliedRaw = nil
  autoNeeded = true
  retryAt = 0
  safetyReason = reason
    if reason then
    errorCode = reason
    noctalia.log("fan control returned to auto: " .. reason)
    noctalia.notify(noctalia.tr("notify.safety.title"), noctalia.tr("error." .. reason))
  end
end
local function checkSafety()
  if desired.mode == "auto" then return end
  local t = sensorTemp()
  if lastReadAt == nil or now() - lastReadAt >= STALE_MS then
    returnAuto("sensor-stale")
  elseif not validTemp(t) then
    returnAuto("sensor-invalid")
  elseif t >= safetyTemp() then
    returnAuto("overheat")
  end
end
local function parseStatus(stdout)
  local ok, data = pcall(noctalia.json.decode, stdout or "")
  if not ok or type(data) ~= "table" or data.ok ~= true or data.scale ~= SCALE then return false end
  for _, key in ipairs({"fan0", "fan1", "temp0", "mode"}) do
    local n = tonumber(data[key])
    if n == nil or n ~= n or n < 0 or n > 255 then return false end
  end
  for _, key in ipairs({"fan0", "fan1", "temp0", "mode"}) do actual[key] = tonumber(data[key]) end
  actual.temp1 = tonumber(data.temp1) or -1
  actual.minSpeed = clamp(data.minSpeed, 0, 100, 25)
  lastReadAt = now()
  ready = true
  return true
end
local function classify(result)
  if result.timedOut then return "helper-stuck" end
  if result.spawnFailed or result.exitCode == 127 then return "helper-missing" end
  local codes = {[2] = "invalid-args", [3] = "device-missing", [4] = "permission-denied", [5] = "read-failed", [6] = "busy"}
  return codes[result.exitCode] or "write-failed"
end
local function fail(code, kind)
  errorCode = code
  confirmed = false
  failures = failures + 1
  retryAt = now() + math.min(30000, 1000 * 2 ^ math.min(failures - 1, 5))
  noctalia.log("fan " .. kind .. " failed: " .. code)
  if kind == "write" and code ~= "busy" then returnAuto(code) end
end
local function matches(raw)
  -- The driver snaps nonzero targets below 25% to off or its minimum.
  local minimum = actual.minSpeed * SCALE / 100
  local expected = raw
  if raw < minimum / 2 then expected = 0
  elseif raw < minimum then expected = minimum end
  -- Allow the EC minimum step and the short decay between writes. Both fans
  -- must follow; ioctl success alone does not confirm control.
  local tolerance = expected == 0 and 30 or 20
  return math.abs(actual.fan0 - expected) <= tolerance and math.abs(actual.fan1 - expected) <= tolerance
end
local function complete(op, result)
  if inFlight ~= op or stopped then return end
  inFlight = nil
  if result.timedOut or result.spawnFailed or result.exitCode ~= 0 then
    fail(classify(result), op.kind)
  elseif op.kind == "auto" then
    autoNeeded = false
    appliedRaw = nil
    confirmed = false
    failures = 0
    retryAt = 0
    if safetyReason == nil then errorCode = "" end
    nextReadAt = 0
  elseif not parseStatus(result.stdout) then
    fail("parse", op.kind)
  else
    failures = 0
    retryAt = 0
    nextReadAt = now() + clamp(cfg("poll_interval_ms"), 1000, 10000, 2000)
    if safetyReason == nil then errorCode = "" end
    checkSafety()
    if op.kind == "write" and op.generation == generation and desired.mode ~= "auto" then
      nextWriteAt = now() + KEEPALIVE_MS
      if matches(op.raw) then
        confirmed = true
        appliedRaw = op.raw
        mismatchCount = 0
      else
        confirmed = false
        mismatchCount = mismatchCount + 1
        errorCode = "control-not-applied"
        if mismatchCount >= 3 then returnAuto("control-not-applied") end
      end
    end
  end
  publish()
  -- The next tick drains commands; no recursive callback chain.
end
local function start(kind, raw)
  local path = helperPath()
  local argv = {path, kind == "read" and "status" or kind == "write" and "set-both" or "auto"}
  if kind == "write" then table.insert(argv, tostring(raw)) end
  local op = {kind = kind, raw = raw, generation = generation, at = now()}
  inFlight = op
  local ok, started = pcall(noctalia.runAsync, argv, function(result)
    local success, err = pcall(complete, op, result)
    if not success then
      inFlight = nil
      noctalia.log("fan callback: " .. tostring(err))
      fail("parse", op.kind)
      publish()
    end
  end, TIMEOUT_MS)
  if not ok or not started then complete(op, {spawnFailed = true, exitCode = 127}) end
end
pump = function()
  if stopped then return end
  checkSafety()
  if inFlight then
    if now() - inFlight.at > TIMEOUT_MS + 2000 then
      errorCode = "helper-stuck"
      confirmed = false
      -- Keep the slot until the host returns the timeout callback.
    end
    publish()
    return
  end
  if now() < retryAt then publish(); return end
  if autoNeeded then start("auto")
  elseif not ready then start("read")
  elseif desired.mode ~= "auto" then
    local target = targetRaw()
    if target ~= nil and now() >= nextWriteAt then start("write", target) end
  elseif now() >= nextReadAt then start("read") end
  publish()
end
local function command(cmd)
  if type(cmd) ~= "table" then return end
  if cmd.action == "refresh" then
    retryAt = 0
    nextReadAt = 0
  elseif cmd.action == "set_curve" and CURVES[cmd.name] then
    desired.curve = cmd.name
    nextWriteAt = 0
    save()
  else
    local mode = cmd.mode
    if cmd.action == "cycle_mode" then
      mode = desired.mode == "auto" and "curve" or desired.mode == "curve" and "manual" or "auto"
    elseif cmd.action == "set_raw" then mode = "manual"
    elseif cmd.action ~= "set_mode" then return end
    if mode ~= "auto" and mode ~= "manual" and mode ~= "curve" then return end
    if mode == "auto" then returnAuto(nil)
    else
      -- A queued auto must complete before a new manual write.
      if not ready or not validTemp(sensorTemp()) or now() - (lastReadAt or 0) >= STALE_MS then
        errorCode = "sensor-invalid"
        publish()
        return
      end
      if sensorTemp() >= safetyTemp() then
        returnAuto("overheat")
        publish()
        return
      end
      generation = generation + 1
      desired.mode = mode
      if cmd.raw ~= nil then desired.raw = math.floor(clamp(cmd.raw, 0, SCALE, desired.raw) + 0.5) end
      confirmed = false
      appliedRaw = nil
      safetyReason = nil
      errorCode = ""
      mismatchCount = 0
      nextWriteAt = 0
      retryAt = 0
    end
    save()
  end
  pump()
end
function update() pump() end
function onConfigChanged()
  nextWriteAt = 0
  nextReadAt = 0
  noctalia.setUpdateInterval(TICK_MS)
  pump()
end
function onIpc(event, payload)
  if event == "command" then
    local ok, cmd = pcall(noctalia.json.decode, payload)
    if ok then command(cmd) end
  elseif event == "status" then
    noctalia.log("fan status: " .. noctalia.json.encode(noctalia.state.get(SNAPSHOT)))
  end
end
function onExit()
  stopped = true
  -- runAsync without callback survives destruction of the plugin VM. flock
  -- may still be held by an old write, so retry the handback in a detached shell.
  noctalia.runAsync({"/bin/sh", "-c", 'i=0; while [ "$i" -lt 10 ]; do "$1" auto && exit 0; i=$((i+1)); sleep 1; done', "fan-handback", helperPath()})
end
noctalia.state.watch(COMMAND, command)
local loaded, saved = pcall(function() return noctalia.json.decode(noctalia.readFile(statePath())) end)
if loaded and type(saved) == "table" then
  desired.raw = math.floor(clamp(saved.raw, 0, SCALE, 100) + 0.5)
  if CURVES[saved.curve] then desired.curve = saved.curve end
end
noctalia.setUpdateInterval(TICK_MS)
pump()
