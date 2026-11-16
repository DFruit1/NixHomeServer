/* Virtual logger: emulated board drivers below the application.
 *
 * Emulated here (the real drivers need the STM32 peripherals):
 *   board_io.c      reset cause (from the harness state), LED, random,
 *                   DR4 marking before a commanded reset, watchdog (no-op)
 *   spi2_bus.c      no-op bus hand-over
 *   mram_mr25h10.c  MRAM_* API on a 128 KiB file (every write goes straight
 *                   to the file, so killing the process is a power cut)
 *   adxl345_app.c   Accel_* API from vl_cfg (tilt) and injected taps
 *   display_ui.c    the panel: renders succeed, nothing is drawn
 *   flash_config.c  the V2.1 settings page from a 2 KiB file, decoded by the
 *                   firmware's own GWL_DecodeSettings + gwl_legacy_settings
 *   user_diskio.c / fatfs_sd_card.c   FatFs disk_* on a card image file
 *   app_fatfs.c     get_fattime() -> App_FatTime(), as the firmware does */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "main.h"
#include "adxl345_app.h"
#include "app_core.h"
#include "board_io.h"
#include "diskio.h"
#include "display_ui.h"
#include "ff.h"
#include "flash_config.h"
#include "gwl_app_events.h"
#include "gwl_parse.h"
#include "mram_mr25h10.h"
#include "spi2_bus.h"
#include "vl.h"

uint32_t vl_uid[3];

/* ------------------------------------------------------------- board_io */

static bool led_enabled, led_on;
bool Board_LseFailed;
void Board_SetLedEnabled(bool enabled) {
    led_enabled = enabled;
    if (!enabled) Op_LED_OFF();
}
bool Board_LedEnabled(void) { return led_enabled; }
void Op_LED_ON(void) { led_on = led_enabled; }
void Op_LED_OFF(void) { led_on = false; }

void Board_CaptureResetCause(void) {}
board_reset_t Board_ResetCause(void) {
    switch (vl_reset_cause) {
    case VL_RESET_POR: return BOARD_RESET_POR;
    case VL_RESET_PIN: return BOARD_RESET_PIN;
    case VL_RESET_WDG: return BOARD_RESET_WDG;
    case VL_RESET_SW: return BOARD_RESET_SW;
    }
    return BOARD_RESET_OTHER;
}
const char *Board_ResetCauseName(void) {
    static const char *const names[] = {"other", "por", "pin", "wdg", "sw", "bor"};
    return names[Board_ResetCause()];
}
uint32_t Board_ResetFlags(void) {
    /* RCC->CSR flags as the STM32G0 sets them (PINRSTF with every internal
     * reset), plus DR4 [7:0] */
    static const uint32_t csr[] = {0, 0x08000000u | 0x04000000u, 0x04000000u, 0x20000000u | 0x04000000u,
                                   0x10000000u | 0x04000000u};
    return csr[vl_reset_cause] | (Board_LseFailed ? 0x100u : 0u) | (vl_bkp[4] & 0xFFu);
}
void Board_ResetMarked(uint32_t bits) { vl_reset(VL_RESET_SW, bits); }
void Board_Reboot(void) { vl_reset(VL_RESET_SW, GWL_BOOT_CLEAN); }
void Board_EnterBootloader(void) {
    vl_event("{\"ev\":\"bootloader\"}");
    vl_reset(VL_RESET_SW, BOARD_BOOTLOADER_MAGIC | GWL_BOOT_CLEAN);
}
void Board_CheckBootloaderRequest(void) {}

static uint32_t rnd_state = 0x9E3779B9u;
uint32_t Board_Random32(void) {
    uint32_t h = rnd_state ^ (uint32_t)vl_tick_ms() ^ vl_uid[0];
    h ^= h >> 16;
    h *= 0x85EBCA6Bu;
    h ^= h >> 13;
    h *= 0xC2B2AE35u;
    h ^= h >> 16;
    rnd_state = h + 0x9E3779B9u;
    return h;
}
void Wake_RestoreClock(void) {}
void Watchdog_StartEarly(void) {}
void Watchdog_Init(void) {}
void Watchdog_Feed(void) {}
void Watchdog_SetMaxSleep(uint32_t s) { (void)s; }

/* ------------------------------------------------------------- spi2_bus */

static gwl_spi2_owner_t spi_owner;
void GWL_SPI2_Init(void) {}
void GWL_SPI2_SelectSD(void) { spi_owner = GWL_SPI2_SD; }
void GWL_SPI2_SelectMRAM(void) { spi_owner = GWL_SPI2_MRAM; }
void GWL_SPI2_Release(void) { spi_owner = GWL_SPI2_NONE; }
gwl_spi2_owner_t GWL_SPI2_Owner(void) { return spi_owner; }
void GWL_SPI2_SetSDSlowClock(bool slow) { (void)slow; }
void GWL_SPI2_MramCs(bool a) { (void)a; }
bool GWL_SPI2_Transfer(const uint8_t *tx, uint8_t *rx, size_t n) {
    (void)tx;
    (void)rx;
    (void)n;
    return false;
}
void GWL_DelayUs(uint32_t us) { (void)us; }

/* ------------------------------------------------------------------ MRAM */

static int mram_fd = -1;
static mram_status_t mram_status;

mram_status_t MRAM_Init(void) {
    mram_status = vl_cfg.mram == 1 ? MRAM_STATUS_ABSENT : vl_cfg.mram == 2 ? MRAM_STATUS_FAULT
                  : mram_fd >= 0   ? MRAM_STATUS_OK
                                   : MRAM_STATUS_ABSENT;
    return mram_status;
}
mram_status_t MRAM_Status(void) { return mram_status; }
uint32_t MRAM_DetectedSize(void) { return mram_status == MRAM_STATUS_OK ? GWL_MRAM_SIZE : 0; }
bool MRAM_Read(uint32_t addr, void *buf, size_t n) {
    if (mram_status != MRAM_STATUS_OK || addr + n > GWL_MRAM_SIZE) return false;
    return pread(mram_fd, buf, n, addr) == (ssize_t)n;
}
bool MRAM_Write(uint32_t addr, const void *buf, size_t n) {
    if (mram_status != MRAM_STATUS_OK || addr + n > GWL_MRAM_SIZE) return false;
    return pwrite(mram_fd, buf, n, addr) == (ssize_t)n;
}
void MRAM_Sleep(void) {}
void MRAM_Wake(void) {}
bool MRAM_IsAsleep(void) { return false; }
static bool ops_read(void *c, uint32_t a, void *b, size_t n) {
    (void)c;
    return MRAM_Read(a, b, n);
}
static bool ops_write(void *c, uint32_t a, const void *b, size_t n) {
    (void)c;
    return MRAM_Write(a, b, n);
}
const gwl_mram_t *MRAM_Ops(void) {
    static const gwl_mram_t ops = {ops_read, ops_write, NULL};
    return &ops;
}

/* ----------------------------------------------------------------- accel */

static uint16_t tap_peak;
static bool tap_latched, tap_enabled;
bool Accel_Configure(bool en, uint8_t sens) {
    (void)sens;
    tap_enabled = en;
    return vl_cfg.accel_present;
}
bool Accel_Init(bool en, uint8_t sens) { return Accel_Configure(en, sens); }
uint8_t Accel_Status(void) { return vl_cfg.accel_present ? ACCEL_STATUS_OK : ACCEL_STATUS_NO_RESPONSE; }
bool Accel_ReadTilt(accel_tilt_t *out) {
    if (!vl_cfg.accel_present) {
        out->x_mg = out->y_mg = out->z_mg = out->pitch_ddeg = out->roll_ddeg = INT16_MIN;
        out->status = ACCEL_STATUS_NO_RESPONSE;
        return false;
    }
    out->x_mg = (int16_t)vl_cfg.tilt_x;
    out->y_mg = (int16_t)vl_cfg.tilt_y;
    out->z_mg = (int16_t)vl_cfg.tilt_z;
    out->pitch_ddeg = GWL_AccelPitchDdeg(out->x_mg, out->y_mg, out->z_mg);
    out->roll_ddeg = GWL_AccelRollDdeg(out->x_mg, out->y_mg, out->z_mg);
    out->status = ACCEL_STATUS_OK;
    return true;
}
bool Accel_ReadImpact(uint16_t *peak) {
    if (!vl_cfg.accel_present || !tap_latched) return false;
    tap_latched = false;
    *peak = tap_peak;
    return true;
}
void vl_tap(uint16_t peak) {
    if (!tap_enabled) return;
    tap_peak = peak;
    tap_latched = true;
}
bool vl_int1_high(void) { return tap_latched; }

/* --------------------------------------------------------------- display */

void GWL_Display_Invalidate(void) {}
void GWL_Display_Park(void) {}
bool GWL_Display_Render(const gwl_display_model_t *m, gwl_display_mode_t mode) {
    (void)m;
    (void)mode;
    return true;
}

/* ------------------------------------------------------- V2.1 flash page */

static uint8_t flash_page[2048];
static bool flash_present;
bool Legacy_ReadSettings(gwl_settings_t *out) {
    char json[GWL_SETTINGS_MAX + 1];
    if (!flash_present) return false;
    size_t n = GWL_DecodeSettings(flash_page, sizeof flash_page, json, sizeof json);
    return n && gwl_legacy_settings(json, n, out);
}

/* ------------------------------------------------------------- SD card */

#define SD_SECTORS (128u * 2048u) /* 128 MiB image, sparse */
static int sd_fd = -1;
static bool sd_powered, sd_init;
void vl_sd_power(bool on) {
    sd_powered = on;
    if (!on) sd_init = false;
}
DSTATUS disk_initialize(BYTE pdrv) {
    if (pdrv || !sd_powered || !vl_cfg.sd_present || sd_fd < 0) return STA_NOINIT | STA_NODISK;
    sd_init = true;
    return 0;
}
DSTATUS disk_status(BYTE pdrv) {
    if (pdrv || !vl_cfg.sd_present || sd_fd < 0) return STA_NOINIT | STA_NODISK;
    return sd_init ? 0 : STA_NOINIT;
}
DRESULT disk_read(BYTE pdrv, BYTE *buff, DWORD sector, UINT count) {
    if (pdrv || !sd_init || !vl_cfg.sd_present) return RES_NOTRDY;
    return pread(sd_fd, buff, count * 512u, (off_t)sector * 512) == (ssize_t)(count * 512u) ? RES_OK : RES_ERROR;
}
DRESULT disk_write(BYTE pdrv, const BYTE *buff, DWORD sector, UINT count) {
    if (pdrv || !sd_init || !vl_cfg.sd_present) return RES_NOTRDY;
    return pwrite(sd_fd, buff, count * 512u, (off_t)sector * 512) == (ssize_t)(count * 512u) ? RES_OK : RES_ERROR;
}
DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff) {
    if (pdrv || !sd_init) return RES_NOTRDY;
    switch (cmd) {
    case CTRL_SYNC: return RES_OK;
    case GET_SECTOR_COUNT: *(DWORD *)buff = SD_SECTORS; return RES_OK;
    case GET_SECTOR_SIZE: *(WORD *)buff = 512; return RES_OK;
    case GET_BLOCK_SIZE: *(DWORD *)buff = 1; return RES_OK;
    default: return RES_PARERR;
    }
}
DWORD get_fattime(void) { return App_FatTime(); }

/* A new card image gets FatFs' own format (FAT32), like a card formatted in
 * a PC; the firmware never formats. */
static void sd_format(void) {
    static FATFS fs;
    static uint8_t work[4096];
    bool was = vl_cfg.sd_present;
    vl_cfg.sd_present = true;
    sd_powered = true;
    FRESULT fr = f_mkfs("", FM_FAT32, 0, work, sizeof work);
    if (fr != FR_OK) fprintf(stderr, "vlogger: f_mkfs failed (%d)\n", (int)fr);
    (void)fs;
    vl_cfg.sd_present = was;
    sd_powered = false;
    sd_init = false;
}

void vl_board_init(const char *mram_file, const char *sd_file, const char *flash_file) {
    if (mram_file && mram_file[0]) {
        struct stat st;
        bool fresh = stat(mram_file, &st) != 0;
        mram_fd = open(mram_file, O_RDWR | O_CREAT, 0644);
        if (mram_fd >= 0 && fresh) {
            /* a new MR25H10 reads 0x00 (blank) */
            if (ftruncate(mram_fd, GWL_MRAM_SIZE) != 0) perror("mram");
        }
    }
    if (sd_file && sd_file[0]) {
        struct stat st;
        bool fresh = stat(sd_file, &st) != 0;
        sd_fd = open(sd_file, O_RDWR | O_CREAT, 0644);
        if (sd_fd >= 0 && fresh) {
            if (ftruncate(sd_fd, (off_t)SD_SECTORS * 512) != 0) perror("sd");
            sd_format();
        }
    }
    if (flash_file && flash_file[0]) {
        memset(flash_page, 0xFF, sizeof flash_page);
        FILE *f = fopen(flash_file, "rb");
        if (f) {
            flash_present = fread(flash_page, 1, sizeof flash_page, f) > 0;
            fclose(f);
        }
    }
}

void vl_board_power_off(void) {
    if (mram_fd >= 0) fsync(mram_fd);
    if (sd_fd >= 0) fsync(sd_fd);
}
