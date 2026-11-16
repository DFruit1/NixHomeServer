/* Forced include for the firmware sources only: network settings, and
 * snprintf as the target links it (gwl_snprintf.c's gwl_vsnprintf). */
#include "vl_net_config.h"
#define snprintf vl_fw_snprintf
