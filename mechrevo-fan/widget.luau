--!nonstrict
-- 状态栏风扇部件:显示当前风扇占空比与温度,点击循环模式,右键开控制面板。

local SNAPSHOT = "mechrevo_fan.status"
local COMMAND = "mechrevo_fan.command"

local snap = noctalia.state.get(SNAPSHOT) or {
  ok = false,
  fan0 = -1,
  fan1 = -1,
  temp0 = -1,
  temp1 = -1,
  modeName = "auto",
  live = false,
  error = "",
}

local function dutyPercent(raw)
  local scale = tonumber(snap.scale) or 200
  if raw == nil or raw < 0 then
    return 0
  end
  return math.floor(raw * 100 / scale + 0.5)
end

local function displayFan()
  -- 取两个风扇中较大的占空比(手动模式下两路同值;自动模式下代表当前主导风扇)
  local f0 = tonumber(snap.fan0) or -1
  local f1 = tonumber(snap.fan1) or -1
  if f0 < 0 then
    return f1
  end
  if f1 < 0 then
    return f0
  end
  return math.max(f0, f1)
end

local function displayText()
  if not snap.ok then
    return "--"
  end
  local mainRaw = displayFan()
  local temp = math.max(tonumber(snap.temp0) or -1, tonumber(snap.temp1) or -1)
  local duty = dutyPercent(mainRaw)
  if temp > 0 then
    return tostring(duty) .. "%  " .. tostring(temp) .. "°"
  end
  return tostring(duty) .. "%"
end

local function modeLabel()
  local m = snap.modeName or "auto"
  if m == "auto" then
    return noctalia.tr("widget.mode.auto")
  elseif m == "curve" then
    return noctalia.tr("widget.mode.curve")
  end
  return noctalia.tr("widget.mode.manual")
end

local function tooltipRows()
  local f0 = tonumber(snap.fan0) or -1
  local f1 = tonumber(snap.fan1) or -1
  local rows = {
    { key = noctalia.tr("widget.tooltip.fan_right"), value = tostring(dutyPercent(f0)) .. "%" },
    {
      key = noctalia.tr("widget.tooltip.fan_left"),
      -- f1 < 0 才是读取失败;能读到数值就显示占空比(低速/停转时显示 0%)
      value = (f1 >= 0) and (tostring(dutyPercent(f1)) .. "%") or noctalia.tr("widget.left_unavailable"),
    },
    { key = noctalia.tr("widget.tooltip.mode"), value = modeLabel() .. (snap.live and " *" or "") },
  }
  local t0 = tonumber(snap.temp0) or -1
  if t0 > 0 then
    table.insert(rows, { key = noctalia.tr("widget.tooltip.temp"), value = tostring(t0) .. "°C" })
  end
  if not snap.ok then
    table.insert(rows, { key = noctalia.tr("widget.tooltip.error"), value = snap.error or "?" })
  end
  return rows
end

local function render()
  if not snap.ok then
    barWidget.setGlyph("propeller-off")
  elseif snap.modeName ~= "auto" then
    barWidget.setGlyph("car-fan-2")
  else
    barWidget.setGlyph("car-fan")
  end
  barWidget.setText(displayText())
  barWidget.setTooltip(tooltipRows())
  if snap.modeName == "auto" or not snap.ok then
    barWidget.setGlyphColor("on_surface")
  else
    barWidget.setGlyphColor("primary")
  end
end

noctalia.state.watch(SNAPSHOT, function(val)
  if type(val) == "table" then
    snap = val
    render()
  end
end)

function update()
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.state.set(COMMAND, { action = "cycle_mode" })
end

function onRightClick()
  noctalia.togglePanel("7yunluo/mechrevo-fan:control")
end

noctalia.setUpdateInterval(2000)
render()
