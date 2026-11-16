/* Virtual logger: the STM32G0 HAL surface that the firmware 2.2 application
 * files (app_core.c, app_cmd.c, gsm_mqtt_app.c, sd_card_app.c, rtc_alarm.c,
 * sensors.c) and the Quectel EC21 driver use, implemented by vl_hal.c on a
 * simulated clock, RTC, ADC, GPIO and UART (the UART talks to vl_modem.c).
 * Only what those files need; nothing here is a model of the real chip
 * beyond the behaviour the firmware relies on. */
#ifndef VL_FAKE_STM32G0XX_HAL_H
#define VL_FAKE_STM32G0XX_HAL_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum { HAL_OK = 0, HAL_ERROR = 1, HAL_BUSY = 2, HAL_TIMEOUT = 3 } HAL_StatusTypeDef;

/* ---- UART ---- */
#define HAL_UART_STATE_READY 0x20U
#define HAL_UART_STATE_BUSY_RX 0x22U
#define HAL_UART_ERROR_NONE 0x00U
#define HAL_UART_ERROR_PE 0x01U
#define HAL_UART_ERROR_NE 0x02U
#define HAL_UART_ERROR_FE 0x04U
#define HAL_UART_ERROR_ORE 0x08U
typedef struct { uint32_t RxState; uint32_t ErrorCode; } UART_HandleTypeDef;
HAL_StatusTypeDef HAL_UART_Transmit(UART_HandleTypeDef *h, const uint8_t *data, uint16_t size, uint32_t timeout);
HAL_StatusTypeDef HAL_UART_Receive_IT(UART_HandleTypeDef *h, uint8_t *data, uint16_t size);
void HAL_UART_RxCpltCallback(UART_HandleTypeDef *h);
void HAL_UART_ErrorCallback(UART_HandleTypeDef *h);

/* ---- tick ---- */
uint32_t HAL_GetTick(void);
void HAL_Delay(uint32_t ms);
void HAL_SuspendTick(void);
void HAL_ResumeTick(void);
static inline void __disable_irq(void) {}
static inline void __enable_irq(void) {}

/* ---- GPIO ---- */
typedef struct { uint32_t id; } GPIO_TypeDef;
typedef enum { GPIO_PIN_RESET = 0, GPIO_PIN_SET } GPIO_PinState;
extern GPIO_TypeDef vl_gpioa, vl_gpiob, vl_gpioc, vl_gpiod;
#define GPIOA (&vl_gpioa)
#define GPIOB (&vl_gpiob)
#define GPIOC (&vl_gpioc)
#define GPIOD (&vl_gpiod)
#define GPIO_PIN_0 ((uint16_t)0x0001)
#define GPIO_PIN_1 ((uint16_t)0x0002)
#define GPIO_PIN_2 ((uint16_t)0x0004)
#define GPIO_PIN_3 ((uint16_t)0x0008)
#define GPIO_PIN_4 ((uint16_t)0x0010)
#define GPIO_PIN_6 ((uint16_t)0x0040)
#define GPIO_PIN_7 ((uint16_t)0x0080)
#define GPIO_PIN_9 ((uint16_t)0x0200)
#define GPIO_PIN_10 ((uint16_t)0x0400)
#define GPIO_PIN_11 ((uint16_t)0x0800)
#define GPIO_PIN_13 ((uint16_t)0x2000)
#define EXTI4_15_IRQn 7
#define EXTI0_1_IRQn 5
#define EXTI2_3_IRQn 6
void HAL_GPIO_WritePin(GPIO_TypeDef *port, uint16_t pin, GPIO_PinState state);
GPIO_PinState HAL_GPIO_ReadPin(GPIO_TypeDef *port, uint16_t pin);

/* ---- RTC (calendar, Alarm A, backup registers) ---- */
typedef struct { uint32_t unused; } RTC_HandleTypeDef;
typedef struct {
    uint8_t Hours, Minutes, Seconds, TimeFormat;
    uint32_t SubSeconds, SecondFraction, DayLightSaving, StoreOperation;
} RTC_TimeTypeDef;
typedef struct { uint8_t WeekDay, Month, Date, Year; } RTC_DateTypeDef;
typedef struct {
    RTC_TimeTypeDef AlarmTime;
    uint32_t AlarmMask, AlarmSubSecondMask, AlarmDateWeekDaySel;
    uint8_t AlarmDateWeekDay;
    uint32_t Alarm;
} RTC_AlarmTypeDef;
#define RTC_FORMAT_BIN 0u
#define RTC_DAYLIGHTSAVING_NONE 0u
#define RTC_STOREOPERATION_RESET 0u
#define RTC_WEEKDAY_MONDAY 1u
#define RTC_ALARMMASK_NONE 0u
#define RTC_ALARMSUBSECONDMASK_ALL 0u
#define RTC_ALARMDATEWEEKDAYSEL_DATE 0u
#define RTC_ALARM_A 0x100u
#define RTC_ALARM_B 0x200u
#define RTC_BKP_DR0 0u
#define RTC_BKP_DR1 1u
#define RTC_BKP_DR2 2u
#define RTC_BKP_DR3 3u
#define RTC_BKP_DR4 4u
#define RTC_WAKEUPCLOCK_CK_SPRE_16BITS 4u
HAL_StatusTypeDef HAL_RTC_GetTime(RTC_HandleTypeDef *h, RTC_TimeTypeDef *t, uint32_t fmt);
HAL_StatusTypeDef HAL_RTC_GetDate(RTC_HandleTypeDef *h, RTC_DateTypeDef *d, uint32_t fmt);
HAL_StatusTypeDef HAL_RTC_SetTime(RTC_HandleTypeDef *h, RTC_TimeTypeDef *t, uint32_t fmt);
HAL_StatusTypeDef HAL_RTC_SetDate(RTC_HandleTypeDef *h, RTC_DateTypeDef *d, uint32_t fmt);
HAL_StatusTypeDef HAL_RTC_SetAlarm_IT(RTC_HandleTypeDef *h, RTC_AlarmTypeDef *a, uint32_t fmt);
HAL_StatusTypeDef HAL_RTC_DeactivateAlarm(RTC_HandleTypeDef *h, uint32_t alarm);
void HAL_RTC_AlarmAEventCallback(RTC_HandleTypeDef *h);
uint32_t HAL_RTCEx_BKUPRead(RTC_HandleTypeDef *h, uint32_t reg);
void HAL_RTCEx_BKUPWrite(RTC_HandleTypeDef *h, uint32_t reg, uint32_t value);

/* ---- PWR ---- */
#define PWR_LOWPOWERREGULATOR_ON 1u
#define PWR_STOPENTRY_WFI 1u
void HAL_PWR_EnterSTOPMode(uint32_t regulator, uint8_t entry);

/* ---- ADC (sensors.c runs for real on this) ---- */
typedef struct { uint32_t unused; } ADC_HandleTypeDef;
typedef struct { uint32_t Channel, Rank, SamplingTime; } ADC_ChannelConfTypeDef;
#define ADC_CHANNEL_4 4u
#define ADC_CHANNEL_7 7u
#define ADC_CHANNEL_8 8u
#define ADC_CHANNEL_VREFINT 13u
#define ADC_REGULAR_RANK_1 1u
#define ADC_SAMPLINGTIME_COMMON_1 0u
#define ADC1 ((void *)0)
#define __LL_ADC_COMMON_INSTANCE(x) (x)
#define LL_ADC_PATH_INTERNAL_NONE 0u
static inline void LL_ADC_SetCommonPathInternalCh(void *i, uint32_t p) { (void)i; (void)p; }
extern const uint16_t vl_vrefint_cal;
#define VREFINT_CAL_ADDR (&vl_vrefint_cal)
HAL_StatusTypeDef HAL_ADC_ConfigChannel(ADC_HandleTypeDef *h, ADC_ChannelConfTypeDef *c);
HAL_StatusTypeDef HAL_ADC_Start(ADC_HandleTypeDef *h);
HAL_StatusTypeDef HAL_ADC_PollForConversion(ADC_HandleTypeDef *h, uint32_t timeout);
uint32_t HAL_ADC_GetValue(ADC_HandleTypeDef *h);
HAL_StatusTypeDef HAL_ADC_Stop(ADC_HandleTypeDef *h);

/* ---- other handles main.c defines ---- */
typedef struct { uint32_t unused; } I2C_HandleTypeDef;
typedef struct { uint32_t unused; } SPI_HandleTypeDef;

/* ---- MCU unique ID: the simulated unit's 96-bit UID (vl_board.c) ---- */
extern uint32_t vl_uid[3];
#define UID_BASE ((uintptr_t)vl_uid)

#endif
