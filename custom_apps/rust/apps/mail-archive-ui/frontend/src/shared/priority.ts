const priorityClassPrefix = "priority-select-";
const priorityValues = ["high", "normal", "low"] as const;

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
