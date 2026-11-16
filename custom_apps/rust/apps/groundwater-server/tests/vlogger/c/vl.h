/* Virtual logger harness: shared declarations of the emulated board.
 *
 * Time model ("world clock"): world UTC = real UTC + offset. The offset is
 * kept in a file that libfaketime also reads for the server and PostgreSQL,
 * so the logger, the server and the database always agree on "now". The
 * logger never sleeps through real time: STOP mode and HAL_Delay() jump the
 * offset forward. While an MQTT session is open, time runs in real time so
 * the server can answer within the listen window; once the link has been
 * idle for vl_cfg.idle_grace_ms it runs vl_cfg.ff times faster. */
#ifndef VL_H
#define VL_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ---- configuration (command line, then `set` control commands) ---- */
typedef struct {
    /* simulated inputs */
    double sensor_ma;     /* 4-20 mA loop current */
    int bat_mv, sol_mv;   /* battery pack / panel */
    bool adc_fault;
    int tilt_x, tilt_y, tilt_z; /* mg */
    bool accel_present;
    bool gnss_fix;        /* GNSS answers with a fix */
    double lat, lon;      /* degrees */
    int alt_m, sats, fix; /* fix 2/3 */
    double hdop;
    bool net_time;        /* network sends time (QLTS) */
    int csq;
    bool registered;
    bool sim_present;
    bool modem_powered;   /* +12 V present */
    bool pubex;           /* AT+QMTPUBEX supported (binary) */
    bool publen;          /* AT+QMTPUB with a length supported */
    bool sd_present;
    int mram;             /* 0 ok, 1 absent, 2 fault */
    /* time */
    int ff;               /* idle fast-forward factor in a session */
    int idle_grace_ms;    /* real ms of link silence before fast-forward */
    /* broker */
    char host[64];
    int port;
    char user[64];
    char pass[128];
} vl_cfg_t;
extern vl_cfg_t vl_cfg;

/* ---- clock ---- */
void vl_time_init(const char *offset_file);
uint64_t vl_tick_ms(void);
int64_t vl_world_ms(void);
void vl_jump_ms(uint64_t ms);
/* RTC = world + delta (ms); persisted across warm resets. */
extern int64_t vl_rtc_delta_ms;
int64_t vl_rtc_ms(void);
/* In a session (MQTT link up): real-time pacing instead of jumps. */
void vl_time_session(bool on);
void vl_time_activity(void); /* link activity: resets the idle timer */

/* ---- events (JSON lines on the event fd) ---- */
void vl_event(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void vl_hex(char *out, const uint8_t *data, size_t n); /* out: 2n+1 */

/* ---- state across resets ---- */
typedef enum { VL_RESET_POR = 1, VL_RESET_PIN, VL_RESET_WDG, VL_RESET_SW } vl_reset_t;
extern vl_reset_t vl_reset_cause;
extern uint32_t vl_bkp[5];
_Noreturn void vl_reset(vl_reset_t next, uint32_t dr4_bits);
_Noreturn void vl_power_off(void);
_Noreturn void vl_power_cut(void); /* exit 43: the controller restarts cold */
void vl_state_load(const char *path, bool power_on);

/* ---- modem (vl_modem.c) ---- */
void vl_modem_init(void);
void vl_modem_tx(const uint8_t *data, size_t n); /* MCU -> modem bytes */
void vl_modem_poll(void);        /* deliver downlink, link loss */
bool vl_modem_rx_pending(void);
bool vl_modem_session(void);     /* MQTT client connected */
void vl_modem_fault(const char *spec);
void vl_modem_shutdown(void);
/* MCU UART receive (vl_hal.c): one byte from the modem */
void vl_uart_rx(uint8_t b);

/* ---- board (vl_board.c) ---- */
void vl_board_init(const char *mram_file, const char *sd_file, const char *flash_file);
void vl_board_power_off(void);
void vl_tap(uint16_t peak_mg);
void vl_sd_power(bool on);
bool vl_int1_high(void);

/* ---- control (vl_main.c) ---- */
void vl_stop(void); /* STOP mode: report and wait for the controller */
void vl_status_event(const char *ev);

#endif
