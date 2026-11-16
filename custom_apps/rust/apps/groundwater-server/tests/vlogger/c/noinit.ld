/* Keep the firmware's .noinit variables (event latches, the at-most-once
 * command history) in one range the harness saves across warm resets. */
SECTIONS
{
  .noinit : { vl_noinit_start = .; KEEP(*(.noinit)) vl_noinit_end = .; }
}
INSERT AFTER .data;
