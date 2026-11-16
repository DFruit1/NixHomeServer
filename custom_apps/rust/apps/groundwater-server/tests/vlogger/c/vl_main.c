/* Virtual logger: replaces main.c. Same globals and the same boot / wake /
 * sleep loop as the firmware's main(), on the emulated board.
 *
 * Process model: one process = one MCU run from reset. A reset (reboot,
 * enter_bootloader, a controller "reset") saves what survives it (backup
 * registers DR0-DR4, the RTC, the .noinit RAM the startup code does not
 * clear, the reset cause) into <dir>/state.bin and exits with status 42;
 * the controller starts the next run. A power cut (`power-off`, or killing
 * the process) keeps only the MRAM and SD files. --power-on starts from a
 * loss of power (RTC at its reset value, backup registers clear).
 *
 * Control channel: commands on stdin, one per line, read only while the
 * logger is in STOP mode (the controller sees a "sleep" event first):
 *   wake                   run to the RTC alarm
 *   advance <utc_s>        jump the world clock (wakes at the alarm if due)
 *   tap <peak_mg>          ADXL345 single tap (INT1)
 *   button                 test button
 *   set <key>=<value> ...  simulated inputs / modem behaviour (vl_cfg)
 *   fault <spec>           publish fault rule (vl_modem.c)
 *   rtc <delta_ms>         RTC error against the world clock
 *   status                 one "status" event
 *   reset pin|wdg|sw       reset; power-off: lose power
 * Events go to the original stdout as JSON lines; the firmware's console
 * (GWL_LOG, debug build) goes to stderr. */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "main.h"
#include "app_core.h"
#include "app_globals.h"
#include "board_io.h"
#include "gwl_app_events.h"
#include "rtc_alarm.h"
#include "Quectel_EC21.h"
#include "vl.h"

ADC_HandleTypeDef hadc1;
I2C_HandleTypeDef hi2c1;
RTC_HandleTypeDef hrtc;
SPI_HandleTypeDef hspi1;
SPI_HandleTypeDef hspi2;
UART_HandleTypeDef huart1 = {HAL_UART_STATE_READY, 0};
UART_HandleTypeDef huart2 = {HAL_UART_STATE_READY, 0};
app_flags_t FLAG;
char Device_ID[25];
uint32_t sp; /* app_cmd.c h_get_debug: "mov %0, sp" stores to this symbol on x86 */

vl_cfg_t vl_cfg = {
    .sensor_ma = 8.0,
    .bat_mv = 7600,
    .sol_mv = 5200,
    .tilt_x = 0,
    .tilt_y = 0,
    .tilt_z = 1000,
    .accel_present = true,
    .gnss_fix = true,
    .lat = -33.8688197,
    .lon = 151.2092955,
    .alt_m = 12,
    .sats = 9,
    .fix = 3,
    .hdop = 0.9,
    .net_time = true,
    .csq = 21,
    .registered = true,
    .sim_present = true,
    .modem_powered = true,
    .pubex = true,
    .publen = true,
    .sd_present = true,
    .mram = 0,
    .ff = 20,
    .idle_grace_ms = 600,
    .host = "127.0.0.1",
    .port = 1883,
};

vl_reset_t vl_reset_cause = VL_RESET_POR;
static int evfd = 1;
static char state_path[512];
extern char vl_noinit_start[], vl_noinit_end[];
extern int64_t vl_alarm_world_ms(void);

/* ------------------------------------------------------------------ events */

void vl_event(const char *fmt, ...) {
    char buf[8192];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf - 1, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n > sizeof buf - 2) {
        /* long payload: print it in full */
        char *big = malloc((size_t)n + 2);
        va_start(ap, fmt);
        vsnprintf(big, (size_t)n + 1, fmt, ap);
        va_end(ap);
        big[n] = '\n';
        if (write(evfd, big, (size_t)n + 1) < 0) {}
        free(big);
        return;
    }
    buf[n] = '\n';
    if (write(evfd, buf, (size_t)n + 1) < 0) {}
}

void vl_hex(char *out, const uint8_t *d, size_t n) {
    for (size_t i = 0; i < n; i++) {
        out[2 * i] = "0123456789ABCDEF"[d[i] >> 4];
        out[2 * i + 1] = "0123456789ABCDEF"[d[i] & 15u];
    }
    out[2 * n] = '\0';
}

void vl_status_event(const char *ev) {
    gwl_ring_state_t st = {0};
    if (App.ring_present) gwl_ring_get_state(&App.ring, &st);
    gwl_time_t now = Time_Now();
    const gwl_settings_t *s = &App.set;
    vl_event("{\"ev\":\"%s\",\"world\":%lld,\"wake\":%lld,\"t\":%u,\"tv\":%u,\"src\":%u,\"up\":%u,"
             "\"ring_present\":%d,\"ring_ok\":%d,\"head\":%u,\"tail\":%u,\"sd_end\":%u,\"mqtt_end\":%u,"
             "\"unsaved\":%u,\"log_id\":%u,\"last_seq\":%u,\"next_seq\":%u,\"gen\":%u,\"boot\":%u,\"flags\":%u,"
             "\"err\":%u,\"missed_readings\":%u,\"next_read\":%u,\"next_send\":%u,\"last_upload\":%u,"
             "\"retry_s\":%u,\"read_s\":%u,\"send_s\":%u,\"listen_s\":%u,"
             "\"fac\":[%.7g,%.7g,%.7g,%.7g],\"sd_state\":%u,\"mram\":%u,\"alarm_hi\":%d,\"alarm_lo\":%d,"
             "\"fault_state\":%u,\"power_critical\":%d}",
             ev, (long long)(vl_world_ms() / 1000), (long long)(vl_alarm_world_ms() / 1000), now.t,
             now.flags & GWL_TIME_VALID, now.flags >> GWL_TIME_SRC_SHIFT, Time_Uptime(), App.ring_present,
             App.ring_ok, st.head, st.tail, st.sd_saved_end, st.mqtt_saved_end, st.unsaved_bytes, st.log_id,
             st.last_seq, st.next_seq, App_Gen(), st.boot_count, st.flags, st.last_error, st.missed_readings,
             App.sched.next_read, App.sched.next_send, App.sched.last_upload, App.sched.retry_s, s->read_s,
             s->send_s, s->listen_s, (double)s->fac[0], (double)s->fac[1], (double)s->fac[2], (double)s->fac[3],
             App.sd_state, App_MramState(), App.alarm.high, App.alarm.low, App.fault_state, App.power_critical);
}

/* ---------------------------------------------------------- resets/state */

typedef struct {
    uint32_t magic;
    uint32_t cause;
    int64_t rtc_delta_ms;
    uint32_t bkp[5];
    uint32_t noinit_len;
} state_hdr_t;
#define STATE_MAGIC 0x564C5354u /* "VLST" */

static void state_save(vl_reset_t next) {
    state_hdr_t h = {STATE_MAGIC, next, vl_rtc_delta_ms, {0}, (uint32_t)(vl_noinit_end - vl_noinit_start)};
    memcpy(h.bkp, vl_bkp, sizeof h.bkp);
    FILE *f = fopen(state_path, "wb");
    if (!f) return;
    fwrite(&h, sizeof h, 1, f);
    fwrite(vl_noinit_start, 1, h.noinit_len, f);
    fclose(f);
}

void vl_state_load(const char *path, bool power_on) {
    snprintf(state_path, sizeof state_path, "%s", path);
    state_hdr_t h;
    FILE *f = power_on ? NULL : fopen(path, "rb");
    if (f && fread(&h, sizeof h, 1, f) == 1 && h.magic == STATE_MAGIC &&
        h.noinit_len == (uint32_t)(vl_noinit_end - vl_noinit_start)) {
        vl_reset_cause = (vl_reset_t)h.cause;
        vl_rtc_delta_ms = h.rtc_delta_ms;
        memcpy(vl_bkp, h.bkp, sizeof vl_bkp);
        if (fread(vl_noinit_start, 1, h.noinit_len, f) != h.noinit_len) memset(vl_noinit_start, 0, h.noinit_len);
    } else {
        /* loss of power: RTC at its reset value, backup registers clear,
         * .noinit RAM undefined (zero here; the firmware validates it) */
        vl_reset_cause = VL_RESET_POR;
        vl_rtc_delta_ms = 946684800LL * 1000 - vl_world_ms();
        memset(vl_bkp, 0, sizeof vl_bkp);
        memset(vl_noinit_start, 0, (size_t)(vl_noinit_end - vl_noinit_start));
    }
    if (f) fclose(f);
}

_Noreturn void vl_reset(vl_reset_t next, uint32_t dr4_bits) {
    vl_bkp[4] |= dr4_bits;
    vl_status_event("reset");
    vl_modem_shutdown();
    vl_board_power_off();
    state_save(next);
    exit(42);
}

_Noreturn void vl_power_off(void) {
    vl_status_event("power_off");
    vl_modem_shutdown();
    vl_board_power_off();
    remove(state_path);
    exit(0);
}

/* ---------------------------------------------------------------- control */

static void set_key(const char *k, const char *v) {
#define B(name) else if (!strcmp(k, #name)) vl_cfg.name = atoi(v) != 0
#define I(name) else if (!strcmp(k, #name)) vl_cfg.name = atoi(v)
#define D(name) else if (!strcmp(k, #name)) vl_cfg.name = atof(v)
    if (0) {
    }
    D(sensor_ma);
    I(bat_mv);
    I(sol_mv);
    B(adc_fault);
    I(tilt_x);
    I(tilt_y);
    I(tilt_z);
    B(accel_present);
    B(gnss_fix);
    D(lat);
    D(lon);
    I(alt_m);
    I(sats);
    I(fix);
    D(hdop);
    B(net_time);
    I(csq);
    B(registered);
    B(sim_present);
    B(modem_powered);
    B(pubex);
    B(publen);
    B(sd_present);
    I(mram);
    I(ff);
    I(idle_grace_ms);
    else fprintf(stderr, "vlogger: unknown key %s\n", k);
#undef B
#undef I
#undef D
}

static void apply_set(char *args) {
    for (char *tok = strtok(args, " "); tok; tok = strtok(NULL, " ")) {
        char *eq = strchr(tok, '=');
        if (!eq) continue;
        *eq = '\0';
        set_key(tok, eq + 1);
    }
}

/* STOP mode: the controller decides what wakes the logger. */
void vl_stop(void) {
    char cmd[512];
    vl_status_event("sleep");
    for (;;) {
        if (!fgets(cmd, sizeof cmd, stdin)) vl_power_off();
        cmd[strcspn(cmd, "\r\n")] = '\0';
        int64_t wake = vl_alarm_world_ms();
        if (!strcmp(cmd, "wake")) {
            if (wake >= 0 && wake > vl_world_ms()) vl_jump_ms((uint64_t)(wake - vl_world_ms()));
            HAL_RTC_AlarmAEventCallback(&hrtc);
            return;
        } else if (!strncmp(cmd, "advance ", 8)) {
            int64_t to = atoll(cmd + 8) * 1000;
            if (wake >= 0 && to >= wake) {
                if (wake > vl_world_ms()) vl_jump_ms((uint64_t)(wake - vl_world_ms()));
                HAL_RTC_AlarmAEventCallback(&hrtc);
                return;
            }
            if (to > vl_world_ms()) vl_jump_ms((uint64_t)(to - vl_world_ms()));
            vl_status_event("sleep");
        } else if (!strncmp(cmd, "tap ", 4)) {
            vl_tap((uint16_t)atoi(cmd + 4));
            FLAG.tap = 1;
            return;
        } else if (!strcmp(cmd, "button")) {
            FLAG.button = 1;
            return;
        } else if (!strncmp(cmd, "set ", 4)) {
            apply_set(cmd + 4);
            vl_event("{\"ev\":\"ok\"}");
        } else if (!strncmp(cmd, "fault ", 6)) {
            vl_modem_fault(cmd + 6);
            vl_event("{\"ev\":\"ok\"}");
        } else if (!strncmp(cmd, "rtc ", 4)) {
            vl_rtc_delta_ms = atoll(cmd + 4);
            vl_event("{\"ev\":\"ok\"}");
        } else if (!strcmp(cmd, "status")) {
            vl_status_event("status");
        } else if (!strcmp(cmd, "reset pin")) {
            vl_reset(VL_RESET_PIN, 0);
        } else if (!strcmp(cmd, "reset wdg")) {
            vl_reset(VL_RESET_WDG, 0);
        } else if (!strcmp(cmd, "reset sw")) {
            vl_reset(VL_RESET_SW, 0);
        } else if (!strcmp(cmd, "power-off")) {
            vl_power_off();
        } else {
            vl_event("{\"ev\":\"error\",\"cmd\":\"%s\"}", cmd);
        }
    }
}

/* ------------------------------------------------------------------- main */

static void usage(void) {
    fprintf(stderr,
            "usage: vlogger --dir DIR --offset-file FILE --uid HEX24 [--host H] [--port P] [--user U]\n"
            "               [--pass P] [--power-on] [--no-sd] [--no-mram] [--flash FILE] [--set k=v ...]\n"
            "       vlogger --uid HEX24 --print-id\n");
    exit(2);
}

int main(int argc, char **argv) {
    const char *dir = NULL, *offset = NULL, *uid = NULL, *flash = NULL;
    bool power_on = false, print_id = false, no_sd = false;
    char sets[1024] = "";
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--dir") && v) dir = argv[++i];
        else if (!strcmp(a, "--offset-file") && v) offset = argv[++i];
        else if (!strcmp(a, "--uid") && v) uid = argv[++i];
        else if (!strcmp(a, "--host") && v) snprintf(vl_cfg.host, sizeof vl_cfg.host, "%s", argv[++i]);
        else if (!strcmp(a, "--port") && v) vl_cfg.port = atoi(argv[++i]);
        else if (!strcmp(a, "--user") && v) snprintf(vl_cfg.user, sizeof vl_cfg.user, "%s", argv[++i]);
        else if (!strcmp(a, "--pass") && v) snprintf(vl_cfg.pass, sizeof vl_cfg.pass, "%s", argv[++i]);
        else if (!strcmp(a, "--flash") && v) flash = argv[++i];
        else if (!strcmp(a, "--set") && v) {
            strncat(sets, argv[++i], sizeof sets - strlen(sets) - 2);
            strcat(sets, " ");
        } else if (!strcmp(a, "--power-on")) power_on = true;
        else if (!strcmp(a, "--print-id")) print_id = true;
        else if (!strcmp(a, "--no-sd")) no_sd = true;
        else usage();
    }
    if (!uid || strlen(uid) != 24) usage();
    for (int i = 0; i < 3; i++) {
        char w[9];
        memcpy(w, uid + 8 * i, 8);
        w[8] = '\0';
        vl_uid[i] = (uint32_t)strtoul(w, NULL, 16);
    }
    gwl_device_hex((const uint32_t *)UID_BASE, Device_ID); /* the V2.1 algorithm, as main.c */
    if (print_id) {
        printf("%s\n", Device_ID);
        return 0;
    }
    if (!dir || !offset) usage();
    apply_set(sets);
    if (no_sd) vl_cfg.sd_present = false;

    /* events on the original stdout; printf (GWL_LOG) to stderr */
    evfd = dup(1);
    dup2(2, 1);
    setvbuf(stdout, NULL, _IONBF, 0);

    char path[600];
    vl_time_init(offset);
    snprintf(path, sizeof path, "%s/state.bin", dir);
    vl_state_load(path, power_on);
    char mram[600], sd[600];
    snprintf(mram, sizeof mram, "%s/mram.bin", dir);
    snprintf(sd, sizeof sd, "%s/sd.img", dir);
    vl_board_init(mram, sd, flash);
    vl_modem_init();
    StartModemReceive();
    /* a reset clears the bootloader request after the jump (Board_CheckBootloaderRequest) */
    vl_bkp[4] &= ~BOARD_BOOTLOADER_MASK;
    vl_event("{\"ev\":\"boot\",\"device\":\"%s\",\"cause\":\"%s\",\"world\":%lld}", Device_ID,
             Board_ResetCauseName(), (long long)(vl_world_ms() / 1000));
    App_Boot();
    for (;;) {
        Watchdog_Feed();
        App_Wake();
        App_Sleep();
    }
}

/* main.c: interrupts off and spin until the IWDG resets the MCU. */
void Error_Handler(void) {
    vl_event("{\"ev\":\"error_handler\"}");
    vl_reset(VL_RESET_WDG, 0);
}
