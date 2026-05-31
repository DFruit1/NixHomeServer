import type { AccountStatus, AccountStatusPayload } from './types';

type Cleanup = () => void;

const interactiveSelector = 'a, button, input, select, textarea, form, label';
const priorityClassPrefix = 'priority-select-';
const priorityValues = ['high', 'normal', 'low'] as const;

const setText = (element: Element | null, value: string): void => {
  if (element) {
    element.textContent = value;
  }
};

const setVisibility = (element: Element | null, visible: boolean): void => {
  if (element) {
    element.classList.toggle('hidden', !visible);
  }
};

const setOptionalText = (root: ParentNode, selector: string, value?: string | null): void => {
  const element = root.querySelector(selector);
  if (!element) {
    return;
  }
  if (value) {
    element.textContent = value;
    element.classList.remove('hidden');
  } else {
    element.textContent = '';
    element.classList.add('hidden');
  }
};

export const applyDashboardStatusPayload = (doc: Document, payload: AccountStatusPayload): void => {
  const formatter = new Intl.NumberFormat();
  const summary = doc.querySelector('[data-dashboard-summary]');
  if (summary) {
    setText(summary.querySelector('[data-summary-field="archived"]'), formatter.format(payload.totals.archived_message_count));
    setText(summary.querySelector('[data-summary-field="indexed"]'), formatter.format(payload.totals.indexed_message_count));
    setText(summary.querySelector('[data-summary-field="pending"]'), formatter.format(payload.totals.pending_index_count));
    setText(summary.querySelector('[data-summary-field="coverage"]'), `${payload.totals.index_coverage_percent}%`);
  }

  payload.accounts.forEach((account) => applyAccountStatus(doc, account, formatter));
};

export const applyAccountStatus = (doc: Document, account: AccountStatus, formatter = new Intl.NumberFormat()): void => {
  const card = doc.querySelector(`[data-account-id="${account.id}"]`);
  if (!card) {
    return;
  }

  const statusBadge = card.querySelector('[data-status-badge]');
  if (statusBadge) {
    statusBadge.className = `status ${account.status_class}`;
    statusBadge.textContent = account.status_label;
  }

  setText(card.querySelector('[data-index-pill]'), account.index_label);
  setText(card.querySelector('[data-progress-field="archived"]'), formatter.format(account.archived_message_count));
  setText(card.querySelector('[data-progress-field="indexed"]'), formatter.format(account.indexed_message_count));
  setText(card.querySelector('[data-progress-field="pending"]'), formatter.format(account.pending_index_count));
  setText(card.querySelector('[data-progress-field="coverage"]'), `${account.index_coverage_percent}%`);
  setText(card.querySelector('[data-progress-note]'), account.progress_note);
  setOptionalText(card, '[data-overlap-note]', account.overlap_note);
  setText(card.querySelector('[data-last-activity]'), `Last activity ${account.last_activity}`);

  const progressBar = card.querySelector<HTMLElement>('[data-progress-bar]');
  if (progressBar) {
    progressBar.style.width = `${account.index_coverage_percent}%`;
  }

  const syncNotice = card.querySelector('[data-sync-diagnostic]');
  if (syncNotice) {
    const metaParts = [];
    if (account.diagnostic_phase) {
      metaParts.push(`Phase ${account.diagnostic_phase}`);
    }
    if (account.diagnostic_code) {
      metaParts.push(`Code ${account.diagnostic_code}`);
    }
    setVisibility(syncNotice, Boolean(account.diagnostic_summary));
    setOptionalText(syncNotice, '[data-diagnostic-summary]', account.diagnostic_summary);
    setOptionalText(syncNotice, '[data-diagnostic-impact]', account.diagnostic_impact);
    setOptionalText(syncNotice, '[data-diagnostic-action]', account.recommended_action);
    setOptionalText(syncNotice, '[data-diagnostic-meta]', metaParts.length > 0 ? metaParts.join(' · ') : '');
    setText(syncNotice.querySelector('[data-diagnostic-detail]'), account.diagnostic_detail ?? '');

    const detailWrap = syncNotice.querySelector<HTMLDetailsElement>('[data-diagnostic-details]');
    if (detailWrap) {
      detailWrap.open = false;
      detailWrap.classList.toggle('hidden', !account.diagnostic_detail);
    }
  }

  const progressWarning = card.querySelector('[data-progress-warning]');
  if (progressWarning) {
    setVisibility(progressWarning, Boolean(account.progress_warning));
    setOptionalText(progressWarning, '[data-progress-warning-text]', account.progress_warning);
    setOptionalText(progressWarning, '[data-progress-warning-action]', account.progress_warning_action);
    setText(progressWarning.querySelector('[data-progress-warning-detail]'), account.progress_warning_detail ?? '');

    const detailWrap = progressWarning.querySelector<HTMLDetailsElement>('[data-progress-warning-details]');
    if (detailWrap) {
      detailWrap.open = false;
      detailWrap.classList.toggle('hidden', !account.progress_warning_detail);
    }
  }
};

export const setupAttachmentSelection = (doc: Document): Cleanup => {
  const attachmentRows = Array.from(doc.querySelectorAll<HTMLElement>('[data-attachment-row]'));
  const bulkForms = [
    doc.querySelector<HTMLFormElement>('#attachment-download-form'),
    doc.querySelector<HTMLFormElement>('#attachment-paperless-form'),
  ].filter((form): form is HTMLFormElement => Boolean(form));
  const selectedKeys = new Set<string>();
  let selectionAnchor: number | null = null;

  const syncSelectedInputs = (): void => {
    attachmentRows.forEach((row) => {
      const key = row.dataset.attachmentKey ?? '';
      const selected = selectedKeys.has(key);
      row.classList.toggle('attachment-row-selected', selected);
      row.setAttribute('aria-selected', selected ? 'true' : 'false');
    });

    bulkForms.forEach((form) => {
      form.querySelectorAll('input[data-selection-hidden]').forEach((input) => input.remove());
      selectedKeys.forEach((key) => {
        const input = doc.createElement('input');
        input.type = 'hidden';
        input.name = 'attachment_keys';
        input.value = key;
        input.dataset.selectionHidden = 'true';
        form.appendChild(input);
      });
    });
  };

  const setRange = (fromIndex: number, toIndex: number): void => {
    const [start, end] = fromIndex <= toIndex ? [fromIndex, toIndex] : [toIndex, fromIndex];
    selectedKeys.clear();
    attachmentRows.slice(start, end + 1).forEach((row) => {
      if (row.dataset.attachmentKey) {
        selectedKeys.add(row.dataset.attachmentKey);
      }
    });
  };

  const selectRow = (row: HTMLElement, event: MouseEvent | KeyboardEvent): void => {
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
      if (![' ', 'Enter'].includes(event.key)) {
        return;
      }
      event.preventDefault();
      selectRow(row, event);
    };

    row.addEventListener('mousedown', onMouseDown);
    row.addEventListener('click', onClick);
    row.addEventListener('keydown', onKeyDown);
    cleanups.push(() => {
      row.removeEventListener('mousedown', onMouseDown);
      row.removeEventListener('click', onClick);
      row.removeEventListener('keydown', onKeyDown);
    });
  });

  const selectPage = doc.querySelector<HTMLElement>('[data-select-page]');
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
    selectPage.addEventListener('click', onSelectPage);
    cleanups.push(() => selectPage.removeEventListener('click', onSelectPage));
  }

  syncSelectedInputs();
  return () => cleanups.forEach((cleanup) => cleanup());
};

export const setPriorityClass = (select: HTMLSelectElement, value: string): void => {
  priorityValues.forEach((priority) => select.classList.remove(`${priorityClassPrefix}${priority}`));
  select.classList.add(`${priorityClassPrefix}${value}`);
};

export const priorityFailureMessage = (detail: string): string => {
  const reasons = [
    'the login session expired',
    'same-origin protection blocked the request',
    'the sender address or domain could not be validated',
    'the server could not write the priority database',
    'the network connection failed before the change was saved',
  ];
  return [
    'Priority change failed.',
    detail ? `Server response: ${detail}` : '',
    '',
    'Potential reasons:',
    ...reasons.map((reason) => `- ${reason}`),
  ].filter(Boolean).join('\n');
};

export type PrioritySubmitDeps = {
  fetch: typeof fetch;
  assign: (url: string) => void;
  currentPath: () => string;
};

export const submitPriorityChange = async (
  select: HTMLSelectElement,
  deps: PrioritySubmitDeps,
): Promise<{ ok: true } | { ok: false; message: string }> => {
  const previousPriority = select.dataset.previousPriority || 'normal';
  const nextPriority = select.value;
  setPriorityClass(select, nextPriority);
  select.disabled = true;

  const form = new URLSearchParams();
  form.set('sender_kind', select.dataset.senderKind || '');
  form.set('sender_value', select.dataset.senderValue || '');
  form.set('priority', nextPriority);
  form.set('return_to', select.dataset.returnTo || deps.currentPath());

  try {
    const response = await deps.fetch('/sender-priorities', {
      method: 'POST',
      credentials: 'same-origin',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
      },
      body: form,
    });

    let payload: { ok?: boolean; message?: string; return_to?: string } | null = null;
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

    deps.assign(payload.return_to || form.get('return_to') || deps.currentPath());
    return { ok: true };
  } catch (error) {
    select.value = previousPriority;
    setPriorityClass(select, previousPriority);
    select.disabled = false;
    return {
      ok: false,
      message: priorityFailureMessage(error instanceof Error ? error.message : ''),
    };
  }
};
