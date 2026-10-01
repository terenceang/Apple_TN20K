// Disk images on the SD card, served to the FPGA as nibble tracks.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SD_MOUNT "/sd"
#define DISK_TRACKS 35
#define DISK_BYTES (DISK_TRACKS * 16 * 256)
extern const char *const DISK_EXTS[3];       // dsk, do, po
void disk_path(char *out, size_t n, int d, const char *ext);   // SD_MOUNT/disk<d+1>.<ext>

void disks_init(void);                       // mounts /sd/disk{1,2}.{dsk,do,po} if present
bool disk_mount(int d, const char *path);    // d = 0 or 1; bumps the generation
void disks_status(uint8_t *gen0, uint8_t *gen1, uint8_t *flags);
bool disk_read_track(int d, int t, uint8_t *out /*7040*/);
void disk_write_track(int d, int t, const uint8_t *in /*7040*/);
