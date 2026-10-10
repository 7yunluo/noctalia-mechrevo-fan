# noctalia-mechrevo-fan

Noctalia v5 状态栏风扇插件 + Uniwill EC 风扇控制 helper,用于机械革命 WUJIE 系列的
双风扇机器(本机:WUJIE Series-X5SP4NAG,Ryzen AI 9 H 365)。

- 状态栏部件:显示 `占空比% 温度°`;点击循环切换 自动 → 曲线 → 手动;右键开控制面板
- 控制面板:模式切换 / 曲线选择(安静·均衡·性能)/ 手动滑块 / 硬件状态卡片
- 过热保护:温度达到阈值(默认 95°C)自动交还 EC,并发通知
- 后台服务:周期轮询风扇状态,manual/curve 模式下周期重施目标值,插件退出时交还 EC

## 实测记录(2026-10-09,驱动 4.22.3 + 内核 7.2.8-zen)

在**未打驱动补丁**的官方 4.22.3 上直接测试 ioctl 写入:

| 操作 | 结果 |
|---|---|
| `W_UW_FANSPEED`(fan0→0x1804)写 200/120/40 | 占空比随写入变化,**有效** |
| `W_UW_FANSPEED2`(fan1→0x1809)写 150/200 | `fan1` 读数不变,**无效** |
| `W_UW_FANAUTO` | 恢复自动模式,两风扇重新受 EC 控制,**有效** |

当时据此得出「只有 fan0 能直控、fan1 写入无效」的结论。后续逐行核对内核源码发现,
上表这几次 fan1 写入是在全风扇模式已关闭(`0x0751` bit6 未置位)时做的:官方
`uw_set_fan()` 在这种情况下会先调 `uw_init_fan()`,而该函数会读 `0x07c5`/`0x07c6`
并回写;随后落到寄存器上的写入并未被 EC 采纳,读数因此不变。也就是说,「无效」来自
初始化那一步,而不是 fan1 写不进去。(2026-10-09 之前的补丁在这条路径上尤其危险:
初始化会做持锁的 WMI 重试,连写 fan1 可把 EC 卡死。)

新版补丁(2026-10-09,4 hunk:decl / init 早退 / dmi / setfan)给 `uw_init_fan()` 加了
`fans_initialized` 早退,让稳态写入只做单次寄存器写,不再触发上述初始化。按这条路径,
**未打补丁时 fan1 同样能直控**;补丁的意义因此不再是「能不能写」,而是写到正确的表——
WUJIE 机型左右风扇共用同一张 CPU 表,补丁让 fan1 用 CPU 表地址 `0x0f20`,而不是 EC
不响应的 GPU 表地址 `0x0f50`。

### EC 行为(实测)
- 写入值 < 约 25%(原始值 50)时,EC 会把持续占空比夹到最低档(读数约 8~26);
  写入 `0` 后约 3 分钟内会被抬到约 13%。这是 EC 固件行为,驱动注释里亦有记载。
- 温度读数:`temp0`(0x043e)返回 CPU 侧温度;`temp1`(0x044f)恒为 0,不可用。

## 安装

- **helper 编译 + udev 规则 + 探测**:运行 `./install.sh`,一键完成
- **驱动补丁(让左风扇写入共享 CPU 表)**:运行 `sudo python3 scripts/apply-driver-patch.py`,再执行:

```sh
sudo dkms remove mechrevo-drivers/4.22.3 --all
sudo dkms install mechrevo-drivers/4.22.3 -k <新内核版本>
```

打完补丁后重启,左风扇写入共享 CPU 表。注意:驱动包升级会覆盖 `/usr/src/`,补丁需重打。

## 使用

- **状态栏部件**:显示 `占空比% 温度°`,点击循环切换 自动 → 曲线 → 手动;右键打开控制面板
- **控制面板**:三种模式(自动/曲线/手动)、手动滑块、风扇曲线选择、状态展示
- **CLI**:`mechrevo-fanctl status` 查看状态;`set 0 <raw>` 设右风扇;`set 1 <raw>` 设左风扇(打补丁后写入共享 CPU 表);`auto` 交还 EC

## 排障

- `mechrevo-fanctl status` 报 `Permission denied`:检查 `/dev/tuxedo_io` 属组是否为 `plugdev`,当前用户是否在 `plugdev` 组
- 左风扇 `set 1` 读数不变:确认驱动补丁是否生效(`set 1` 走 GPU 表 `0x0f50` 时读数不会跟随),参照上文「安装」节重打补丁
- 部件显示 `--`:运行 `noctalia msg plugins list` 确认插件已启用,再检查 `~/.local/bin/mechrevo-fanctl` 是否存在

## 背景:为什么需要这个插件

这台机械革命(WUJIE X5SP4NAG)的 Uniwill EC 有个怪癖:**左风扇**(CPU 侧)在官方驱动(TUXEDO/tuxedo-drivers,4.22.x)里被分到 GPU 曲线表(`0x0f50`),而这块 EC 不响应那张表,导致左风扇停转(停在最低档 ≈25%)。两个风扇只有在「自动」模式下才都转,但自动模式的转速曲线不可调。

本插件绕开 EC 自动模式,经 `/dev/tuxedo_io` 直写风扇寄存器。历史的驱动补丁修复
(两风扇共用 CPU 表 `0x0f20`)在 2026-09-22 驱动包升级 4.22.1 → 4.22.3 时被覆盖,
由 `scripts/apply-driver-patch.py` 重新固化——把 `uw_set_fan()` 里 fan1 的目标表
从 GPU 表改回 CPU 表,让左风扇的写入落到这张共享表上。补丁的作用不是「让 fan1 能写」
(这条写路径本身是通的),而是让 fan1 写到 EC 真正响应的 CPU 表地址。

## 仓库结构

```
.
├── helper/mechrevo-fanctl.c   # C 小工具:经 /dev/tuxedo_io 直读写 EC 风扇寄存器
├── udev/60-mechrevo-fanctl.rules  # 赋予 plugdev 组 /dev/tuxedo_io 读写权
├── scripts/apply-driver-patch.py  # 驱动补丁:修 fan1 写入 CPU 表而非 GPU 表
├── mechrevo-fan/              # Noctalia 插件本体(服务 + 部件 + 面板)
│   ├── plugin.toml            # 清单:service + bar widget + panel + 设置项
│   ├── service.luau           # 轮询/写风扇/曲线/过热保护
│   ├── widget.luau            # 状态栏部件
│   ├── panel.luau             # 控制面板
│   └── translations/          # zh-Hans + en
└── install.sh                 # 一键部署 helper + udev
```

## 故障排查:抓风扇被拉满的写者

`scripts/trace-fan-writers.sh` 用 ftrace kprobe 记录内核侧所有风扇 EC 写操作的调用者与参数。排查「风扇被钉在异常转速」时:

```
sudo scripts/trace-fan-writers.sh start
# ...复现问题...
sudo scripts/trace-fan-writers.sh dump   # 存 /var/log/fan-trace.log 并预览
sudo scripts/trace-fan-writers.sh stop
```

输出里每行带进程名/PID,可直接看出是 tccd、mechrevo-fanctl 还是别的进程在写。
