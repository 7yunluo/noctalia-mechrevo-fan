#!/usr/bin/env python3
"""给 uniwill_keyboard.h 打「WUJIE 共享风扇表」补丁。

用法: apply-driver-patch.py [uniwill_keyboard.h 路径]
不传路径时自动探测 /usr/src/mechrevo-drivers-*/uniwill_keyboard.h。

三处改动：新增静态标志 uw_fan_shared_table、uw_init_fan() 内 DMI 判定
(WUJIE 时跳过 0x07c5 bit7 分离)、uw_set_fan() 的 fan_index==1 分支在共享
表时改写 CPU 表地址。
锚点精确匹配，匹配不唯一或缺失即报错退出；已打过补丁则直接成功退出。
"""

import glob
import sys


def find_target(argv):
    if len(argv) > 1:
        return argv[1]
    candidates = sorted(glob.glob("/usr/src/mechrevo-drivers-*/uniwill_keyboard.h"))
    if not candidates:
        sys.exit("ERROR: no /usr/src/mechrevo-drivers-*/uniwill_keyboard.h found")
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
        "\t\tset_full_fan_mode(false);\n"
        "\n"
        "\t\tuniwill_read_ec_ram(addr_use_custom_fan_table_0, &value_use_custom_fan_table_0);\n"
        "\t\tif (!((value_use_custom_fan_table_0 >> offset_use_custom_fan_table_0) & 1)) {\n"
        "\t\t\tuniwill_write_ec_ram_with_retry(addr_use_custom_fan_table_0, value_use_custom_fan_table_0 + (1 << offset_use_custom_fan_table_0), 3);\n"
        "\t\t}",
        "\t\tset_full_fan_mode(false);\n"
        "\n"
        "\t\t// WUJIE: both fans share one fan table (no 0x07c5 bit7 split)\n"
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


def main():
    target = find_target(sys.argv)
    with open(target, "r") as f:
        text = f.read()

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

    with open(target, "w") as f:
        f.write(text)
    print("patched: %s" % target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
