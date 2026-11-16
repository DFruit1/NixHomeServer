/* The target links gwl_snprintf.c's snprintf (gwl_vsnprintf: %s %d %u %c
 * %% and 'l' only). Firmware objects call it as vl_fw_snprintf so the
 * harness and libmosquitto keep the C library's. */
#include <stdarg.h>
#include <stddef.h>
#include "gwl_snprintf.h"
int vl_fw_snprintf(char *restrict out, size_t size, const char *restrict fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = gwl_vsnprintf(out, size, fmt, ap);
    va_end(ap);
    return n;
}
