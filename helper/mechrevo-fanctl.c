/*
 * mechrevo-fanctl — 读写 Uniwill EC 风扇状态的小工具。
 * 经 /dev/tuxedo_io 与 mechrevo-drivers(tuxedo-drivers) 通信。
 *
 * 用法:
 *   mechrevo-fanctl status                 输出 JSON 状态(风扇占空比/EC温度/模式寄存器)
 *   mechrevo-fanctl set <0|1> <0-200>      设置风扇占空比(200 = 100%)
 *   mechrevo-fanctl auto                   交还 EC 自动控制
 *
 * 退出码: 0 成功; 1 设备错误; 2 参数错误; 3 设备不存在。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <errno.h>
#include <sys/ioctl.h>

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

static int open_dev(void)
{
    int fd = open("/dev/tuxedo_io", O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open /dev/tuxedo_io: %s\n", strerror(errno));
        return -1;
    }
    return fd;
}

static void read_or(int fd, unsigned long req, int32_t *out)
{
    if (ioctl(fd, req, out) < 0)
        *out = -1;
}

static int cmd_status(int fd)
{
    int32_t fan0 = -1, fan1 = -1, temp0 = -1, temp1 = -1;
    int32_t mode = -1, minspeed = -1;

    read_or(fd, R_UW_FANSPEED, &fan0);
    read_or(fd, R_UW_FANSPEED2, &fan1);
    read_or(fd, R_UW_FAN_TEMP, &temp0);
    read_or(fd, R_UW_FAN_TEMP2, &temp1);
    read_or(fd, R_UW_MODE, &mode);
    read_or(fd, R_UW_FANS_MIN_SPEED, &minspeed);

    printf("{\"ok\":true,\"fan0\":%d,\"fan1\":%d,\"temp0\":%d,\"temp1\":%d,"
           "\"mode\":%d,\"minSpeed\":%d,\"scale\":200}\n",
           fan0, fan1, temp0, temp1, mode, minspeed);
    return 0;
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
        return 3;

    if (strcmp(cmd, "status") == 0) {
        int rc = cmd_status(fd);
        close(fd);
        return rc;
    }

    if (strcmp(cmd, "set") == 0 && argc >= 4) {
        char *end;
        long idx = strtol(argv[2], &end, 10);
        if (*end || idx < 0 || idx > 1) {
            fprintf(stderr, "set: fan index must be 0 or 1\n");
            close(fd);
            return 2;
        }
        long raw = strtol(argv[3], &end, 10);
        if (*end || raw < 0 || raw > 200) {
            fprintf(stderr, "set: speed must be 0-200\n");
            close(fd);
            return 2;
        }
        int rc = cmd_set(fd, (int)idx, raw);
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

    fprintf(stderr, "usage: mechrevo-fanctl status | set <0|1> <0-200> | auto\n");
    close(fd);
    return 2;
}
