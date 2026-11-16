/* Virtual logger: fake STM32 HAL (fakehal/stm32g0xx_hal.h) on the world
 * clock. RTC calendar/rtc_alarm_a/backup registers, tick, ADC channels computed
 * from the simulated inputs, GPIO, the modem UART and STOP mode. */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "main.h"
#include "app_globals.h"
#include "gwl_app_sched.h"
#include "vl.h"

GPIO_TypeDef vl_gpioa = {0}, vl_gpiob = {1}, vl_gpioc = {2}, vl_gpiod = {3};
PWR_TypeDef vl_pwr;
const uint16_t vl_vrefint_cal = 1655; /* VREFINT 1.212 V at VDDA 3.000 V */

/* ------------------------------------------------------------------ clock */

static uint64_t mono0_ms, jumped_ms, last_tick_real_ms, last_activity_real_ms;
static int64_t offset_ms; /* world = real UTC + offset */
static long offset_written = -1;
static char offset_path[512];
static bool in_session;
int64_t vl_rtc_delta_ms;

static uint64_t mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static int64_t real_utc_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* libfaketime relative offset ("+<seconds>"), written atomically. */
static void offset_save(void) {
    long s = (long)(offset_ms / 1000);
    if (s == offset_written || !offset_path[0]) return;
    char tmp[600];
    snprintf(tmp, sizeof tmp, "%s.tmp", offset_path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "%+ld\n", s);
    fclose(f);
    if (rename(tmp, offset_path) == 0) offset_written = s;
}

void vl_time_init(const char *path) {
    mono0_ms = mono_ms();
    last_tick_real_ms = last_activity_real_ms = mono0_ms;
    snprintf(offset_path, sizeof offset_path, "%s", path);
    FILE *f = fopen(path, "r");
    long s = 0;
    if (f) {
        if (fscanf(f, "%ld", &s) != 1) s = 0;
        fclose(f);
    }
    offset_ms = (int64_t)s * 1000;
    offset_written = s;
}

uint64_t vl_tick_ms(void) { return mono_ms() - mono0_ms + jumped_ms; }
int64_t vl_world_ms(void) { return real_utc_ms() + offset_ms; }
int64_t vl_rtc_ms(void) { return vl_world_ms() + vl_rtc_delta_ms; }

void vl_jump_ms(uint64_t ms) {
    if (!ms) return;
    jumped_ms += ms;
    offset_ms += (int64_t)ms;
    offset_save();
}

void vl_time_session(bool on) {
    in_session = on;
    last_activity_real_ms = mono_ms();
}
void vl_time_activity(void) { last_activity_real_ms = mono_ms(); }

/* Time passes as the firmware polls: outside a session every poll is 1 ms
 * of simulated time; inside a session time is real, sped up by vl_cfg.ff
 * once the link has been quiet for vl_cfg.idle_grace_ms. */
static void pace(void) {
    uint64_t now = mono_ms();
    uint64_t dt = now - last_tick_real_ms;
    last_tick_real_ms = now;
    if (!in_session) {
        vl_jump_ms(1);
        return;
    }
    if (now - last_activity_real_ms > (uint64_t)vl_cfg.idle_grace_ms && vl_cfg.ff > 1)
        vl_jump_ms(dt * (uint64_t)(vl_cfg.ff - 1));
    struct timespec ts = {0, 200000};
    nanosleep(&ts, NULL);
}

uint32_t HAL_GetTick(void) {
    vl_modem_poll();
    if (!vl_modem_rx_pending()) pace();
    return (uint32_t)vl_tick_ms();
}

void HAL_Delay(uint32_t ms) {
    vl_modem_poll();
    vl_jump_ms(ms);
    vl_modem_poll();
}

void HAL_SuspendTick(void) {}
void HAL_ResumeTick(void) {}

/* -------------------------------------------------------------------- RTC */

/* Reset value of the calendar after a loss of backup power (CubeMX
 * MX_RTC_Init: 2000-01-01 00:00:00). */
#define RTC_RESET_EPOCH 946684800LL

static uint32_t rtc_s(void) {
    int64_t ms = vl_rtc_ms();
    return (uint32_t)(ms / 1000);
}

static void rtc_set_s(uint32_t s) { vl_rtc_delta_ms = (int64_t)s * 1000 - vl_world_ms(); }

HAL_StatusTypeDef HAL_RTC_GetTime(RTC_HandleTypeDef *h, RTC_TimeTypeDef *t, uint32_t fmt) {
    (void)h;
    (void)fmt;
    gwl_civil_t c;
    gwl_civil_from_epoch(rtc_s(), &c);
    memset(t, 0, sizeof *t);
    t->Hours = c.hour;
    t->Minutes = c.minute;
    t->Seconds = c.second;
    return HAL_OK;
}

HAL_StatusTypeDef HAL_RTC_GetDate(RTC_HandleTypeDef *h, RTC_DateTypeDef *d, uint32_t fmt) {
    (void)h;
    (void)fmt;
    gwl_civil_t c;
    gwl_civil_from_epoch(rtc_s(), &c);
    d->Year = (uint8_t)(c.year - 2000u);
    d->Month = c.month;
    d->Date = c.day;
    d->WeekDay = 1;
    return HAL_OK;
}

HAL_StatusTypeDef HAL_RTC_SetTime(RTC_HandleTypeDef *h, RTC_TimeTypeDef *t, uint32_t fmt) {
    (void)h;
    (void)fmt;
    gwl_civil_t c;
    gwl_civil_from_epoch(rtc_s(), &c);
    c.hour = t->Hours;
    c.minute = t->Minutes;
    c.second = t->Seconds;
    rtc_set_s(gwl_epoch_from_civil(&c));
    return HAL_OK;
}

HAL_StatusTypeDef HAL_RTC_SetDate(RTC_HandleTypeDef *h, RTC_DateTypeDef *d, uint32_t fmt) {
    (void)h;
    (void)fmt;
    gwl_civil_t c;
    gwl_civil_from_epoch(rtc_s(), &c);
    c.year = (uint16_t)(2000u + d->Year);
    c.month = d->Month;
    c.day = d->Date;
    rtc_set_s(gwl_epoch_from_civil(&c));
    return HAL_OK;
}

static bool alarm_on;
static RTC_AlarmTypeDef rtc_alarm_a;
static uint32_t alarm_armed_s; /* RTC second when Alarm A was armed */

HAL_StatusTypeDef HAL_RTC_SetAlarm_IT(RTC_HandleTypeDef *h, RTC_AlarmTypeDef *a, uint32_t fmt) {
    (void)h;
    (void)fmt;
    rtc_alarm_a = *a;
    alarm_on = true;
    alarm_armed_s = rtc_s();
    return HAL_OK;
}

HAL_StatusTypeDef HAL_RTC_DeactivateAlarm(RTC_HandleTypeDef *h, uint32_t which) {
    (void)h;
    if (which == RTC_ALARM_A) alarm_on = false;
    return HAL_OK;
}

/* World milliseconds of the next Alarm A match, -1 when none is armed. The
 * RTC sets the alarm flag on the 1 Hz update INTO the matching second, so
 * the match is the first calendar second after the one it was armed in; a
 * match the clock has already passed (the second ticked over between the
 * firmware's last check and STOP) is due now. */
int64_t vl_alarm_world_ms(void) {
    if (!alarm_on) return -1;
    uint32_t day0 = alarm_armed_s - alarm_armed_s % 86400u;
    for (uint32_t k = 0; k < 64; k++) {
        uint32_t cand = day0 + k * 86400u + rtc_alarm_a.AlarmTime.Hours * 3600u + rtc_alarm_a.AlarmTime.Minutes * 60u +
                        rtc_alarm_a.AlarmTime.Seconds;
        gwl_civil_t c;
        gwl_civil_from_epoch(cand, &c);
        if (c.day != rtc_alarm_a.AlarmDateWeekDay || cand <= alarm_armed_s) continue;
        int64_t w = (int64_t)cand * 1000 - vl_rtc_delta_ms;
        return w < vl_world_ms() ? vl_world_ms() : w;
    }
    return -1;
}

uint32_t vl_bkp[5];
uint32_t HAL_RTCEx_BKUPRead(RTC_HandleTypeDef *h, uint32_t reg) {
    (void)h;
    return reg < 5 ? vl_bkp[reg] : 0;
}
void HAL_RTCEx_BKUPWrite(RTC_HandleTypeDef *h, uint32_t reg, uint32_t v) {
    (void)h;
    if (reg < 5) vl_bkp[reg] = v;
}

/* -------------------------------------------------------------------- PWR */

void HAL_PWR_EnterSTOPMode(uint32_t regulator, uint8_t entry) {
    (void)regulator;
    (void)entry;
    vl_stop();
}

/* -------------------------------------------------------------------- ADC */

static uint32_t adc_channel;
static uint16_t adc_raw(void) {
    const uint32_t vdda = 3300, fs = 4095;
    uint32_t mv = 0;
    switch (adc_channel) {
    case ADC_CHANNEL_VREFINT: return (uint16_t)((vl_vrefint_cal * 3000u + vdda / 2u) / vdda);
    case ADC_CHANNEL_7: mv = (uint32_t)(vl_cfg.sensor_ma * 150.0 + 0.5); break;
    case ADC_CHANNEL_4: mv = (uint32_t)vl_cfg.bat_mv * 3300u / 8400u; break;
    case ADC_CHANNEL_8: mv = (uint32_t)vl_cfg.sol_mv * 20000u / 120000u; break;
    default: return 0;
    }
    if (mv > vdda) mv = vdda; /* the Zener clamp / full scale */
    return (uint16_t)((mv * fs + vdda / 2u) / vdda);
}

HAL_StatusTypeDef HAL_ADC_ConfigChannel(ADC_HandleTypeDef *h, ADC_ChannelConfTypeDef *c) {
    (void)h;
    adc_channel = c->Channel;
    return HAL_OK;
}
HAL_StatusTypeDef HAL_ADC_Start(ADC_HandleTypeDef *h) {
    (void)h;
    return HAL_OK;
}
HAL_StatusTypeDef HAL_ADC_PollForConversion(ADC_HandleTypeDef *h, uint32_t timeout) {
    (void)h;
    (void)timeout;
    return vl_cfg.adc_fault ? HAL_ERROR : HAL_OK;
}
uint32_t HAL_ADC_GetValue(ADC_HandleTypeDef *h) {
    (void)h;
    return adc_raw();
}
HAL_StatusTypeDef HAL_ADC_Stop(ADC_HandleTypeDef *h) {
    (void)h;
    return HAL_OK;
}

/* ------------------------------------------------------------------- GPIO */

void HAL_GPIO_WritePin(GPIO_TypeDef *port, uint16_t pin, GPIO_PinState s) {
    if (port == GPIOC && pin == SD_ctrl_Pin) vl_sd_power(s == GPIO_PIN_SET);
}

GPIO_PinState HAL_GPIO_ReadPin(GPIO_TypeDef *port, uint16_t pin) {
    if (port == INT1_GPIO_Port && pin == INT1_Pin) return vl_int1_high() ? GPIO_PIN_SET : GPIO_PIN_RESET;
    return GPIO_PIN_RESET;
}

/* ------------------------------------------------------------------- UART */

static uint8_t *rx_slot;
HAL_StatusTypeDef HAL_UART_Receive_IT(UART_HandleTypeDef *h, uint8_t *d, uint16_t n) {
    (void)n;
    if (h->RxState != HAL_UART_STATE_READY) return HAL_BUSY;
    h->RxState = HAL_UART_STATE_BUSY_RX;
    h->ErrorCode = HAL_UART_ERROR_NONE;
    rx_slot = d;
    return HAL_OK;
}

/* One byte from the modem as HAL_UART_IRQHandler delivers it. */
void vl_uart_rx(uint8_t b) {
    if (huart1.RxState != HAL_UART_STATE_BUSY_RX) {
        vl_event("{\"ev\":\"uart_lost\",\"byte\":%u}", b);
        return;
    }
    huart1.ErrorCode = 0;
    huart1.RxState = HAL_UART_STATE_READY;
    *rx_slot = b;
    HAL_UART_RxCpltCallback(&huart1);
}

HAL_StatusTypeDef HAL_UART_Transmit(UART_HandleTypeDef *h, const uint8_t *d, uint16_t n, uint32_t t) {
    (void)t;
    if (h == &huart1) {
        vl_modem_tx(d, n);
        return HAL_OK;
    }
    fwrite(d, 1, n, stderr); /* console (GWL_LOG) */
    return HAL_OK;
}
