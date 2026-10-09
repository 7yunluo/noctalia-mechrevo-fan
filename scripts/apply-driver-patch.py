#!/usr/bin/env python3
"""给 uniwill_keyboard.h 打「WUJIE 共享风扇表」补丁。

用法: apply-driver-patch.py [uniwill_keyboard.h 路径]
不传路径时自动探测 /usr/src/mechrevo-drivers-*/uniwill_keyboard.h。

四处改动：新增静态标志 uw_fan_shared_table、uw_init_fan() 只在首次初始化时做
DMI 判定、uw_init_fan() 重复进入时提前返回、uw_set_fan() 的 fan_index==1 分支
在共享表时改写 CPU 表地址。
锚点精确匹配，匹配不唯一或缺失即报错退出；已打过补丁则直接成功退出。
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

    if "uw_fan_shared_table" in text:
        missing = [name for name, _, new in EDITS if new not in text]
        if missing:
            sys.exit("ERROR: uw_fan_shared_table present but hunks missing: %s" % missing)
        print("already patched, nothing to do (idempotent)")
        return 0

    for name, old, _ in EDITS:
        n = text.count(old)
        if n != 1:
            sys.exit("ERROR: anchor %r matched %d times (expected exactly 1)" % (name, n))

    for name, old, new in EDITS:
        text = text.replace(old, new, 1)
        print("applied hunk: %s" % name)

    backup_once(target, original)
    write_atomic(target, text)
    print("patched: %s" % target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
