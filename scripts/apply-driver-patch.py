#!/usr/bin/env python3
"""给 uniwill_keyboard.h 打「WUJIE 共享风扇表」补丁。

用法: apply-driver-patch.py [uniwill_keyboard.h 路径]
不传路径时自动探测 /usr/src/mechrevo-drivers-*/uniwill_keyboard.h。

六处改动：新增静态标志 uw_fan_shared_table、uw_init_fan() 只在首次初始化时做
DMI 判定、uw_init_fan() 重复进入时提前返回、uw_set_fan() 的 fan_index==1 分支
在共享表时改写 CPU 表地址；另外两条交还可靠性修复：uw_set_fan_auto() 的 old
分支改用带重试回读的写入（autorc）、uniwill_keyboard_remove() 卸载时调一次
uw_set_fan_auto() 交还 EC（remove）。
每条改动独立判断：已落位的跳过，未落位的用锚点精确匹配，匹配不唯一或缺失即报错
退出；全部已落位则直接成功退出。
先写临时文件再 os.replace，并保留一次 .orig 备份。
"""

import glob
import os
import re
import sys
import tempfile

TARGET_GLOB = "/usr/src/mechrevo-drivers-*/uniwill_keyboard.h"


def version_key(path):
    """从 mechrevo-drivers-<版本> 目录名提取数字元组，供语义排序。"""
    name = os.path.basename(os.path.dirname(path))
    numbers = re.findall(r"\d+", name)
    return tuple(int(n) for n in numbers) if numbers else (0,)


def find_target(argv):
    if len(argv) > 1:
        return argv[1]
    candidates = glob.glob(TARGET_GLOB)
    if not candidates:
        sys.exit("ERROR: no %s found" % TARGET_GLOB)
    candidates.sort(key=version_key)
    return candidates[-1]

EDITS = [
    (
        "full-mode-idempotent",
        "\telse if (mode_data & 0x40){\n",
        "\telse if (!enable && (mode_data & 0x40)){\n",
    ),
    (
        "decl",
        "static bool fans_initialized = false;\n",
        "static bool fans_initialized = false;\n"
        "static bool uw_fan_shared_table = false;\n",
    ),
    (
        "init",
        "int uw_init_fan(void) {\n"
        "\tstruct uniwill_device_features_t *uw_feats = &uniwill_device_features;\n"
        "\tint i, temp_offset;\n",
        "int uw_init_fan(void) {\n"
        "\tstruct uniwill_device_features_t *uw_feats = &uniwill_device_features;\n"
        "\tint i, temp_offset;\n"
        "\n"
        "\tif (fans_initialized)\n"
        "\t\treturn 0;\n",
    ),
    (
        "dmi",
        "\t\tset_full_fan_mode(false);\n"
        "\n"
        "\t\tuniwill_read_ec_ram(addr_use_custom_fan_table_0, &value_use_custom_fan_table_0);\n"
        "\t\tif (!((value_use_custom_fan_table_0 >> offset_use_custom_fan_table_0) & 1)) {\n"
        "\t\t\tuniwill_write_ec_ram_with_retry(addr_use_custom_fan_table_0, value_use_custom_fan_table_0 + (1 << offset_use_custom_fan_table_0), 3);\n"
        "\t\t}",
        "\t\tset_full_fan_mode(false);\n"
        "\n"
        "\t\tuw_fan_shared_table = dmi_match(DMI_BOARD_NAME, \"WUJIE Series-X5SP4NAG\");\n"
        "\n"
        "\t\tif (!uw_fan_shared_table) {\n"
        "\t\t\tuniwill_read_ec_ram(addr_use_custom_fan_table_0, &value_use_custom_fan_table_0);\n"
        "\t\t\tif (!((value_use_custom_fan_table_0 >> offset_use_custom_fan_table_0) & 1)) {\n"
        "\t\t\t\tuniwill_write_ec_ram_with_retry(addr_use_custom_fan_table_0, value_use_custom_fan_table_0 + (1 << offset_use_custom_fan_table_0), 3);\n"
        "\t\t\t}\n"
        "\t\t}",
    ),
    (
        "setfan",
        "\t\t\tif (fan_index == 0)\n"
        "\t\t\t\taddr_for_fan = addr_cpu_custom_fan_table_fan_speed;\n"
        "\t\t\telse if (fan_index == 1)\n"
        "\t\t\t\taddr_for_fan = addr_gpu_custom_fan_table_fan_speed;\n"
        "\t\t\telse\n"
        "\t\t\t\treturn -EINVAL;",
        "\t\t\tif (fan_index == 0)\n"
        "\t\t\t\taddr_for_fan = addr_cpu_custom_fan_table_fan_speed;\n"
        "\t\t\telse if (fan_index == 1)\n"
        "\t\t\t\t// shared table: fan1 uses the CPU fan table too\n"
        "\t\t\t\taddr_for_fan = uw_fan_shared_table\n"
        "\t\t\t\t\t? addr_cpu_custom_fan_table_fan_speed\n"
        "\t\t\t\t\t: addr_gpu_custom_fan_table_fan_speed;\n"
        "\t\t\telse\n"
        "\t\t\t\treturn -EINVAL;",
    ),
    (
        "autorc",
        "\t\tuniwill_write_ec_ram(0x0751, mode_data & 0xbf);\n",
        "\t\tuniwill_write_ec_ram_with_retry(0x0751, mode_data & 0xbf, 3);\n",
    ),
    (
        "remove",
        "\tcancel_delayed_work_sync(&direct_fan_control_restart_delayed_work);\n"
        "\n"
        "#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 11, 0)\n",
        "\tcancel_delayed_work_sync(&direct_fan_control_restart_delayed_work);\n"
        "\n"
        "\t// Hand EC back to automatic fan control on unload\n"
        "\tuw_set_fan_auto();\n"
        "\n"
        "#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 11, 0)\n",
    ),
]


def write_atomic(target, text):
    """先写同目录临时文件再 os.replace，避免中途失败留下半截文件。"""
    directory = os.path.dirname(os.path.abspath(target))
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".apply-driver-patch-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def backup_once(target, text):
    """首次修改前留一份 .orig，已存在则不覆盖。"""
    if os.path.exists(target + ".orig"):
        return
    write_atomic(target + ".orig", text)


def main():
    target = find_target(sys.argv)
    with open(target, "r") as f:
        original = f.read()
    text = original

    applied = []
    for name, old, new in EDITS:
        if new in text:
            continue
        n = text.count(old)
        if n != 1:
            sys.exit("ERROR: anchor %r matched %d times (expected exactly 1)" % (name, n))
        text = text.replace(old, new, 1)
        applied.append(name)
        print("applied hunk: %s" % name)

    if not applied:
        print("already patched, nothing to do (idempotent)")
        return 0

    backup_once(target, original)
    write_atomic(target, text)
    print("patched: %s" % target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
