import type { AccountStatus, AccountStatusPayload } from "./types";

type Cleanup = () => void;

const interactiveSelector = "a, button, input, select, textarea, form, label";
const priorityClassPrefix = "priority-select-";
const priorityValues = ["high", "normal", "low"] as const;

const setText = (element: Element | null, value: string): void => {
  if (element) {
    element.textContent = value;
  }
};

const setVisibility = (element: Element | null, visible: boolean): void => {
  if (element) {
    element.classList.toggle("hidden", !visible);
  }
};

const setOptionalText = (
  root: ParentNode,
  selector: string,
  value?: string | null,
): void => {
  const element = root.querySelector(selector);
  if (!element) {
    return;
  }
  if (value) {
    element.textContent = value;
    element.classList.remove("hidden");
  } else {
    element.textContent = "";
    element.classList.add("hidden");
  }
};

const healthState = (
  account: AccountStatus,
  key: string,
): { className: string; title: string } => {
  if (key === "mailbox") {
    if (account.status_class === "error") {
      return { className: "error", title: "Mailbox connection failed" };
    }
    if (account.status_label === "syncing") {
      return {
        className: "active pulse-fast",
        title: "Mailbox connection syncing",
      };
    }
    if (account.status_class === "idle") {
      return { className: "idle", title: "Mailbox connection idle" };
    }
    return { className: "ok", title: "Mailbox connection healthy" };
  }

  if (key === "index") {
    if (
      account.diagnostic_phase === "index" ||
      account.diagnostic_phase === "reconcile"
    ) {
      return {
        className: "warning pulse-slow",
        title: "Search index needs attention",
      };
    }
    if (account.pending_index_count > 0) {
      return {
        className: "warning pulse-slow",
        title: "Search index is catching up",
      };
    }
    if (account.index_label !== "Indexed") {
      return { className: "idle", title: "Search index has not been built" };
    }
    return { className: "ok", title: "Search index healthy" };
  }

  if (key === "storage") {
    if (account.progress_warning || account.diagnostic_phase === "metrics") {
      return {
        className: "warning pulse-slow",
        title: "Archive storage needs attention",
      };
    }
    return { className: "ok", title: "Archive storage healthy" };
  }

  if (key === "paperless") {
    if (account.progress_warning_detail?.toLowerCase().includes("paperless")) {
      return {
        className: "warning pulse-slow",
        title: "Paperless handoff needs attention",
      };
    }
    return { className: "ok", title: "Paperless handoff ready" };
  }

  if (key === "sync" && account.status_label === "syncing") {
    return { className: "active pulse-fast", title: "Sync is running" };
  }
  if (key === "sync" && account.status_class === "error") {
    return { className: "error", title: "Last sync failed" };
  }
  return { className: "ok", title: "Automatic sync is scheduled" };
};

const updateHealthLights = (card: Element, account: AccountStatus): void => {
  card
    .querySelectorAll<HTMLElement>("[data-health-light]")
    .forEach((element) => {
      const key = element.dataset.healthLight;
      if (!key) {
        return;
      }
      const state = healthState(account, key);
      element.className = `health-light ${state.className}`;
      element.title = state.title;
      const label = key.charAt(0).toUpperCase() + key.slice(1);
      element.setAttribute("aria-label", `${label}: ${state.title}`);
    });
};

export const showToast = (
  doc: Document,
  message: string,
  kind: "success" | "error",
): void => {
  if (!message) {
    return;
  }

  let stack = doc.querySelector<HTMLElement>(".toast-stack");
  if (!stack) {
    stack = doc.createElement("div");
    stack.className = "toast-stack";
    stack.setAttribute("aria-live", "polite");
    stack.setAttribute("aria-atomic", "true");
    doc.body.prepend(stack);
  }

  const toast = doc.createElement("div");
  toast.className = `toast ${kind}`;
  toast.setAttribute("role", kind === "error" ? "alert" : "status");
  toast.textContent = message;
  stack.appendChild(toast);
};

export const applyDashboardStatusPayload = (
  doc: Document,
  payload: AccountStatusPayload,
): void => {
  const formatter = new Intl.NumberFormat();
  const summary = doc.querySelector("[data-dashboard-summary]");
  if (summary) {
    setText(
      summary.querySelector('[data-summary-field="archived"]'),
      formatter.format(payload.totals.archived_message_count),
    );
    setText(
      summary.querySelector('[data-summary-field="indexed"]'),
      formatter.format(payload.totals.indexed_message_count),
    );
    setText(
      summary.querySelector('[data-summary-field="pending"]'),
      formatter.format(payload.totals.pending_index_count),
    );
    setText(
      summary.querySelector('[data-summary-field="coverage"]'),
      `${payload.totals.index_coverage_percent}%`,
    );
  }

  payload.accounts.forEach((account) =>
    applyAccountStatus(doc, account, formatter),
  );
};

export const applyAccountStatus = (
  doc: Document,
  account: AccountStatus,
  formatter = new Intl.NumberFormat(),
): void => {
  const card = doc.querySelector(`[data-account-id="${account.id}"]`);
  if (!card) {
    return;
  }

  const statusBadge = card.querySelector("[data-status-badge]");
  if (statusBadge) {
    statusBadge.className = `status ${account.status_class}`;
    statusBadge.textContent = account.status_label;
  }

  setText(card.querySelector("[data-index-pill]"), account.index_label);
  setText(
    card.querySelector('[data-progress-field="archived"]'),
    formatter.format(account.archived_message_count),
  );
  setText(
    card.querySelector('[data-progress-field="indexed"]'),
    formatter.format(account.indexed_message_count),
  );
  setText(
    card.querySelector('[data-progress-field="pending"]'),
    formatter.format(account.pending_index_count),
  );
  setText(
    card.querySelector('[data-progress-field="coverage"]'),
    `${account.index_coverage_percent}%`,
  );
  setText(card.querySelector("[data-progress-note]"), account.progress_note);
  setOptionalText(card, "[data-overlap-note]", account.overlap_note);
  setText(card.querySelector("[data-last-activity]"), account.last_activity);
  updateHealthLights(card, account);

  const progressBar = card.querySelector<HTMLElement>("[data-progress-bar]");
  if (progressBar) {
    progressBar.style.width = `${account.index_coverage_percent}%`;
  }

  const syncNotice = card.querySelector("[data-sync-diagnostic]");
  if (syncNotice) {
    const metaParts = [];
    if (account.diagnostic_phase) {
      metaParts.push(`Phase ${account.diagnostic_phase}`);
    }
    if (account.diagnostic_code) {
      metaParts.push(`Code ${account.diagnostic_code}`);
    }
    setVisibility(syncNotice, Boolean(account.diagnostic_summary));
    setOptionalText(
      syncNotice,
      "[data-diagnostic-summary]",
      account.diagnostic_summary,
    );
    setOptionalText(
      syncNotice,
      "[data-diagnostic-impact]",
      account.diagnostic_impact,
    );
    setOptionalText(
      syncNotice,
      "[data-diagnostic-action]",
      account.recommended_action,
    );
    setOptionalText(
      syncNotice,
      "[data-diagnostic-meta]",
      metaParts.length > 0 ? metaParts.join(" · ") : "",
    );
    setText(
      syncNotice.querySelector("[data-diagnostic-detail]"),
      account.diagnostic_detail ?? "",
    );

    const detailWrap = syncNotice.querySelector<HTMLDetailsElement>(
      "[data-diagnostic-details]",
    );
    if (detailWrap) {
      detailWrap.open = false;
      detailWrap.classList.toggle("hidden", !account.diagnostic_detail);
    }
  }

  const progressWarning = card.querySelector("[data-progress-warning]");
  if (progressWarning) {
    setVisibility(progressWarning, Boolean(account.progress_warning));
    setOptionalText(
      progressWarning,
      "[data-progress-warning-text]",
      account.progress_warning,
    );
    setOptionalText(
      progressWarning,
      "[data-progress-warning-action]",
      account.progress_warning_action,
    );
    setText(
      progressWarning.querySelector("[data-progress-warning-detail]"),
      account.progress_warning_detail ?? "",
    );

    const detailWrap = progressWarning.querySelector<HTMLDetailsElement>(
      "[data-progress-warning-details]",
    );
    if (detailWrap) {
      detailWrap.open = false;
      detailWrap.classList.toggle("hidden", !account.progress_warning_detail);
    }
  }
};

export const setupAttachmentSelection = (doc: Document): Cleanup => {
  const attachmentRows = Array.from(
    doc.querySelectorAll<HTMLElement>("[data-attachment-row]"),
  );
  const bulkForms = [
    doc.querySelector<HTMLFormElement>("#attachment-download-form"),
    doc.querySelector<HTMLFormElement>("#attachment-paperless-form"),
  ].filter((form): form is HTMLFormElement => Boolean(form));
  const selectedKeys = new Set<string>();
  let selectionAnchor: number | null = null;

  const syncSelectedInputs = (): void => {
    const selectedCount = selectedKeys.size;
    setText(
      doc.querySelector("[data-selected-count]"),
      `${selectedCount} selected`,
    );
    doc
      .querySelectorAll<HTMLButtonElement>("[data-bulk-action]")
      .forEach((button) => {
        button.disabled = selectedCount === 0;
      });

    attachmentRows.forEach((row) => {
      const key = row.dataset.attachmentKey ?? "";
      const selected = selectedKeys.has(key);
      row.classList.toggle("attachment-row-selected", selected);
      row.setAttribute("aria-selected", selected ? "true" : "false");
    });

    bulkForms.forEach((form) => {
      form
        .querySelectorAll("input[data-selection-hidden]")
        .forEach((input) => input.remove());
      selectedKeys.forEach((key) => {
        const input = doc.createElement("input");
        input.type = "hidden";
        input.name = "attachment_keys";
        input.value = key;
        input.dataset.selectionHidden = "true";
        form.appendChild(input);
      });
    });
  };

  const setRange = (fromIndex: number, toIndex: number): void => {
    const [start, end] =
      fromIndex <= toIndex ? [fromIndex, toIndex] : [toIndex, fromIndex];
    selectedKeys.clear();
    attachmentRows.slice(start, end + 1).forEach((row) => {
      if (row.dataset.attachmentKey) {
        selectedKeys.add(row.dataset.attachmentKey);
      }
    });
  };

  const selectRow = (
    row: HTMLElement,
    event: MouseEvent | KeyboardEvent,
  ): void => {
    const key = row.dataset.attachmentKey;
    if (!key) {
      return;
    }
    const index = attachmentRows.indexOf(row);

    if (event.shiftKey && selectionAnchor !== null) {
      setRange(selectionAnchor, index);
    } else if (event.ctrlKey || event.metaKey) {
      if (selectedKeys.has(key)) {
        selectedKeys.delete(key);
      } else {
        selectedKeys.add(key);
      }
      selectionAnchor = index;
    } else {
      selectedKeys.clear();
      selectedKeys.add(key);
      selectionAnchor = index;
    }

    syncSelectedInputs();
  };

  const cleanups: Cleanup[] = [];
  attachmentRows.forEach((row) => {
    const onMouseDown = (event: MouseEvent): void => {
      if ((event.target as Element).closest(interactiveSelector)) {
        return;
      }
      if (event.shiftKey || event.ctrlKey || event.metaKey) {
        event.preventDefault();
      }
    };
    const onClick = (event: MouseEvent): void => {
      if ((event.target as Element).closest(interactiveSelector)) {
        return;
      }
      selectRow(row, event);
    };
    const onKeyDown = (event: KeyboardEvent): void => {
      if (![" ", "Enter"].includes(event.key)) {
        return;
      }
      event.preventDefault();
      selectRow(row, event);
    };

    row.addEventListener("mousedown", onMouseDown);
    row.addEventListener("click", onClick);
    row.addEventListener("keydown", onKeyDown);
    cleanups.push(() => {
      row.removeEventListener("mousedown", onMouseDown);
      row.removeEventListener("click", onClick);
      row.removeEventListener("keydown", onKeyDown);
    });
  });

  const selectPage = doc.querySelector<HTMLElement>("[data-select-page]");
  if (selectPage) {
    const onSelectPage = (): void => {
      selectedKeys.clear();
      attachmentRows.forEach((row) => {
        if (row.dataset.attachmentKey) {
          selectedKeys.add(row.dataset.attachmentKey);
        }
      });
      selectionAnchor = attachmentRows.length > 0 ? 0 : null;
      syncSelectedInputs();
    };
    selectPage.addEventListener("click", onSelectPage);
    cleanups.push(() => selectPage.removeEventListener("click", onSelectPage));
  }

  const paperlessForms = Array.from(
    doc.querySelectorAll<HTMLFormElement>("form[data-paperless-form]"),
  );
  paperlessForms.forEach((form) => {
    const onSubmit = (event: SubmitEvent): void => {
      event.preventDefault();
      submitPaperlessForm(form, {
        fetch: window.fetch.bind(window),
        doc,
      }).then((result) => {
        if (result.ok) {
          result.sentAttachmentKeys.forEach((key) => selectedKeys.delete(key));
          syncSelectedInputs();
          showToast(doc, result.message, "success");
          if (result.error) {
            showToast(doc, result.error, "error");
          }
        } else {
          showToast(doc, result.message, "error");
        }
      });
    };
    form.addEventListener("submit", onSubmit);
    cleanups.push(() => form.removeEventListener("submit", onSubmit));
  });

  const refreshForm = doc.querySelector<HTMLFormElement>(
    "form[data-refresh-attachments-form]",
  );
  if (refreshForm) {
    const onSubmit = (event: SubmitEvent): void => {
      event.preventDefault();
      submitJsonAction(refreshForm, {
        fetch: window.fetch.bind(window),
        doc,
      }).then((result) => {
        showToast(doc, result.message, result.ok ? "success" : "error");
      });
    };
    refreshForm.addEventListener("submit", onSubmit);
    cleanups.push(() => refreshForm.removeEventListener("submit", onSubmit));
  }

  syncSelectedInputs();
  return () => cleanups.forEach((cleanup) => cleanup());
};

type ActionPayload = {
  ok?: boolean;
  message?: string;
  account_id?: number | null;
};

type JsonActionDeps = {
  fetch: typeof fetch;
  doc: Document;
};

const urlEncodedFormBody = (form: HTMLFormElement): URLSearchParams => {
  const body = new URLSearchParams();
  new FormData(form).forEach((value, key) => {
    if (typeof value === "string") {
      body.append(key, value);
    }
  });
  return body;
};

export const submitJsonAction = async (
  form: HTMLFormElement,
  deps: JsonActionDeps,
): Promise<{ ok: boolean; message: string }> => {
  const buttons = Array.from(
    form.querySelectorAll<HTMLButtonElement>("button"),
  );
  buttons.forEach((button) => {
    button.disabled = true;
    button.dataset.previousLabel = button.textContent || "";
    button.textContent = "...";
  });

  try {
    const response = await deps.fetch(form.action, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
      },
      body: urlEncodedFormBody(form),
    });
    const responseText = await response.text();
    let payload: ActionPayload | null = null;
    if (responseText) {
      try {
        payload = JSON.parse(responseText) as ActionPayload;
      } catch {
        payload = { message: responseText };
      }
    }
    const ok = response.ok && Boolean(payload?.ok);
    return {
      ok,
      message:
        payload?.message ||
        (ok ? "Action completed" : `Request failed with ${response.status}`),
    };
  } catch (error) {
    return {
      ok: false,
      message: error instanceof Error ? error.message : "Request failed",
    };
  } finally {
    buttons.forEach((button) => {
      button.disabled = false;
      button.textContent = button.dataset.previousLabel || "";
      delete button.dataset.previousLabel;
    });
  }
};

export const setupDashboardActions = (doc: Document): Cleanup => {
  const forms = Array.from(
    doc.querySelectorAll<HTMLFormElement>("form[data-dashboard-action]"),
  );
  const cleanups: Cleanup[] = [];

  forms.forEach((form) => {
    const onSubmit = (event: SubmitEvent): void => {
      event.preventDefault();
      submitJsonAction(form, {
        fetch: window.fetch.bind(window),
        doc,
      }).then((result) => {
        showToast(doc, result.message, result.ok ? "success" : "error");
        if (result.ok) {
          window
            .fetch("/api/accounts/status", {
              cache: "no-store",
              headers: { Accept: "application/json" },
            })
            .then((response) => (response.ok ? response.json() : null))
            .then((payload: AccountStatusPayload | null) => {
              if (payload) {
                applyDashboardStatusPayload(doc, payload);
              }
            })
            .catch(() => undefined);
        }
      });
    };
    form.addEventListener("submit", onSubmit);
    cleanups.push(() => form.removeEventListener("submit", onSubmit));
  });

  return () => cleanups.forEach((cleanup) => cleanup());
};

type PaperlessPayload = {
  ok?: boolean;
  message?: string;
  error?: string | null;
  sent_attachment_keys?: string[];
  return_to?: string | null;
};

type PaperlessSubmitDeps = {
  fetch: typeof fetch;
  doc: Document;
};

type PaperlessSubmitResult =
  | {
      ok: true;
      message: string;
      error?: string | null;
      sentAttachmentKeys: string[];
    }
  | { ok: false; message: string };

export const submitPaperlessForm = async (
  form: HTMLFormElement,
  deps: PaperlessSubmitDeps,
): Promise<PaperlessSubmitResult> => {
  const buttons = Array.from(
    form.querySelectorAll<HTMLButtonElement>("button"),
  );
  buttons.forEach((button) => {
    button.disabled = true;
    button.dataset.previousLabel = button.textContent || "";
    button.textContent = "…";
  });

  try {
    const response = await deps.fetch(form.action, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
      },
      body: urlEncodedFormBody(form),
    });
    const responseText = await response.text();
    let payload: PaperlessPayload | null = null;
    if (responseText) {
      try {
        payload = JSON.parse(responseText) as PaperlessPayload;
      } catch {
        payload = { message: responseText };
      }
    }

    if (!response.ok || !payload?.ok) {
      throw new Error(
        payload?.error || payload?.message || `HTTP ${response.status}`,
      );
    }

    const sentAttachmentKeys = payload.sent_attachment_keys || [];
    markAttachmentsSent(deps.doc, sentAttachmentKeys);
    return {
      ok: true,
      message: payload.message || "Attachments sent to Paperless",
      error: payload.error,
      sentAttachmentKeys,
    };
  } catch (error) {
    return {
      ok: false,
      message:
        error instanceof Error
          ? error.message
          : "Paperless handoff request failed",
    };
  } finally {
    buttons.forEach((button) => {
      button.disabled = false;
      button.textContent = button.dataset.previousLabel || "→";
      delete button.dataset.previousLabel;
    });
  }
};

const markAttachmentsSent = (doc: Document, attachmentKeys: string[]): void => {
  attachmentKeys.forEach((key) => {
    const row = doc.querySelector<HTMLElement>(
      `[data-attachment-row][data-attachment-key="${cssEscape(key)}"]`,
    );
    const form = row?.querySelector<HTMLFormElement>(
      "form[data-paperless-form]",
    );
    if (!row || !form) {
      return;
    }

    const button = doc.createElement("button");
    button.className = "icon-button paperless-sent-button";
    button.type = "button";
    button.title = "Successfully sent to Paperless";
    button.setAttribute("aria-label", "Successfully sent to Paperless");
    button.dataset.paperlessSentButton = "true";
    button.textContent = "✓";
    form.replaceWith(button);
  });
};

const cssEscape = (value: string): string => {
  if (typeof window.CSS?.escape === "function") {
    return window.CSS.escape(value);
  }
  return value.replace(/["\\]/g, "\\$&");
};

export const setPriorityClass = (
  select: HTMLSelectElement,
  value: string,
): void => {
  priorityValues.forEach((priority) =>
    select.classList.remove(`${priorityClassPrefix}${priority}`),
  );
  select.classList.add(`${priorityClassPrefix}${value}`);
};

export const priorityFailureMessage = (detail: string): string => {
  const reasons = [
    "the login session expired",
    "same-origin protection blocked the request",
    "the sender address or domain could not be validated",
    "the server could not write the priority database",
    "the network connection failed before the change was saved",
  ];
  return [
    "Sender importance change failed.",
    detail ? `Server response: ${detail}` : "",
    "",
    "Potential reasons:",
    ...reasons.map((reason) => `- ${reason}`),
  ]
    .filter(Boolean)
    .join("\n");
};

export type PrioritySubmitDeps = {
  fetch: typeof fetch;
  currentPath: () => string;
};

export const submitPriorityChange = async (
  select: HTMLSelectElement,
  deps: PrioritySubmitDeps,
): Promise<{ ok: true; message: string } | { ok: false; message: string }> => {
  const previousPriority = select.dataset.previousPriority || "normal";
  const nextPriority = select.value;
  setPriorityClass(select, nextPriority);
  select.disabled = true;

  const form = new URLSearchParams();
  form.set("sender_kind", select.dataset.senderKind || "");
  form.set("sender_value", select.dataset.senderValue || "");
  form.set("priority", nextPriority);
  form.set("return_to", select.dataset.returnTo || deps.currentPath());

  try {
    const response = await deps.fetch("/sender-priorities", {
      method: "POST",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
      },
      body: form,
    });

    let payload: { ok?: boolean; message?: string; return_to?: string } | null =
      null;
    const responseText = await response.text();
    if (responseText) {
      try {
        payload = JSON.parse(responseText) as typeof payload;
      } catch {
        payload = { message: responseText };
      }
    }

    if (!response.ok || !payload || !payload.ok) {
      throw new Error(payload?.message || `HTTP ${response.status}`);
    }

    select.dataset.previousPriority = nextPriority;
    select.disabled = false;
    return { ok: true, message: payload.message || "Sender importance saved" };
  } catch (error) {
    select.value = previousPriority;
    setPriorityClass(select, previousPriority);
    select.disabled = false;
    return {
      ok: false,
      message: priorityFailureMessage(
        error instanceof Error ? error.message : "",
      ),
    };
  }
};
