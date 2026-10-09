#!/usr/bin/env bash
# 部署 mechrevo-fanctl + udev 规则,并提示 Noctalia 接入步骤。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"

echo "==> 编译 mechrevo-fanctl"
gcc -O2 -o "$BIN_DIR/.mechrevo-fanctl.tmp" "$ROOT/helper/mechrevo-fanctl.c"
mkdir -p "$BIN_DIR"
install -m755 "$BIN_DIR/.mechrevo-fanctl.tmp" "$BIN_DIR/mechrevo-fanctl"
rm -f "$BIN_DIR/.mechrevo-fanctl.tmp"
echo "    -> $BIN_DIR/mechrevo-fanctl"

echo "==> 安装 udev 规则(需要 sudo)"
sudo install -m644 "$ROOT/udev/60-mechrevo-fanctl.rules" /etc/udev/rules.d/60-mechrevo-fanctl.rules
sudo udevadm control --reload
sudo udevadm trigger --action=change --sysname-match=tuxedo_io || true
ls -l /dev/tuxedo_io

echo "==> 验证 helper"
if "$BIN_DIR/mechrevo-fanctl" status; then
  echo "    helper 可用 ✅"
else
  echo "    helper 不可用,请检查 /dev/tuxedo_io 权限 ❌"
fi

cat <<EOF

==> Noctalia 接入
  noctalia msg plugins source add mechrevo path $ROOT
  noctalia msg plugins enable 7yunluo/mechrevo-fan

(若之前用 /tmp 路径或其它位置添加过插件源,先移除同名旧源再添加)

==> 可选:恢复左风扇直控(驱动补丁 + dkms 重装,需重启生效)
  sudo python3 $ROOT/scripts/apply-driver-patch.py
  VER=\$(ls /usr/src | sed -n 's/^mechrevo-drivers-//p' | head -1)
  sudo dkms remove mechrevo-drivers/\$VER --all
  sudo dkms install mechrevo-drivers/\$VER -k \$(uname -r)
EOF
