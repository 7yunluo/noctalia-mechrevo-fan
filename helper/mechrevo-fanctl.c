/*
 * mechrevo-fanctl — 读写 Uniwill EC 风扇状态的小工具。
 * 经 /dev/tuxedo_io 与 mechrevo-drivers(tuxedo-drivers) 通信。
 *
 * 用法:
 *   mechrevo-fanctl status                 输出 JSON 状态(风扇占空比/EC温度/模式寄存器)
 *   mechrevo-fanctl set <0|1> <0-200>      设置风扇占空比(200 = 100%)
 *   mechrevo-fanctl auto                   交还 EC 自动控制
 *
 * 退出码: 0 成功; 1 设备错误; 2 参数错误; 3 设备不存在; 4 权限不足;
 *         5 状态读取失败(ioctl 出错,JSON 中 ok=false)。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/file.h>

#define IOCTL_MAGIC 0xEC
#define MAGIC_READ_UW  (IOCTL_MAGIC + 3)
#define MAGIC_WRITE_UW (IOCTL_MAGIC + 4)

#define R_UW_FANSPEED  _IOR(MAGIC_READ_UW, 0x10, int32_t *)
#define R_UW_FANSPEED2 _IOR(MAGIC_READ_UW, 0x11, int32_t *)
#define R_UW_FAN_TEMP  _IOR(MAGIC_READ_UW, 0x12, int32_t *)
#define R_UW_FAN_TEMP2 _IOR(MAGIC_READ_UW, 0x13, int32_t *)
#define R_UW_MODE      _IOR(MAGIC_READ_UW, 0x14, int32_t *)
#define R_UW_FANS_MIN_SPEED _IOR(MAGIC_READ_UW, 0x17, int32_t *)
#define W_UW_FANSPEED  _IOW(MAGIC_WRITE_UW, 0x10, int32_t *)
#define W_UW_FANSPEED2 _IOW(MAGIC_WRITE_UW, 0x11, int32_t *)
#define W_UW_FANAUTO   _IO(MAGIC_WRITE_UW, 0x14)

#define RC_DEVICE_MISSING 3   /* 设备节点不存在 */
#define RC_PERMISSION     4   /* 设备存在但权限不足 */
#define RC_STATUS_IOCTL   5   /* status 读取失败 */

/* 打开设备节点,区分「不存在」与「权限不足」两种失败。 */
static int open_dev(void)
{
    int fd = open("/dev/tuxedo_io", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "open /dev/tuxedo_io: %s\n", strerror(errno));
        if (errno == ENOENT)
            return -RC_DEVICE_MISSING;
        if (errno == EACCES || errno == EPERM)
            return -RC_PERMISSION;
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        fprintf(stderr, "another fanctl operation is in progress\n");
        close(fd);
        return -6;
    }
    return fd;
}

/* 读一个寄存器;ioctl 出错或驱动回填负值(错误哨兵)都算读取失败。 */
static int read_or(int fd, unsigned long req, int32_t *out)
{
    if (ioctl(fd, req, out) < 0 || *out < 0) {
        *out = -1;
        return 0;
    }
    return 1;
}

static int cmd_status(int fd)
{
    int32_t fan0 = -1, fan1 = -1, temp0 = -1, temp1 = -1;
    int32_t mode = -1, minspeed = -1;

    /* 关键字段任一 ioctl 失败则整体视为不健康 */
    int ok = 1;
    ok &= read_or(fd, R_UW_FANSPEED, &fan0);
    ok &= read_or(fd, R_UW_FANSPEED2, &fan1);
    ok &= read_or(fd, R_UW_FAN_TEMP, &temp0);
    read_or(fd, R_UW_FAN_TEMP2, &temp1);
    ok &= read_or(fd, R_UW_MODE, &mode);
    read_or(fd, R_UW_FANS_MIN_SPEED, &minspeed);

    printf("{\"ok\":%s,\"fan0\":%d,\"fan1\":%d,\"temp0\":%d,\"temp1\":%d,"
           "\"mode\":%d,\"minSpeed\":%d,\"scale\":200}\n",
           ok ? "true" : "false",
           fan0, fan1, temp0, temp1, mode, minspeed);
    return ok ? 0 : RC_STATUS_IOCTL;
}

static int cmd_set(int fd, int idx, long raw)
{
    unsigned long req = idx == 0 ? W_UW_FANSPEED : W_UW_FANSPEED2;
    int32_t arg = (int32_t)raw;

    if (ioctl(fd, req, &arg) < 0) {
        fprintf(stderr, "ioctl set fan%d: %s\n", idx, strerror(errno));
        return 1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "status";
    int fd;

    fd = open_dev();
    if (fd < 0)
        return -fd;

    if (strcmp(cmd, "status") == 0) {
        int rc = cmd_status(fd);
        close(fd);
        return rc;
    }

    if ((strcmp(cmd, "set") == 0 && argc == 4) ||
        (strcmp(cmd, "set-both") == 0 && argc == 3)) {
        int both = strcmp(cmd, "set-both") == 0;
        char *end;
        errno = 0;
        long idx = both ? 0 : strtol(argv[2], &end, 10);
        if (!both && (errno || end == argv[2] || *end || idx < 0 || idx > 1)) {
            fprintf(stderr, "set: fan index must be 0 or 1\n");
            close(fd);
            return 2;
        }
        char *speed = argv[both ? 2 : 3];
        errno = 0;
        long raw = strtol(speed, &end, 10);
        if (errno || end == speed || *end || raw < 0 || raw > 200) {
            fprintf(stderr, "set: speed must be 0-200\n");
            close(fd);
            return 2;
        }
        int rc = cmd_set(fd, (int)idx, raw);
        if (both && rc == 0)
            rc = cmd_set(fd, 1, raw);
        if (both && rc == 0)
            rc = cmd_status(fd);
        if (both && rc != 0)
            ioctl(fd, W_UW_FANAUTO, 0);
        close(fd);
        return rc;
    }

    if (strcmp(cmd, "auto") == 0) {
        if (ioctl(fd, W_UW_FANAUTO, 0) < 0) {
            fprintf(stderr, "ioctl auto: %s\n", strerror(errno));
            close(fd);
            return 1;
        }
        close(fd);
        return 0;
    }

    fprintf(stderr, "usage: mechrevo-fanctl status | set <0|1> <0-200> | set-both <0-200> | auto\n");
    close(fd);
    return 2;
}
