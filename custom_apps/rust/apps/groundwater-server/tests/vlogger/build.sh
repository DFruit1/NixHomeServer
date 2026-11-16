#!/usr/bin/env bash
# Builds the virtual logger from a firmware 2.2 source tree (read-only).
# Usage: build.sh <firmware project dir> <output dir>
#   <firmware project dir> = .../GWL_Firmware_V2.1/GWL_Firmware_V2.1
# Needs CC (nix gcc), VL_MOSQ_INC and VL_MOSQ_LIB (libmosquitto); run.sh
# sets them. Objects and the binary go to <output dir>; nothing is written
# into the firmware tree.
set -euo pipefail
fw="$(cd "$1" && pwd)"
out="$2"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$out/obj"
if [[ -e "$fw/Core/Inc/gwl_net_config_local.h" ]]; then
  echo "refusing: $fw has a gwl_net_config_local.h (use a git archive snapshot)" >&2
  exit 2
fi
cc="${CC:-cc}"
# Firmware 2.2 sources that run for real (see README.md).
fw_src=(
  Core/Src/app_core.c Core/Src/app_cmd.c Core/Src/gsm_mqtt_app.c Core/Src/sd_card_app.c
  Core/Src/rtc_alarm.c Core/Src/sensors.c Core/Src/flash_config.c Core/Src/sensor_math.c Core/Src/accel_math.c
  Core/Src/gwl_app_events.c Core/Src/gwl_app_sched.c Core/Src/gwl_app_store.c Core/Src/gwl_batch.c
  Core/Src/gwl_json.c Core/Src/gwl_proto.c Core/Src/gwl_records.c Core/Src/gwl_ring.c
  Core/Src/gwl_sdarchive.c Core/Src/gwl_settings.c Core/Src/sd_archive_fatfs.c
  Drivers/BSP/GSM/Src/Quectel_EC21.c Middlewares/Third_Party/FatFs/src/ff.c Middlewares/GUI/Src/gwl_display_layout.c
  Middlewares/GUI/Src/gwl_gfx.c Middlewares/GUI/Src/gwl_gfx_assets.c
)
inc=(-I"$here/c/fakehal" -I"$here/c" -I"$fw/Core/Inc" -I"$fw/Drivers/BSP/GSM/Inc" -I"$fw/Drivers/BSP/MRAM/Inc"
     -I"$fw/Middlewares/Third_Party/FatFs/src" -I"$fw/FATFS/Target" -I"$fw/Middlewares/GUI/Inc")
common=(-std=gnu11 -g -O1 -fno-pie -fno-strict-aliasing -DGWL_DEBUG_BUILD=1 -D_DEFAULT_SOURCE)
objs=()
for s in "${fw_src[@]}"; do
  o="$out/obj/$(basename "${s%.c}").o"
  "$cc" "${common[@]}" -w -include "$here/c/vl_fw_force.h" "${inc[@]}" -c "$fw/$s" -o "$o"
  objs+=("$o")
done
# gwl_vsnprintf only (its snprintf override is linked as vl_fw_snprintf)
"$cc" "${common[@]}" -w -DGWL_SNPRINTF_HOST_TEST "${inc[@]}" -c "$fw/Core/Src/gwl_snprintf.c" -o "$out/obj/gwl_snprintf.o"
objs+=("$out/obj/gwl_snprintf.o")
for s in vl_main vl_hal vl_modem vl_board vl_fw_snprintf; do
  o="$out/obj/$s.o"
  "$cc" "${common[@]}" -Wall -Wextra -Wno-unused-parameter -include "$here/c/vl_net_config.h" \
    -I"$VL_MOSQ_INC" ${VL_CJSON_INC:+-I"$VL_CJSON_INC"} "${inc[@]}" -c "$here/c/$s.c" -o "$o"
  objs+=("$o")
done
"$cc" -no-pie -o "$out/vlogger" "${objs[@]}" -Wl,-T,"$here/c/noinit.ld" \
  -L"$VL_MOSQ_LIB" -Wl,-rpath,"$VL_MOSQ_LIB" -lmosquitto -lm
echo "$out/vlogger"
