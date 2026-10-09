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
local pendingRaw = nil -- 写入进行中收到的最新目标值
local safetyNotified = false -- 过热通知节流,温度回落后重置
local sensorWarned = false -- 温度无效警告节流,温度恢复后重置

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

-- 判断温度是否可用,<=0 或非数字视为无效(部分机型温度通道恒为 0)
local function tempValid(temp)
  return temp ~= nil and temp == temp and temp > 0
end

-- 取当前传感器温度;无效时返回非正值,由调用方决定如何处理
local function sensorTemp()
  local t0 = tonumber(status.temp0) or -1
  local t1 = tonumber(status.temp1) or -1
  if cfg("sensor") == "max" then
    if t0 <= 0 and t1 <= 0 then
      return -1
    end
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

-- 计算曲线目标值;温度无效时返回 nil,请求交还 auto。
-- 用 auto 而非沿用旧值:传感器故障下曲线无法跟随温度,保持旧值可能既过热又过吵。
local function curveTarget()
  if not tempValid(sensorTemp()) then
    return nil
  end
  return curveRaw()
end

local function publish()
  status.ok = backendState == true
  status.modeName = desiredMode
  status.sensor = cfg("sensor") or "cpu"
  status.safetyTempC = tonumber(cfg("safety_temp_c")) or 95
  status.scale = RAW_MAX
  status.curve = curveName()
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

-- 交还 EC 自动控制。置位与写入结果无关:desiredMode 已由调用方置为 auto,
-- 保证交还失败时 tick 不会再把手动/曲线值写回去,避免与过热保护对打。
local function sendAuto()
  noctalia.runAsync(helper() .. " auto", function(result)
    if result.exitCode == 0 then
      status.targetRaw = 0
    else
      status.error = "write-failed"
    end
    publish()
  end, 3000)
end

-- 写两个风扇的目标占空比。左风扇在驱动修复后走共享曲线表,此处同步写入两条路径。
-- 写入进行中若有新目标,记为 pending,当前写完成后立即补写,避免快速拖动滑块丢值。
local function applyRaw(raw)
  if writing then
    pendingRaw = raw
    status.targetRaw = raw
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
    if pendingRaw ~= nil then
      local next = pendingRaw
      pendingRaw = nil
      applyRaw(next)
    end
  end, 3000)
end

local function applyDesired()
  if desiredMode == MODE_AUTO then
    sendAuto()
  elseif desiredMode == MODE_MANUAL then
    applyRaw(desiredRaw)
  elseif desiredMode == MODE_CURVE then
    local raw = curveTarget()
    -- 曲线模式下但没有有效温度时交还 auto,而非写入低值。只改意向不动风扇
    -- 已有档位,下一次 tick 由 auto 分支真正交还。
    if raw == nil then
      desiredMode = MODE_AUTO
      desiredRaw = 0
      publish()
    else
      applyRaw(raw)
    end
  end
end

local function safetyCheck()
  local safety = tonumber(cfg("safety_temp_c")) or 95
  local temp = sensorTemp()
  if not tempValid(temp) then
    -- 温度不可用:不写曲线/手动低值,交还 auto 保底,警告只发一次
    if desiredMode ~= MODE_AUTO then
      if not sensorWarned then
        sensorWarned = true
        noctalia.notify(noctalia.tr("notify.sensor.title"), noctalia.tr("notify.sensor.body"))
      end
      desiredMode = MODE_AUTO
      desiredRaw = 0
      isLive = false
      publish()
    end
    return
  end
  sensorWarned = false
  if desiredMode ~= MODE_AUTO and temp >= safety then
    -- 立即乐观置位 auto,否则交还失败时下一 tick 会再次触发
    if not safetyNotified then
      safetyNotified = true
      noctalia.notify(
        noctalia.tr("notify.safety.title"),
        noctalia.tr("notify.safety.body", { temp = tostring(temp) })
      )
    end
    desiredMode = MODE_AUTO
    desiredRaw = 0
    isLive = false
    publish()
    sendAuto()
  elseif temp < safety - 5 then
    safetyNotified = false
  end
end

-- 手动模式初值:优先沿用有效历史值,否则用当前实测占空比,读不到再取中档。
-- 面板直接切手动时不会因 desiredRaw 为 0 把风扇打到停转。
local function manualSeedRaw()
  if desiredRaw > 0 then
    return desiredRaw
  end
  local measured = math.max(tonumber(status.fan0) or -1, tonumber(status.fan1) or -1)
  if measured > 0 then
    return math.min(RAW_MAX, measured)
  end
  return math.floor(RAW_MAX / 2)
end

local function setMode(mode, raw)
  if mode == MODE_AUTO then
    isLive = false
    desiredMode = MODE_AUTO
    publish()
    sendAuto()
  elseif mode == MODE_MANUAL then
    isLive = true
    desiredMode = MODE_MANUAL
    if raw then
      desiredRaw = math.max(0, math.min(RAW_MAX, tonumber(raw) or desiredRaw))
    else
      desiredRaw = manualSeedRaw()
    end
    publish()
    applyRaw(desiredRaw)
  elseif mode == MODE_CURVE then
    if not tempValid(sensorTemp()) then
      -- 温度无效时曲线无法计算,直接交还 auto,避免写入最低档
      setMode(MODE_AUTO)
      return
    end
    isLive = true
    desiredMode = MODE_CURVE
    publish()
    applyRaw(curveTarget())
  end
end

local function cycleMode()
  if desiredMode == MODE_AUTO then
    setMode(MODE_CURVE)
  elseif desiredMode == MODE_CURVE then
    setMode(MODE_MANUAL)
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
        if desiredMode == MODE_CURVE then
          local raw = curveTarget()
          if raw == nil then
            setMode(MODE_AUTO)
          else
            applyRaw(raw)
          end
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
  -- 插件停用或外壳退出时交还 EC 控制,并把持久化模式重置为 auto,
  -- 避免下次启动时突然夺回风扇(期间 EC 可能已经按自己的曲线调整过)
  if desiredMode ~= MODE_AUTO and reason ~= "reload" then
    desiredMode = MODE_AUTO
    isLive = false
    publish()
    noctalia.runAsync(helper() .. " auto", nil, 2000)
  end
end

noctalia.setUpdateInterval(tonumber(cfg("poll_interval_ms")) or TICK_MS)

publish()
refresh()
