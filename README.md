# noctalia-mechrevo-fan · 重构版

机械革命 WUJIE 笔记本的 Noctalia v5 风扇控制插件，通过 `mechrevo-fanctl` 和
`/dev/tuxedo_io` 读取风扇状态、设置双风扇占空比，以及交还 EC 自动控制。

**当前仓库为重构版本。** 后台服务改为串行执行硬件操作，统一处理模式切换、目标下发、
读回验证和异常恢复；状态栏和面板同步更新，区分“正在下发”和“已验证生效”。

适配与实测机型为 **WUJIE Series-X5SP4NAG / Ryzen AI 9 H 365**。其他机械革命或
Uniwill 机型的 EC 行为可能不同，驱动中的共享风扇表适配只针对上述主板型号。

## 重构内容

- **串行调度**：读取、双路写入和恢复自动控制逐个执行；操作进行中合并新的目标，避免并发调用 helper。
- **双风扇读回验证**：新增 `set-both`，在同一 helper 进程和设备锁内依次写入两路，再输出状态。服务按读回占空比判断是否生效。
- **持续维持目标**：手动和曲线模式每秒重施目标，即使目标未变化也会继续下发，以应对 EC 固件覆盖。
- **故障恢复**：温度无效、读数超过 15 秒未更新、达到保护温度或连续三次双路读回不匹配时，请求恢复自动控制；写入失败也会触发交还。
- **界面反馈**：面板显示等待验证、生效和错误提示；滑块拖动期间保留预览，命令带唯一标识。
- **启动与退出交还**：每次启动先执行 `auto`；退出时启动独立进程尝试交还 EC。只保存手动目标与曲线选择，重启插件后从自动模式开始。
- **回归测试**：用模拟 Noctalia 宿主测试真实服务代码，覆盖调度、曲线、读回验证和保护逻辑。

## 功能

| 模式 | 行为 |
| --- | --- |
| 自动 | 由 EC 固件控制风扇，插件定期读取状态 |
| 曲线 | 按温度线性插值，提供安静、均衡、性能三条曲线 |
| 手动 | 用滑块设置两路相同的目标占空比 |

状态栏显示两路风扇中较高的占空比及温度，左键按 **自动 → 曲线 → 手动** 循环切换，
右键打开控制面板。面板分别显示左右风扇读数，并提供模式、曲线和手动滑块。

百分比是风扇占空比，原始值范围为 `0–200`，`200` 对应 `100%`；读数不是 RPM。

## 安装

### 环境要求

- Linux，以及提供 `/dev/tuxedo_io` 的 `mechrevo-drivers` / `tuxedo-drivers`。
- Noctalia v5，支持插件 API 24。
- `gcc`、`udev`、`sudo`；应用驱动补丁还需要 Python 3、DKMS 和对应内核头文件。
- 当前用户有权读写 `/dev/tuxedo_io`；仓库提供的 udev 规则使用 `plugdev` 组。

参考硬件环境为上述 WUJIE 机型、驱动 `4.22.3`、内核 `7.2.8-zen`。

### 1. 安装 helper 和设备权限规则

```sh
git clone https://github.com/7yunluo/noctalia-mechrevo-fan.git
cd noctalia-mechrevo-fan
./install.sh
```

脚本将 helper 编译安装到 `~/.local/bin/mechrevo-fanctl`，安装 udev 规则，然后执行
一次状态探测。以普通用户运行脚本，安装系统规则时脚本会调用 `sudo`。

如果提示权限不足，确认系统存在 `plugdev` 组，并将当前用户加入该组：

```sh
sudo usermod -aG plugdev "$USER"
```

重新登录后检查设备权限，再运行 `~/.local/bin/mechrevo-fanctl status`。

### 2. 接入 Noctalia

在仓库目录执行：

```sh
noctalia msg plugins source add mechrevo path "$PWD"
noctalia msg plugins enable 7yunluo/mechrevo-fan
```

然后在 Noctalia 状态栏配置中添加插件的 `fan` 部件。插件源引用本地仓库路径，
请保留该目录；如果曾用其他路径添加同名源，先移除旧源再添加。

### 3. WUJIE 驱动补丁

`scripts/apply-driver-patch.py` 为驱动源码应用以下修复：

- 让重复启用全风扇模式保持幂等，避免意外清除模式位。
- 初始化完成后提前返回，避免稳态写入重复初始化。
- 识别 `WUJIE Series-X5SP4NAG`，调整初始化，并在共享表路径中让 fan1 使用 CPU 风扇表。
- 为旧控制路径的自动模式写入增加回读重试，驱动卸载时交还 EC。

脚本默认选择 `/usr/src/mechrevo-drivers-*/uniwill_keyboard.h` 中版本最高的源码，
也支持显式指定文件。它会保留首次修改前的 `.orig` 备份，支持重复执行，
锚点缺失或不唯一时退出，不写入部分补丁。

以驱动 `4.22.3` 和当前内核为例；请将版本变量改成实际安装的驱动版本：

```sh
DRIVER_VERSION=4.22.3
sudo python3 scripts/apply-driver-patch.py "/usr/src/mechrevo-drivers-${DRIVER_VERSION}/uniwill_keyboard.h"
sudo dkms remove "mechrevo-drivers/${DRIVER_VERSION}" --all
sudo dkms install "mechrevo-drivers/${DRIVER_VERSION}" -k "$(uname -r)"
```

完成后重启，使新驱动生效。`--all` 会移除该驱动版本在所有内核上的 DKMS 安装，
上面的安装命令只为当前内核重建；需要使用其他内核时，也要为其安装。
驱动包升级可能覆盖 `/usr/src` 中的修改，升级后需重新应用补丁并重建。

## 从旧版迁移

更新仓库后，重新运行 `./install.sh` 安装带 `set-both` 和设备锁的新 helper，
再重新加载或重新启用 Noctalia 插件。服务和 helper 应一起更新。

重构版不恢复上次的手动或曲线模式；启动后先交还 EC，再由用户选择控制模式。
手动目标占空比和曲线选择仍会保存。

旧补丁曾通过 `oldctl` 将 WUJIE 加入旧风扇控制路径的例外表。当前脚本已移除这条补丁，
**但不会自动撤销已经应用的 `oldctl` 修改**。如果使用过该补丁，请从干净的同版本
驱动源码重新应用当前补丁，再重建 DKMS，避免保留旧路径配置。

## 设置

| 设置 | 默认值 | 说明 |
| --- | --- | --- |
| `poll_interval_ms` | `2000` | 自动模式状态轮询间隔，可设为 1000–10000 ms；手动和曲线模式每秒写入并读回 |
| `sensor` | `cpu` | 使用 CPU 温度，或两路温度中的最大值 `max` |
| `curve` | `balanced` | 默认曲线：`quiet` / `balanced` / `performance` |
| `min_fan_percent` | `0` | 曲线模式的目标下限，范围 0–60%；仍受 EC 最低档行为影响 |
| `safety_temp_c` | `95` | 保护温度，范围 70–105°C |
| `helper_path` | `~/.local/bin/mechrevo-fanctl` | helper 可执行文件路径 |

保护逻辑会请求恢复 EC 自动控制并显示原因。设备无响应或驱动调用阻塞时，
实际交还仍取决于 helper 和驱动能否完成操作；服务等待当前操作返回，避免叠加调用。

## 命令行

如果 `~/.local/bin` 已在 `PATH` 中，可以直接运行：

```sh
mechrevo-fanctl status         # 输出 JSON 状态
mechrevo-fanctl set-both 120   # 两路目标均设为 60%，写入后输出 JSON 状态
mechrevo-fanctl set 0 120      # 设置右风扇（fan0）
mechrevo-fanctl set 1 120      # 设置左风扇（fan1）
mechrevo-fanctl auto           # 交还 EC 自动控制
```

`set-both` 在同一设备锁内依次写入两路；写入或随后状态读取失败时，会尝试交还 EC。
设备锁用于协调 helper 进程，其他直接访问 EC 的工具仍可能覆盖目标。
CLI 的 `set` / `set-both` 是一次性操作，每秒维持目标和温度保护由插件服务提供。

退出码：`0` 成功，`1` 设备或写入错误，`2` 参数错误，`3` 设备不存在，
`4` 权限不足，`5` 关键状态读取失败，`6` 另一个 helper 操作正在执行。

## 硬件限制与排障

- **低占空比不等于停转**：在实测机型上，EC 会调整低于约 25% 的请求值，
  `0` 目标也可能在一段时间后被抬到最低档。插件保留用户目标，但实际占空比以读回为准。
- **第二路温度不可用**：实测 `temp0` 返回 CPU 侧温度，`temp1` 恒为 `0`。
  第二路温度或最低转速字段读取失败不会单独使 helper 的整体状态失败。
- **左风扇不跟随**：检查驱动补丁及 DKMS 是否生效，特别是共享 CPU 表适配和旧 `oldctl` 修改。
  服务不会仅凭 ioctl 成功就宣告控制生效，连续三次读回不匹配后会请求自动模式。
- **部件显示 `--`**：用 `noctalia msg plugins list` 检查插件，再运行
  `~/.local/bin/mechrevo-fanctl status`，在面板查看具体错误。
- **`Permission denied`**：检查设备属组、udev 规则和当前登录会话的 `plugdev` 组成员资格。
- **操作繁忙或目标被覆盖**：检查是否有其他 helper、tccd 或风扇管理工具同时访问设备。

需要定位内核侧 EC 写入来源时，可使用 ftrace 脚本：

```sh
sudo scripts/trace-fan-writers.sh start
# 复现问题
sudo scripts/trace-fan-writers.sh dump
sudo scripts/trace-fan-writers.sh stop
```

`dump` 保存到 `/var/log/fan-trace.log` 并预览，记录中包含进程名、PID 和写入参数，
用于定位异常转速的写入者。

## 开发与验证

无需硬件即可运行服务回归测试（Lua 5.2 或更新版本）：

```sh
lua tests/service_test.lua
gcc -Wall -Wextra -Werror -fsyntax-only helper/mechrevo-fanctl.c
bash -n install.sh scripts/trace-fan-writers.sh
```

服务测试通过模拟时间、硬件返回值和异步回调验证调度与保护逻辑。
实际 EC 响应、驱动补丁和 Noctalia 界面仍需在目标机器上验证。

## 仓库结构

```text
.
├── helper/mechrevo-fanctl.c        # ioctl helper、设备锁、双路写入与状态输出
├── mechrevo-fan/
│   ├── plugin.toml                # 插件清单与设置
│   ├── service.luau               # 串行调度、曲线、读回验证与保护
│   ├── widget.luau                # 状态栏部件
│   ├── panel.luau                 # 控制面板
│   └── translations/              # 简体中文与英文
├── scripts/
│   ├── apply-driver-patch.py       # WUJIE 驱动补丁
│   └── trace-fan-writers.sh        # EC 写入来源取证
├── tests/service_test.lua         # 模拟宿主下的服务回归测试
├── udev/60-mechrevo-fanctl.rules   # plugdev 设备权限规则
└── install.sh                    # helper 与 udev 安装
```
