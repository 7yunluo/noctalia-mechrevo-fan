--!nonstrict
-- Mechrevo Fan Control 后台服务。
--
-- 职责:
--   1. 周期调 mechrevo-fanctl status 读取风扇占空比/EC 温度,发布到插件共享状态
--   2. 收到命令时调 mechrevo-fanctl set / auto 写风扇
--   3. manual/curve 模式下周期重施目标值,抵消 EC 固件自行调整
--   4. 过热保护:达到 safety_temp_c 时立刻交还 EC 自动模式

local SNAPSHOT = "mechrevo_fan.status"
local COMMAND = "mechrevo_fan.command"
local LAST = "mechrevo_fan.last"

local MODE_AUTO = "auto"
local MODE_MANUAL = "manual"
local MODE_CURVE = "curve"

local RAW_MAX = 200 -- 100% 对应的原始占空比值(驱动 NB02_FAN_SPEED_MAX=0xc8)
local TICK_MS = 2000

-- 温度-转速曲线(原始值 0-200)
local CURVES = {
  quiet = {
    { temp = 45, raw = 0 },
    { temp = 55, raw = 50 },
    { temp = 65, raw = 70 },
    { temp = 75, raw = 100 },
    { temp = 85, raw = 130 },
    { temp = 95, raw = 170 },
    { temp = 105, raw = 200 },
  },
  balanced = {
    { temp = 45, raw = 0 },
    { temp = 50, raw = 50 },
    { temp = 60, raw = 80 },
    { temp = 70, raw = 110 },
    { temp = 80, raw = 150 },
    { temp = 90, raw = 180 },
    { temp = 100, raw = 200 },
  },
  performance = {
    { temp = 40, raw = 50 },
    { temp = 50, raw = 70 },
    { temp = 60, raw = 100 },
    { temp = 70, raw = 130 },
    { temp = 80, raw = 160 },
    { temp = 90, raw = 190 },
    { temp = 100, raw = 200 },
  },
}

local status = {
  ok = false,
  fan0 = -1,
  fan1 = -1,
  temp0 = -1,
  temp1 = -1,
  mode = 0,
  minSpeed = 25,
  scale = RAW_MAX,
  modeName = MODE_AUTO,
  targetRaw = 0,
  appliedRaw = 0,
  curve = "balanced",
  sensor = "cpu",
  safetyTempC = 95,
  error = "",
}

local last = noctalia.state.get(LAST) or {}
local isLive = last.live == true
local desiredMode = last.mode or MODE_AUTO
local desiredRaw = tonumber(last.raw) or 0
local desiredCurve = last.curve -- 面板里选过的曲线,优先于设置项
local backendState = nil -- nil=未探测, true=可用, false=不可用

local reading = false
local writing = false

local function cfg(key)
  return noctalia.getConfig(key)
end

local function helper()
  local path = cfg("helper_path")
  if type(path) ~= "string" or path == "" then
    path = "mechrevo-fanctl"
  end
  return path
end

local function sensorTemp()
  local t0 = tonumber(status.temp0) or -1
  local t1 = tonumber(status.temp1) or -1
  if cfg("sensor") == "max" then
    return math.max(t0, t1)
  end
  if t0 > 0 then
    return t0
  end
  return t1
end

local function curveName()
  local name = desiredCurve or cfg("curve") or "balanced"
  if not CURVES[name] then
    name = "balanced"
  end
  return name
end

local function curveRaw()
  local name = curveName()
  status.curve = name
  local points = CURVES[name]
  local temp = sensorTemp()
  local raw

  if temp < points[1].temp then
    raw = points[1].raw
  elseif temp >= points[#points].temp then
    raw = points[#points].raw
  else
    raw = points[#points].raw
    for i = 1, #points - 1 do
      local a, b = points[i], points[i + 1]
      if temp >= a.temp and temp < b.temp then
        local ratio = (temp - a.temp) / (b.temp - a.temp)
        raw = math.floor(a.raw + (b.raw - a.raw) * ratio + 0.5)
        break
      end
    end
  end

  local floorPercent = tonumber(cfg("min_fan_percent")) or 0
  local floorRaw = math.floor(RAW_MAX * floorPercent / 100 + 0.5)
  if floorRaw > raw then
    raw = floorRaw
  end
  return math.max(0, math.min(RAW_MAX, raw))
end

local function publish()
  status.ok = backendState == true
  status.modeName = desiredMode
  status.sensor = cfg("sensor") or "cpu"
  status.safetyTempC = tonumber(cfg("safety_temp_c")) or 95
  status.scale = RAW_MAX
  noctalia.state.set(SNAPSHOT, {
    ok = status.ok,
    fan0 = status.fan0,
    fan1 = status.fan1,
    temp0 = status.temp0,
    temp1 = status.temp1,
    mode = status.mode,
    minSpeed = status.minSpeed,
    scale = status.scale,
    modeName = status.modeName,
    targetRaw = status.targetRaw,
    appliedRaw = status.appliedRaw,
    curve = status.curve,
    sensor = status.sensor,
    safetyTempC = status.safetyTempC,
    error = status.error,
    live = isLive,
  })
  noctalia.state.set(LAST, {
    live = isLive,
    mode = desiredMode,
    raw = desiredRaw,
    curve = desiredCurve,
  })
end

local function parseStatus(stdout)
  local decoded = noctalia.json.decode(stdout)
  if type(decoded) ~= "table" then
    return false
  end
  status.fan0 = tonumber(decoded.fan0) or -1
  status.fan1 = tonumber(decoded.fan1) or -1
  status.temp0 = tonumber(decoded.temp0) or -1
  status.temp1 = tonumber(decoded.temp1) or -1
  status.mode = tonumber(decoded.mode) or 0
  status.minSpeed = tonumber(decoded.minSpeed) or 25
  return true
end

local function refresh(onDone)
  if reading then
    if onDone then onDone() end
    return
  end
  reading = true
  local ok = noctalia.runAsync(helper() .. " status", function(result)
    reading = false
    local rc = result.exitCode
    if rc == 0 and parseStatus(result.stdout or "") then
      backendState = true
      status.error = ""
    elseif rc == 0 then
      backendState = true
      status.error = "parse"
    elseif rc == 3 then
      backendState = false
      status.error = "device-missing"
    elseif rc == 127 then
      backendState = false
      status.error = "helper-missing"
    else
      backendState = false
      status.error = "read-failed"
    end
    publish()
    if onDone then onDone() end
  end, 3000)
  if not ok then
    reading = false
    backendState = false
    status.error = "helper-missing"
    publish()
    if onDone then onDone() end
  end
end

local function sendAuto(onDone)
  noctalia.runAsync(helper() .. " auto", function(result)
    if result.exitCode == 0 then
      desiredMode = MODE_AUTO
      status.targetRaw = 0
      if onDone then onDone() end
    end
    publish()
  end, 3000)
end

-- 写两个风扇的目标占空比。左风扇在驱动修复后走共享曲线表,此处同步写入两条路径。
local function applyRaw(raw)
  if writing then
    return
  end
  writing = true
  status.targetRaw = raw
  local h = helper()
  local cmd = h .. " set 0 " .. tostring(raw) .. " && " .. h .. " set 1 " .. tostring(raw)
  noctalia.runAsync(cmd, function(result)
    writing = false
    if result.exitCode == 0 then
      status.appliedRaw = raw
    else
      status.error = "write-failed"
    end
    publish()
  end, 3000)
end

local function applyDesired()
  if desiredMode == MODE_AUTO then
    sendAuto()
  elseif desiredMode == MODE_MANUAL then
    applyRaw(desiredRaw)
  elseif desiredMode == MODE_CURVE then
    applyRaw(curveRaw())
  end
end

local function safetyCheck()
  local safety = tonumber(cfg("safety_temp_c")) or 95
  local temp = sensorTemp()
  if desiredMode ~= MODE_AUTO and temp > 0 and temp >= safety then
    noctalia.notify(
      noctalia.tr("notify.safety.title"),
      noctalia.tr("notify.safety.body", { temp = tostring(temp) })
    )
    isLive = false
    sendAuto()
  end
end

local function setMode(mode, raw)
  if mode == MODE_AUTO then
    isLive = false
    sendAuto()
  elseif mode == MODE_MANUAL then
    isLive = true
    desiredMode = MODE_MANUAL
    if raw then
      desiredRaw = math.max(0, math.min(RAW_MAX, tonumber(raw) or desiredRaw))
    end
    applyRaw(desiredRaw)
  elseif mode == MODE_CURVE then
    isLive = true
    desiredMode = MODE_CURVE
    applyRaw(curveRaw())
  end
end

local function cycleMode()
  if desiredMode == MODE_AUTO then
    setMode(MODE_CURVE)
  elseif desiredMode == MODE_CURVE then
    setMode(MODE_MANUAL, desiredRaw > 0 and desiredRaw or math.floor(RAW_MAX / 2))
  else
    setMode(MODE_AUTO)
  end
end

local function handleCommand(cmd)
  if type(cmd) == "table" then
    if cmd.action == "set_mode" and type(cmd.mode) == "string" then
      setMode(cmd.mode, cmd.raw)
    elseif cmd.action == "set_raw" then
      isLive = true
      desiredMode = MODE_MANUAL
      desiredRaw = math.max(0, math.min(RAW_MAX, tonumber(cmd.raw) or 0))
      applyRaw(desiredRaw)
    elseif cmd.action == "set_curve" and type(cmd.name) == "string" then
      if CURVES[cmd.name] then
        desiredCurve = cmd.name
        status.curve = cmd.name
        if desiredMode == MODE_CURVE then
          applyRaw(curveRaw())
        else
          publish()
        end
      end
    elseif cmd.action == "cycle_mode" then
      cycleMode()
    elseif cmd.action == "refresh" then
      refresh()
    end
  elseif cmd == "cycle_mode" then
    cycleMode()
  elseif cmd == "refresh" then
    refresh()
  end
end

noctalia.state.watch(COMMAND, handleCommand)

local function tick()
  refresh(function()
    if desiredMode ~= MODE_AUTO then
      safetyCheck()
      if desiredMode ~= MODE_AUTO then
        applyDesired()
      end
    end
  end)
end

function update()
  tick()
end

function onConfigChanged()
  noctalia.setUpdateInterval(tonumber(cfg("poll_interval_ms")) or TICK_MS)
  refresh()
end

function onEnable()
  refresh()
end

function onExit(_signal, reason)
  -- 插件停用或外壳退出时交还 EC 控制,避免风扇停在手动值上
  if desiredMode ~= MODE_AUTO and reason ~= "reload" then
    noctalia.runAsync(helper() .. " auto", nil, 2000)
  end
end

noctalia.setUpdateInterval(tonumber(cfg("poll_interval_ms")) or TICK_MS)

publish()
refresh()
