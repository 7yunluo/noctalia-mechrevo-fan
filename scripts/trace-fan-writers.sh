#!/usr/bin/env bash
# 抓内核侧风扇 EC 写的 ftrace kprobe 取证脚本。
# 覆盖 tuxedo_keyboard 模块的 uw_set_fan / uw_set_fan_auto / set_full_fan_mode /
# direct_fan_control / uw_init_fan,start/stop/dump 需 root。
set -euo pipefail

TRACE_DIR=/sys/kernel/tracing
KPROBE_EVENTS="$TRACE_DIR/kprobe_events"
KALLSYMS=/proc/kallsyms
DEFAULT_OUT=/var/log/fan-trace.log
GREP_PATTERN='fan_uw_set|fan_uw_auto|fan_full_mode|fan_direct|fan_init'

# 探针定义:名称 符号 kprobe 参数
PROBE_NAMES=(fan_uw_set fan_uw_auto fan_full_mode fan_direct fan_init)
PROBE_SYMS=(uw_set_fan uw_set_fan_auto set_full_fan_mode direct_fan_control uw_init_fan)
PROBE_SPECS=('idx=%di:u32 speed=%si:u32' '' 'enable=%di:u32' 'fan=%di:u32 speed=%si:u32 prevent=%dx:u32' '')

usage() {
  cat >&2 <<EOF
用法:$0 <start|stop|status|dump [输出文件]>
  start   注册 kprobe 并开始抓取(需 root)
  stop    停止抓取(需 root)
  status  显示 tracing_on 与已抓事件数
  dump    保存 trace 到文件(默认 $DEFAULT_OUT)并预览风扇事件(需 root)
EOF
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "需要 root 权限运行" >&2
    exit 1
  fi
}

do_start() {
  need_root
  # 清场:先关探针开关,再清空已注册探针
  echo 0 > "$TRACE_DIR/events/kprobes/enable" 2>/dev/null || true
  : > "$KPROBE_EVENTS" 2>/dev/null || true

  local registered=() i name sym spec line
  for i in "${!PROBE_NAMES[@]}"; do
    name=${PROBE_NAMES[$i]}
    sym=${PROBE_SYMS[$i]}
    spec=${PROBE_SPECS[$i]}
    if ! grep -qw "$sym" "$KALLSYMS" 2>/dev/null; then
      echo "跳过 $name:符号 $sym 不在 kallsyms" >&2
      continue
    fi
    if [[ -n $spec ]]; then
      line="p:$name $sym $spec"
    else
      line="p:$name $sym"
    fi
    if echo "$line" >> "$KPROBE_EVENTS" 2>/dev/null; then
      registered+=("$name")
    else
      echo "跳过 $name:注册失败(符号缺失或 constprop 变体)" >&2
    fi
  done

  if [[ ${#registered[@]} -eq 0 ]]; then
    echo "错误:没有任何探针注册成功" >&2
    exit 1
  fi

  echo 16384 > "$TRACE_DIR/buffer_size_kb" 2>/dev/null || true
  echo 1 > "$TRACE_DIR/events/kprobes/enable" 2>/dev/null || true
  echo 1 > "$TRACE_DIR/tracing_on" 2>/dev/null || true

  echo "已注册探针:${registered[*]}"
}

do_stop() {
  echo 0 > "$TRACE_DIR/tracing_on" 2>/dev/null || true
  echo 0 > "$TRACE_DIR/events/kprobes/enable" 2>/dev/null || true
  echo "已停止抓取"
}

do_status() {
  local on='未知' lines=0
  if [[ -r "$TRACE_DIR/tracing_on" ]]; then
    on=$(cat "$TRACE_DIR/tracing_on" 2>/dev/null || echo '未知')
  fi
  echo "tracing_on = $on"
  if [[ -r "$TRACE_DIR/trace" ]]; then
    lines=$(grep -Ec "$GREP_PATTERN" "$TRACE_DIR/trace" 2>/dev/null || true)
  fi
  echo "trace 中匹配事件行数:${lines:-0}"
}

do_dump() {
  local out=${1:-$DEFAULT_OUT}
  need_root
  cat "$TRACE_DIR/trace" > "$out"
  echo "已保存 trace 到 $out"
  echo "--- 风扇事件预览(前 50 行)---"
  grep -E "$GREP_PATTERN" "$out" | head -50 || true
}

case ${1:-} in
  start) do_start ;;
  stop) do_stop ;;
  status) do_status ;;
  dump) do_dump "${2:-}" ;;
  *)
    usage
    exit 2
    ;;
esac
