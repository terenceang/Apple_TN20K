#include "disks.h"
#include "nibble.h"
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#define TAG "disks"

typedef struct {
    FILE *f;
    bool writable, po;
    uint8_t gen;      // 0 = no image (f == NULL); changes on every mount
} disk_t;

static disk_t D[2];
static SemaphoreHandle_t mu;
static const uint8_t DOS_TO_PHYS[16] = {0x0, 0xd, 0xb, 0x9, 0x7, 0x5, 0x3, 0x1,
                                        0xe, 0xc, 0xa, 0x8, 0x6, 0x4, 0x2, 0xf};
static uint8_t PHYS_TO_DOS[16];
static uint8_t secbuf[16][256];   // used under mu only

const char *const DISK_EXTS[3] = {"dsk", "do", "po"};

void disk_path(char *out, size_t n, int d, const char *ext) {
    snprintf(out, n, SD_MOUNT "/disk%d.%s", d + 1, ext);
}

static bool bad(int d, int t) { return d < 0 || d > 1 || t < 0 || t >= DISK_TRACKS; }

// File sector holding physical position p: .po is already physical, DOS order is not.
static int sector_slot(const disk_t *k, int p) { return k->po ? p : PHYS_TO_DOS[p]; }

bool disk_mount(int d, const char *path) {
    xSemaphoreTake(mu, portMAX_DELAY);
    disk_t *k = &D[d];
    if (k->f) { fclose(k->f); k->f = NULL; }
    k->gen = 0;
    k->writable = false;
    bool rw = true;
    FILE *f = fopen(path, "r+b");
    if (!f) { rw = false; f = fopen(path, "rb"); }
    bool ok = false;
    if (f) {
        fseek(f, 0, SEEK_END);
        if (ftell(f) == DISK_BYTES) {
            const char *ext = strrchr(path, '.');
            k->po = ext && !strcasecmp(ext, ".po");
            k->f = f; k->writable = rw; ok = true;
            static uint8_t g;
            g = (uint8_t)(g % 255 + 1);       // never 0
            k->gen = g;
            ESP_LOGI(TAG, "drive %d: %s (%s, %s)", d + 1, path, k->po ? "po" : "dos order",
                     rw ? "rw" : "ro");
        } else {
            ESP_LOGW(TAG, "%s: not a 143360-byte image", path);
            fclose(f);
        }
    }
    xSemaphoreGive(mu);
    return ok;
}

void disks_init(void) {
    mu = xSemaphoreCreateMutex();
    for (int p = 0; p < 16; p++) PHYS_TO_DOS[DOS_TO_PHYS[p]] = (uint8_t)p;
    for (int d = 0; d < 2; d++)
        for (int e = 0; e < 3; e++) {
            char path[32];
            disk_path(path, sizeof path, d, DISK_EXTS[e]);
            if (disk_mount(d, path)) break;
        }
}

void disks_status(uint8_t *gen0, uint8_t *gen1, uint8_t *flags) {
    *gen0 = D[0].gen;
    *gen1 = D[1].gen;
    *flags = (uint8_t)((D[0].writable ? 1 : 0) | (D[1].writable ? 2 : 0));
}

bool disk_read_track(int d, int t, uint8_t *out) {
    if (bad(d, t)) return false;
    xSemaphoreTake(mu, portMAX_DELAY);
    disk_t *k = &D[d];
    bool ok = k->f != NULL;
    const uint8_t *sp[16];
    for (int p = 0; ok && p < 16; p++) {
        sp[p] = secbuf[p];
        ok = fseek(k->f, (long)((t * 16 + sector_slot(k, p)) * 256), SEEK_SET) == 0 &&
             fread(secbuf[p], 1, 256, k->f) == 256;
    }
    if (ok) nib_encode_track(t, sp, out);
    xSemaphoreGive(mu);
    return ok;
}

void disk_write_track(int d, int t, const uint8_t *in) {
    if (bad(d, t)) return;
    xSemaphoreTake(mu, portMAX_DELAY);
    disk_t *k = &D[d];
    if (k->f && k->writable) {
        uint16_t mask = nib_decode_track(in, secbuf);
        for (int p = 0; p < 16; p++) {
            if (!(mask & (1u << p))) continue;
            if (fseek(k->f, (long)((t * 16 + sector_slot(k, p)) * 256), SEEK_SET) ||
                fwrite(secbuf[p], 1, 256, k->f) != 256)
                ESP_LOGE(TAG, "drive %d track %d sector %d: SD write failed", d + 1, t, p);
        }
        fflush(k->f);
        ESP_LOGI(TAG, "drive %d track %d: %d sectors written", d + 1, t, __builtin_popcount(mask));
    }
    xSemaphoreGive(mu);
}
