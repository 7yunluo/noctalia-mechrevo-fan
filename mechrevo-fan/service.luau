--!nonstrict
-- Mechrevo Fan Control 后台服务。
--
-- 分区: CONFIG / STATE MODEL / EC TRANSPORT / EC SCHEDULER / MODE ENGINE /
--       PUBLISH / LIFECYCLE
--
-- 硬不变式:
--   1. 只有 EC SCHEDULER 发起 helper 子进程;
--   2. 只有 MODE ENGINE 修改 desired 意图;
--   3. 只有 PUBLISH 写 UI 通道;
--   4. 任何「置位」与「写 EC」不写在同一函数里。

-- ══════════════════════════════════════════════════════════════════════════
-- 1. CONFIG & CONSTANTS
-- ══════════════════════════════════════════════════════════════════════════

local SNAPSHOT = "mechrevo_fan.status"
local COMMAND = "mechrevo_fan.command"

local MODE_AUTO = "auto"
local MODE_MANUAL = "manual"
local MODE_CURVE = "curve"

local RAW_MAX = 200 -- 100% 对应的原始占空比(驱动 NB02_FAN_SPEED_MAX=0xc8)
local RAW_STEP = 5 -- 触发一次写的 raw 最小变化量
local RAW_ZERO_FLOOR = 1 -- 0 归一化为 1,避免 EC 数分钟后自行抬升

-- 调度节奏:宿主 tick 固定,读节奏由 poll_interval_ms 决定
local SCHED_TICK_MS = 250
local WRITE_DEBOUNCE_MS = 500 -- 写请求合并窗口
local EC_WRITE_MIN_INTERVAL_MS = 2000 -- 两次真实 EC 写的最小间隔
local TEMP_REAPPLY_DELTA_C = 2 -- 曲线模式下重算目标的温度变化阈值
local POST_WRITE_SETTLE_MS = 1500 -- 写完成后延迟多久才允许读
local USER_INTENT_BYPASS_MS = 1000 -- 用户主动操作可穿透去抖的窗口

local BACKOFF_BASE_MS = 2000 -- 失败退避基数
local BACKOFF_MAX_MS = 60000 -- 失败退避上限
local SILENT_PROBE_MS = 60000 -- 静默/卡死态的慢探间隔

-- 看门狗阈值,同时用作 runAsync 超时
local WATCHDOG_MS = { read = 5000, write = 8000, auto = 4000 }

local DEFAULT_HELPER = "~/.local/bin/mechrevo-fanctl"

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

-- ══════════════════════════════════════════════════════════════════════════
-- 2. STATE MODEL
-- ══════════════════════════════════════════════════════════════════════════

local function cfg(key)
  return noctalia.getConfig(key)
end

local function now()
  return noctalia.nowMs()
end

-- 意图:用户/策略想要什么。只由 MODE ENGINE 修改
local desired = {
  mode = MODE_AUTO,
  raw = 0, -- 手动档滑块值(原样保留,0 不做归一化)
  targetRaw = nil, -- 当前模式下真正要下发的目标(已归一化)
  curve = nil, -- 面板选过的曲线,优先于设置项
  sensor = "cpu",
  safety_c = 95,
}

-- 实测:硬件当前是什么。只由读回调修改
local actual = {
  fan0 = -1,
  fan1 = -1,
  temp0 = -1,
  temp1 = -1,
  mode_reg = 0,
  minSpeed = 25,
  lastReadAt = 0,
}

-- 健康:后端可用性与错误。只由传输层结果修改
local health = {
  ok = false,
  writable = true,
  error = "",
  backoff_n = 0,
  backoffUntil = 0,
  stuck = false,
  silent = false,
}

-- ══════════════════════════════════════════════════════════════════════════
-- 3. EC TRANSPORT
-- ══════════════════════════════════════════════════════════════════════════

local ERROR_CODES = {
  ["device-missing"] = true,
  ["permission-denied"] = true,
  ["helper-missing"] = true,
  ["read-failed"] = true,
  ["parse"] = true,
  ["write-failed"] = true,
  ["invalid-args"] = true,
  ["helper-stuck"] = true,
}

-- 错误码 -> 已翻译文本,未知码原样输出
local function errText(code)
  if ERROR_CODES[code] then
    return noctalia.tr("error." .. code)
  end
  return code
end

-- 解析 helper 可执行文件路径(全网唯一一处)
local function resolveHelperPath()
  local path = cfg("helper_path")
  if type(path) ~= "string" or path == "" then
    path = DEFAULT_HELPER
  end
  local expanded = noctalia.expandPath(path)
  if type(expanded) ~= "string" or expanded == "" then
    return nil
  end
  return expanded
end

-- 目标值归一化:clamp 到 0..200,0 抬到 1
local function normalizeRaw(raw)
  local n = math.floor((tonumber(raw) or 0) + 0.5)
  if n < 0 then
    n = 0
  elseif n > RAW_MAX then
    n = RAW_MAX
  end
  if n == 0 then
    n = RAW_ZERO_FLOOR
  end
  return n
end

local function tempValid(temp)
  return temp ~= nil and temp == temp and temp > 0
end

-- 按 Op 类型组成完整 argv(API 24,直接 exec 无 shell)
local function buildArgv(path, op)
  if op.kind == "read" then
    return { path, "status" }
  elseif op.kind == "auto" then
    return { path, "auto" }
  end
  -- helper 的 set 一次只写一个风扇,左右两路由调度器串行成对下发
  return { path, "set", tostring(op.fan or 0), tostring(op.raw) }
end

-- ══════════════════════════════════════════════════════════════════════════
-- 4. EC SCHEDULER
-- ══════════════════════════════════════════════════════════════════════════

local inFlight = nil -- { id, kind, raw, startedAt, probe }
local opSeq = 0
local pendingWrite = nil -- { raw }: 下一轮写入的目标
local writeDueAt = nil
local writeStage = nil -- nil=空闲 / "fan0"=右路已发 / "fan1"=左路已发
local writeRoundRaw = nil -- 当前一轮写入的冻结目标,保证左右两路同值
local lastWriteAt = 0 -- 上一轮(左右两路)完成时刻
local appliedRaw = nil -- EC 已确认的占空比
local appliedMode = MODE_AUTO -- EC 已确认的控制模式
local statusEarliestAt = 0
local nextReadAt = 0
local probeAt = 0
local userIntentUntil = 0

-- 标记用户主动操作,允许一次穿透去抖
local function schedulerMarkUserIntent()
  userIntentUntil = now() + USER_INTENT_BYPASS_MS
end

-- 把下次读提前,允许穿透退避
local function schedulerRequestRead()
  nextReadAt = 0
end

local function pollInterval()
  local v = tonumber(cfg("poll_interval_ms")) or 2000
  if v < 1000 then
    v = 1000
  elseif v > 60000 then
    v = 60000
  end
  return v
end

-- rc / 情况 -> 错误码 + 是否致命(致命进静默慢探)
local function classify(result)
  if result.spawnFailed or result.exitCode == 127 then
    return "helper-missing", true
  end
  local rc = result.exitCode
  if rc == 3 then
    return "device-missing", true
  elseif rc == 4 then
    return "permission-denied", true
  elseif rc == 5 then
    return "read-failed", false
  elseif rc == 2 then
    return "invalid-args", false
  elseif rc == 1 then
    return "write-failed", false
  end
  return "parse", false
end

-- 失败处理:致命进静默,其余走指数退避
local function applyFailure(code, fatal)
  health.error = code
  if fatal then
    health.silent = true
    health.writable = false
    probeAt = now() + SILENT_PROBE_MS
  else
    health.backoff_n = health.backoff_n + 1
    local delay = math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * (2 ^ (health.backoff_n - 1)))
    health.backoffUntil = now() + delay
    health.writable = (code == "parse" or code == "invalid-args")
  end
end

-- 进入卡死态:只标记,不发下一个,等回调真正回来
local function enterStuck()
  health.ok = false
  health.stuck = true
  health.silent = false
  health.error = "helper-stuck"
  health.writable = false
  probeAt = now() + SILENT_PROBE_MS
end

local function clearHealthy()
  health.ok = true
  health.error = ""
  health.writable = true
  health.backoff_n = 0
  health.backoffUntil = 0
  health.stuck = false
  health.silent = false
end

-- 解析 status JSON,写 actual
local function parseStatus(stdout)
  local ok, decoded = pcall(noctalia.json.decode, stdout)
  if not ok or type(decoded) ~= "table" then
    return false, "parse"
  end
  actual.fan0 = tonumber(decoded.fan0) or -1
  actual.fan1 = tonumber(decoded.fan1) or -1
  actual.temp0 = tonumber(decoded.temp0) or -1
  actual.temp1 = tonumber(decoded.temp1) or -1
  actual.mode_reg = tonumber(decoded.mode) or 0
  actual.minSpeed = tonumber(decoded.minSpeed) or 25
  actual.lastReadAt = now()
  if decoded.ok ~= true then
    return false, "read-failed"
  end
  return true, ""
end

-- 前向声明
local schedulerTick
local engineRecomputeTarget
local publish
local savePersist

-- 一次 Op 的结果处理(在 pcall 内运行)
local function handleResult(op, result)
  local nowMs = now()

  if op.kind == "read" then
    if not result.spawnFailed and result.exitCode == 0 then
      local parsed, code = parseStatus(result.stdout or "")
      if parsed then
        clearHealthy()
        nextReadAt = nowMs + pollInterval()
        engineRecomputeTarget()
        publish()
        return
      end
      -- 能跑通但 ok=false:标记不可用并退避重读,不误判为卡死
      health.ok = false
      applyFailure(code, false)
      publish()
      return
    end
    health.ok = false
    if result.timedOut then
      enterStuck()
    else
      local code, fatal = classify(result)
      applyFailure(code, fatal)
    end
    publish()
    return
  end

  -- write(单风扇);左右两路成对下发,以左路(fan1)完成作为整轮写入完成
  if op.kind == "write" then
    if not result.spawnFailed and result.exitCode == 0 then
      clearHealthy()
      appliedMode = "write"
      if op.fan == 1 then
        appliedRaw = op.raw
        writeStage = nil
        writeRoundRaw = nil
        lastWriteAt = nowMs
        statusEarliestAt = nowMs + POST_WRITE_SETTLE_MS
        nextReadAt = statusEarliestAt
      end
      publish()
      return
    end
    -- 任一路失败都放弃本轮,免得只写到一半
    writeStage = nil
    writeRoundRaw = nil
    if result.timedOut then
      enterStuck()
    else
      local code, fatal = classify(result)
      applyFailure(code, fatal)
    end
    publish()
    return
  end

  -- auto
  if not result.spawnFailed and result.exitCode == 0 then
    clearHealthy()
    appliedMode = MODE_AUTO
    statusEarliestAt = nowMs + POST_WRITE_SETTLE_MS
    nextReadAt = statusEarliestAt
    publish()
    return
  end
  if result.timedOut then
    enterStuck()
  else
    local code, fatal = classify(result)
    applyFailure(code, fatal)
  end
  publish()
end

-- Op 结束统一入口:先处理结果,再无条件复位 inFlight 并推进调度
local function onOpDone(id, result)
  local op = inFlight
  if op and op.id == id then
    pcall(handleResult, op, result)
    pcall(function()
      if inFlight and inFlight.id == id then
        inFlight = nil
      end
    end)
  end
  pcall(schedulerTick)
end

-- 唯一 spawn helper 的地方
local function startOp(kind, raw, timeout, isProbe, fan)
  local path = resolveHelperPath()
  opSeq = opSeq + 1
  local id = opSeq
  if not path then
    handleResult({ kind = kind, raw = raw, fan = fan }, { spawnFailed = true, exitCode = -1 })
    return
  end
  inFlight = { id = id, kind = kind, raw = raw, fan = fan, startedAt = now(), probe = isProbe }
  local argv = buildArgv(path, { kind = kind, raw = raw, fan = fan })
  local started = noctalia.runAsync(argv, function(result)
    pcall(onOpDone, id, result)
  end, timeout)
  if not started then
    handleResult({ kind = kind, raw = raw, fan = fan }, { spawnFailed = true, exitCode = -1 })
    if inFlight and inFlight.id == id then
      inFlight = nil
    end
  end
end

-- 退出时交还 EC,fire-and-forget,短超时
local function schedulerExitHandback()
  local path = resolveHelperPath()
  if not path then
    health.error = "helper-missing"
    return false
  end
  local ok = pcall(noctalia.runAsync, { path, "auto" }, nil, 2000)
  return ok == true
end

-- 调度主循环:看门狗 -> 卡死/静默探测 -> 退避 -> auto -> 写 -> 读
schedulerTick = function()
  local nowMs = now()

  -- 在途:只看看门狗,绝不另起一个
  if inFlight then
    local wd = WATCHDOG_MS[inFlight.kind] or 8000
    if not health.stuck and (nowMs - inFlight.startedAt) > (wd + 2000) then
      enterStuck()
      publish()
    end
    return
  end

  -- 卡死态:只按慢节奏探测,不发任何写
  if health.stuck then
    if nowMs >= probeAt then
      probeAt = nowMs + SILENT_PROBE_MS
      startOp("read", nil, WATCHDOG_MS.read, true)
    end
    return
  end

  -- 静默态(致命错误):只做慢探,不写
  if health.silent then
    if nowMs >= probeAt then
      probeAt = nowMs + SILENT_PROBE_MS
      startOp("read", nil, WATCHDOG_MS.read, false)
    end
    return
  end

  -- 退避期:不重发同一次意图
  if nowMs < health.backoffUntil then
    return
  end

  -- 写:先把待写目标入队(去抖合并),再按「轮」下发左右两路
  if desired.mode == MODE_AUTO then
    pendingWrite = nil
    writeDueAt = nil
    -- 放弃未完成的写轮次:auto 应接管,不再补写另一路
    writeStage = nil
    writeRoundRaw = nil
    if appliedMode ~= MODE_AUTO then
      startOp("auto", nil, WATCHDOG_MS.auto, false)
      return
    end
  else
    local target = desired.targetRaw
    local need = target and health.writable
      and ((appliedRaw == nil) or math.abs(target - appliedRaw) >= RAW_STEP)
    if need then
      pendingWrite = { raw = target }
      if writeDueAt == nil then
        writeDueAt = (nowMs <= userIntentUntil) and nowMs or (nowMs + WRITE_DEBOUNCE_MS)
      end
    else
      -- 已追平或不可写:清掉待写,避免重复下发同值
      pendingWrite = nil
      writeDueAt = nil
    end

    -- 第二轮:补齐另一路风扇
    if writeStage ~= nil then
      local fan = (writeStage == "fan0") and 1 or 0
      startOp("write", writeRoundRaw, WATCHDOG_MS.write, false, fan)
      return
    end

    -- 第一轮:冻结当前目标,先写右路
    if pendingWrite and nowMs >= (writeDueAt or 0)
      and nowMs - lastWriteAt >= EC_WRITE_MIN_INTERVAL_MS then
      writeRoundRaw = pendingWrite.raw
      pendingWrite = nil
      writeDueAt = nil
      lastWriteAt = nowMs
      writeStage = "fan0"
      startOp("write", writeRoundRaw, WATCHDOG_MS.write, false, 0)
      return
    end
  end

  -- 读:按 poll 节奏,且避开刚写完的锁竞争窗口
  if nowMs >= nextReadAt and nowMs >= statusEarliestAt then
    startOp("read", nil, WATCHDOG_MS.read, false)
  end
end

-- ══════════════════════════════════════════════════════════════════════════
-- 5. MODE ENGINE (策略,纯改 desired)
-- ══════════════════════════════════════════════════════════════════════════

local curveTemp = nil -- 上次算曲线用的温度
local safetyNotified = false -- 过热通知节流,温度回落后重置
local sensorNotified = false -- 温度失效通知节流,温度恢复后重置

local function notifySafe(title, body)
  local ok = pcall(noctalia.notify, title, body)
  if not ok then
    pcall(noctalia.notifyError, title, body)
    pcall(noctalia.log, tostring(title) .. " " .. tostring(body or ""))
  end
end

local function curveName()
  local name = desired.curve or cfg("curve") or "balanced"
  if not CURVES[name] then
    name = "balanced"
  end
  return name
end

-- 传感器温度;无效时返回非正值
local function sensorTemp()
  local t0 = tonumber(actual.temp0) or -1
  local t1 = tonumber(actual.temp1) or -1
  if desired.sensor == "max" then
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

-- 温度 -> raw 分段线性插值,叠加 min_fan_percent 下限
local function curveRaw(temp)
  local points = CURVES[curveName()]
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

-- 手动档初值:历史值 -> 当前实测 -> 中档
local function manualSeedRaw()
  if desired.raw and desired.raw > 0 then
    return desired.raw
  end
  local measured = math.max(tonumber(actual.fan0) or -1, tonumber(actual.fan1) or -1)
  if measured > 0 then
    return math.min(RAW_MAX, measured)
  end
  return math.floor(RAW_MAX / 2)
end

-- 重算当前模式的生效目标(写 desired.targetRaw,不发 EC 写)
engineRecomputeTarget = function()
  if desired.mode == MODE_MANUAL then
    desired.targetRaw = normalizeRaw(desired.raw)
  elseif desired.mode == MODE_CURVE then
    local temp = sensorTemp()
    if tempValid(temp) and (curveTemp == nil or math.abs(temp - curveTemp) >= TEMP_REAPPLY_DELTA_C) then
      curveTemp = temp
      desired.targetRaw = normalizeRaw(curveRaw(temp))
    end
  else
    desired.targetRaw = nil
  end
end

-- 曲线模式下温度失效或过热时乐观交还 auto;manual 不强制交还
local function engineSafety()
  local safety = desired.safety_c
  local temp = sensorTemp()

  -- 尚未成功读过之前不知道温度,不做无效判定,免得启动即误交还
  if actual.lastReadAt > 0 and not tempValid(temp) then
    -- 温度通道失效:curve 交还 auto;manual 保持(用户显式设定),仅告警
    if desired.mode == MODE_CURVE then
      if not sensorNotified then
        sensorNotified = true
        notifySafe(noctalia.tr("notify.sensor.title"), noctalia.tr("notify.sensor.body"))
      end
      desired.mode = MODE_AUTO
      desired.targetRaw = nil
      curveTemp = nil
      savePersist()
    end
    return
  end

  sensorNotified = false
  if desired.mode ~= MODE_AUTO and temp >= safety then
    if not safetyNotified then
      safetyNotified = true
      notifySafe(
        noctalia.tr("notify.safety.title"),
        noctalia.tr("notify.safety.body", { temp = tostring(temp) })
      )
    end
    desired.mode = MODE_AUTO
    desired.targetRaw = nil
    curveTemp = nil
    savePersist()
  elseif temp < safety - 5 then
    safetyNotified = false
  end
end

local function engineEnterMode(mode, raw)
  if mode == MODE_AUTO then
    desired.mode = MODE_AUTO
    desired.targetRaw = nil
    curveTemp = nil
  elseif mode == MODE_MANUAL then
    desired.mode = MODE_MANUAL
    if raw ~= nil then
      local v = math.floor((tonumber(raw) or 0) + 0.5)
      desired.raw = math.max(0, math.min(RAW_MAX, v))
    else
      desired.raw = manualSeedRaw()
    end
    desired.targetRaw = normalizeRaw(desired.raw)
    schedulerMarkUserIntent()
  elseif mode == MODE_CURVE then
    if not tempValid(sensorTemp()) then
      engineEnterMode(MODE_AUTO)
      return
    end
    desired.mode = MODE_CURVE
    curveTemp = nil
    desired.targetRaw = normalizeRaw(curveRaw(sensorTemp()))
  end
  savePersist()
  publish()
end

local function engineSetCurve(name)
  desired.curve = name
  curveTemp = nil
  schedulerMarkUserIntent()
  if desired.mode == MODE_CURVE then
    engineRecomputeTarget()
  end
  savePersist()
  publish()
end

local function engineCycle()
  if desired.mode == MODE_AUTO then
    engineEnterMode(MODE_CURVE)
  elseif desired.mode == MODE_CURVE then
    engineEnterMode(MODE_MANUAL)
  else
    engineEnterMode(MODE_AUTO)
  end
end

-- 命令分发(只接受 table 形式)
local function engineHandleCommand(cmd)
  if type(cmd) ~= "table" then
    return
  end
  if cmd.action == "set_mode" and type(cmd.mode) == "string" then
    engineEnterMode(cmd.mode, cmd.raw)
  elseif cmd.action == "set_raw" then
    local v = math.max(0, math.min(RAW_MAX, tonumber(cmd.raw) or 0))
    engineEnterMode(MODE_MANUAL, v)
  elseif cmd.action == "set_curve" and type(cmd.name) == "string" then
    if CURVES[cmd.name] then
      engineSetCurve(cmd.name)
    end
  elseif cmd.action == "cycle_mode" then
    engineCycle()
  elseif cmd.action == "refresh" then
    schedulerRequestRead()
  end
end

-- ══════════════════════════════════════════════════════════════════════════
-- 6. PUBLISH / UI BRIDGE
-- ══════════════════════════════════════════════════════════════════════════

local lastSig = nil

-- 组装并发布快照;签名未变则跳过
publish = function()
  local outRaw
  if desired.mode == MODE_MANUAL then
    outRaw = desired.raw -- 展示用户值,归一化只发生在传输层
  else
    outRaw = desired.targetRaw or 0
  end
  local snapshot = {
    ok = health.ok,
    fan0 = actual.fan0,
    fan1 = actual.fan1,
    temp0 = actual.temp0,
    temp1 = actual.temp1,
    mode = actual.mode_reg,
    minSpeed = actual.minSpeed,
    scale = RAW_MAX,
    modeName = desired.mode,
    targetRaw = outRaw,
    appliedRaw = appliedRaw or 0,
    curve = curveName(),
    sensor = desired.sensor,
    safetyTempC = desired.safety_c,
    error = errText(health.error),
    live = desired.mode ~= MODE_AUTO,
    writable = health.writable,
  }
  local sig = table.concat({
    tostring(snapshot.ok),
    tostring(snapshot.fan0),
    tostring(snapshot.fan1),
    tostring(snapshot.temp0),
    tostring(snapshot.temp1),
    tostring(snapshot.mode),
    tostring(snapshot.modeName),
    tostring(snapshot.targetRaw),
    tostring(snapshot.appliedRaw),
    tostring(snapshot.curve),
    tostring(snapshot.sensor),
    tostring(snapshot.safetyTempC),
    tostring(snapshot.error),
    tostring(snapshot.live),
    tostring(snapshot.writable),
  }, "|")
  if sig == lastSig then
    return
  end
  lastSig = sig
  pcall(noctalia.state.set, SNAPSHOT, snapshot)
end

-- ══════════════════════════════════════════════════════════════════════════
-- 7. LIFECYCLE
-- ══════════════════════════════════════════════════════════════════════════

local function stateFilePath()
  local dir = noctalia.pluginDataDir()
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  return dir .. "/state.json"
end

-- 读取持久化意图;缺失或损坏回退默认
local function loadPersist()
  local path = stateFilePath()
  if not path then
    return {}
  end
  local ok, contents = pcall(noctalia.readFile, path)
  if not ok or type(contents) ~= "string" or contents == "" then
    return {}
  end
  local ok2, decoded = pcall(noctalia.json.decode, contents)
  if not ok2 or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

-- 写持久化意图(模式/曲线/手动值)
savePersist = function()
  local path = stateFilePath()
  if not path then
    return
  end
  local ok, encoded = pcall(noctalia.json.encode, {
    mode = desired.mode,
    raw = desired.raw,
    curve = desired.curve,
  }, true)
  if not ok or type(encoded) ~= "string" then
    return
  end
  pcall(noctalia.writeFile, path, encoded)
end

function update()
  engineSafety()
  engineRecomputeTarget()
  schedulerTick()
  publish()
end

function onConfigChanged()
  desired.sensor = cfg("sensor") or "cpu"
  desired.safety_c = tonumber(cfg("safety_temp_c")) or 95
  noctalia.setUpdateInterval(SCHED_TICK_MS)
  publish()
end

function onEnable()
  local saved = loadPersist()
  desired.sensor = cfg("sensor") or "cpu"
  desired.safety_c = tonumber(cfg("safety_temp_c")) or 95
  if type(saved.curve) == "string" and CURVES[saved.curve] then
    desired.curve = saved.curve
  end
  if tonumber(saved.raw) then
    desired.raw = math.max(0, math.min(RAW_MAX, math.floor(tonumber(saved.raw) + 0.5)))
  end
  -- 启动默认 auto,不夺权
  desired.mode = MODE_AUTO
  desired.targetRaw = nil
  appliedMode = MODE_AUTO
  noctalia.setUpdateInterval(SCHED_TICK_MS)
  publish()
  schedulerRequestRead()
  schedulerTick()
end

function onExit(_signal, reason)
  -- 重载不交还,免得热重载抢走 EC 控制
  if reason == "reload" then
    return
  end
  if desired.mode ~= MODE_AUTO or appliedMode ~= MODE_AUTO then
    desired.mode = MODE_AUTO
    desired.targetRaw = nil
    savePersist()
    local ok = schedulerExitHandback()
    if not ok then
      health.error = "helper-missing"
    end
    publish()
    pcall(noctalia.log, "[mechrevo-fan] onExit handback, helper ok=" .. tostring(ok))
  end
end

noctalia.state.watch(COMMAND, function(cmd)
  pcall(engineHandleCommand, cmd)
end)

onEnable()
