--!nonstrict
-- 控制面板:模式切换(自动/曲线/手动)、曲线选择、手动滑块、状态卡片。

local SNAPSHOT = "mechrevo_fan.status"
local COMMAND = "mechrevo_fan.command"

local snap = noctalia.state.get(SNAPSHOT) or {
  ok = false,
  fan0 = -1,
  fan1 = -1,
  temp0 = -1,
  temp1 = -1,
  modeName = "auto",
  curve = "balanced",
  sensor = "cpu",
  live = false,
  error = "",
  writable = true,
}

local MODE_AUTO = "auto"
local MODE_MANUAL = "manual"
local MODE_CURVE = "curve"

local CURVE_NAMES = { "quiet", "balanced", "performance" }
-- 滑块预览值:拖拽中以及松手后等待服务确认期间使用,避免回弹到旧值
local sliderPreview = nil
local render -- 前向声明:各控件的回调在 render 定义前引用它

local function send(payload)
  noctalia.state.set(COMMAND, payload)
end

-- helper 可用且后端可写时才放行控件
local function controlsEnabled()
  return snap.ok == true and snap.writable ~= false
end

local function dutyPercent(raw)
  local scale = tonumber(snap.scale) or 200
  if raw == nil or raw < 0 then
    return 0
  end
  return math.floor(raw * 100 / scale + 0.5)
end

local function modeLabel(mode)
  if mode == MODE_AUTO then return noctalia.tr("widget.mode.auto") end
  if mode == MODE_CURVE then return noctalia.tr("widget.mode.curve") end
  return noctalia.tr("widget.mode.manual")
end

local function modeButton(mode)
  local active = (snap.modeName or MODE_AUTO) == mode
  return ui.button({
    key = "mode-" .. mode,
    text = modeLabel(mode),
    variant = active and "primary" or "outline",
    flexGrow = 1,
    enabled = controlsEnabled(),
    onClick = function()
      sliderPreview = nil
      send({ action = "set_mode", mode = mode })
    end,
  })
end

local function curveButton(name)
  local active = (snap.curve or "balanced") == name
  return ui.button({
    key = "curve-" .. name,
    text = noctalia.tr("curve." .. name),
    variant = active and "primary" or "ghost",
    flexGrow = 1,
    enabled = controlsEnabled() and (snap.modeName or MODE_AUTO) == MODE_CURVE,
    onClick = function()
      send({ action = "set_curve", name = name })
    end,
  })
end

local function statCard(label, value)
  return ui.row({
    fill = "secondary/0.12",
    radius = 6,
    paddingH = 8,
    paddingV = 5,
    gap = 4,
    flexGrow = 1,
    justify = "center",
  }, {
    ui.label({ text = label .. " ", fontSize = 12, color = "on_surface_variant" }),
    ui.label({ text = value, fontSize = 12, fontWeight = "bold", color = "primary" }),
  })
end

local function statusSection()
  local t0 = tonumber(snap.temp0) or -1
  local t1 = tonumber(snap.temp1) or -1
  local tempText = t0 > 0 and (tostring(t0) .. "°C") or (t1 > 0 and (tostring(t1) .. "°C") or "--")
  return ui.column({ gap = 6 }, {
    ui.label({ text = noctalia.tr("panel.status"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
    ui.row({ gap = 8 }, {
      statCard(noctalia.tr("panel.fan_left"), tostring(dutyPercent(snap.fan1)) .. "%"),
      statCard(noctalia.tr("panel.fan_right"), tostring(dutyPercent(snap.fan0)) .. "%"),
      statCard(noctalia.tr("panel.temp"), tempText),
    }),
    snap.live and ui.label({
      text = noctalia.tr("panel.live_hint"),
      fontSize = 10,
      color = "on_surface_variant",
    }) or ui.box({}),
    -- helper 卡住或不可写时的只读状态行
    (snap.writable == false) and ui.label({
      text = tostring(snap.error or ""),
      fontSize = 10,
      color = "error",
      maxLines = 2,
    }) or ui.box({}),
  })
end

local function manualSection()
  local scale = tonumber(snap.scale) or 200
  local shown = sliderPreview
  if shown == nil then
    shown = tonumber(snap.targetRaw) or 0
  end
  local enabled = (snap.modeName or MODE_AUTO) == MODE_MANUAL and controlsEnabled()
  return ui.column({ key = "manual", gap = 6 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("panel.manual_speed"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      ui.label({
        text = tostring(math.floor(shown * 100 / scale + 0.5)) .. "%",
        fontWeight = "bold",
        color = "primary",
      }),
    }),
    ui.slider({
      key = "manual-slider",
      min = 0,
      max = scale,
      step = 5,
      value = shown,
      enabled = enabled,
      onChange = function(v)
        sliderPreview = tonumber(v) or shown
        render()
      end,
      onDragEnd = function(v)
        -- 保留预览值直到服务确认(targetRaw 追上),否则快照回传旧值会让滑块回弹
        local target = sliderPreview or tonumber(v) or shown
        sliderPreview = target
        send({ action = "set_raw", raw = target })
      end,
    }),
    ui.label({
      text = noctalia.tr("panel.manual_hint"),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 3,
    }),
  })
end

render = function()
  panel.render(ui.column({ flexGrow = 1, gap = 12, padding = 12 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ align = "center", gap = 6 }, {
        ui.glyph({ name = "car-fan", color = "primary", size = 18 }),
        ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold" }),
      }),
      ui.button({ glyph = "close", variant = "ghost", onClick = function() panel.close() end }),
    }),

    statusSection(),

    ui.column({ gap = 6 }, {
      ui.label({ text = noctalia.tr("panel.mode"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      ui.row({ gap = 6 }, {
        modeButton(MODE_AUTO),
        modeButton(MODE_CURVE),
        modeButton(MODE_MANUAL),
      }),
    }),

    ui.column({ gap = 6 }, {
      ui.label({ text = noctalia.tr("panel.curve"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
      ui.row({ gap = 6 }, {
        curveButton("quiet"),
        curveButton("balanced"),
        curveButton("performance"),
      }),
    }),

    manualSection(),
  }))
end

noctalia.state.watch(SNAPSHOT, function(val)
  if type(val) == "table" then
    snap = val
    -- 服务端已确认写入目标值,预览使命完成,交还给快照驱动
    if sliderPreview ~= nil and tonumber(snap.targetRaw) == sliderPreview then
      sliderPreview = nil
    end
    render()
  end
end)

function update()
  render()
end

function onOpen(_context)
  snap = noctalia.state.get(SNAPSHOT) or snap
  noctalia.state.set(COMMAND, { action = "refresh" })
  render()
end

render()
