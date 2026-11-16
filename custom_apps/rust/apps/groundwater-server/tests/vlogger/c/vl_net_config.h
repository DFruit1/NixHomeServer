/* Virtual logger build: network settings for the firmware sources (forced
 * include). Never the developer's gwl_net_config_local.h. The broker
 * address is what the firmware sends in AT+QMTOPEN; the emulator connects
 * to the test broker given on its command line instead. Credentials are the
 * ones AT+QMTCONN carries unless vlogger --user/--pass override them. */
#define GWL_NET_CONFIG_SKIP_LOCAL 1
#define GWL_NET_PROFILE "vlogger"
#define GWL_MQTT_HOST "broker.vlogger.test"
#define GWL_MQTT_PORT 8883
#ifndef GWL_MQTT_USERNAME
#define GWL_MQTT_USERNAME "groundwater-logger"
#endif
#ifndef GWL_MQTT_PASSWORD
#define GWL_MQTT_PASSWORD "vlogger-test-password"
#endif
