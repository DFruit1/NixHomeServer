// Revision 2 command operations: help text and argument forms.

export const OP_HELP: Record<string, string> = {
  self_test: "Run a self-test; the result arrives on Tests.",
  get_status: "Health plus ring pointers (head, tail, saved ends, last seq).",
  get_settings: "Report the effective settings and generation.",
  get_debug:
    "Firmware/runtime details: reset cause and flags, watchdog resets, the ring's boot report, modem state, free RAM. Queued automatically after an unexpected reset.",
  flush_mqtt:
    "Send unsaved frames now, or resend a sequence range from MRAM/SD.",
  flush_sd: "Save unsaved frames to the SD archive now.",
  file_list:
    "List a directory page on the SD card (16 entries per page); any absolute 8.3 path up to 63 bytes.",
  file_chunk:
    "Fetch one chunk of an SD file, any absolute 8.3 path up to 63 bytes (Files starts whole downloads).",
  clear_error_latch: "Clear the latched error and SD/MRAM fault states.",
  enable_logging: "Resume logging after disable_logging.",
  sync_time:
    "Set the logger clock; the server inserts the time when it publishes.",
  reboot:
    "Restart the logger at the end of its listen window. No nonce handshake.",
  wipe_sd: "Delete /GWL/ on the SD card.",
  wipe_mram: "Start a new log; unsaved ring data is lost.",
  factory_reset: "As wipe_mram plus default settings.",
  recover_mram: "Rebuild the ring from its RECOVERY area.",
  disable_logging: "Stop logging until enable_logging.",
  erase_keys: "Credentials are build-time in firmware 2.2.",
  rotate_keys: "Credentials are build-time in firmware 2.2.",
  enter_bootloader:
    "Reset into the STM32 UART bootloader. Recovery needs site access.",
  firmware_update: "Not implemented by firmware 2.2.",
};

export function opArgs(op: string, args: Record<string, string>) {
  const errors: string[] = [];
  const int = (key: string, min: number, max: number) => {
    const text = (args[key] ?? "").trim();
    const value = /^\d+$/.test(text) ? Number(text) : NaN;
    if (!Number.isInteger(value) || value < min || value > max)
      errors.push(`${key} must be a whole number from ${min} to ${max}.`);
    return value;
  };
  if (op === "flush_mqtt") {
    const keys = ["log_id", "from_seq", "to_seq"];
    const given = keys.filter((k) => (args[k] ?? "").trim() !== "");
    if (given.length === 0) return { args: {}, errors };
    if (given.length !== 3) {
      errors.push(
        "A resend range needs log_id, from_seq and to_seq (or none of them).",
      );
      return { args: {}, errors };
    }
    const value = {
      log_id: int("log_id", 0, 4294967295),
      from_seq: int("from_seq", 0, 4294967295),
      to_seq: int("to_seq", 0, 4294967295),
    };
    if (!errors.length && value.from_seq > value.to_seq)
      errors.push("from_seq must not exceed to_seq.");
    return { args: value, errors };
  }
  if (op === "file_list") {
    const path = (args.path ?? "/GWL").trim() || "/GWL";
    if (!path.startsWith("/")) errors.push("path must start with /.");
    if (new TextEncoder().encode(path).length > 63)
      errors.push("path must be at most 63 bytes.");
    return { args: { path, page: int("page", 0, 65535) }, errors };
  }
  if (op === "file_chunk") {
    const path = (args.path ?? "").trim();
    if (!path.startsWith("/")) errors.push("path must be an absolute SD path.");
    if (new TextEncoder().encode(path).length > 63)
      errors.push("path must be at most 63 bytes.");
    return {
      args: { path, off: int("off", 0, 4294967295), len: int("len", 1, 1024) },
      errors,
    };
  }
  return { args: {}, errors };
}

/** Who queued a command, for anything the server queued by itself. */
export const ORIGIN_TEXT: Record<string, string> = {
  "auto-settings": "automatic: fetch settings",
  "auto-gap": "automatic: resend missing data",
  "auto-clock": "automatic: set the clock",
  "auto-confirm": "automatic: confirm (no unsaved data)",
  "auto-restore": "automatic: restore lost settings",
  "auto-debug": "automatic: boot report after an unexpected reset",
  download: "file download",
};
export const originText = (origin: string | null | undefined) =>
  !origin || origin === "operator" ? "" : ORIGIN_TEXT[origin] || origin;

/** The command list holds the server's newest 500 commands. */
