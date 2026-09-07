import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  DISMISS_ROW_ANIMATION_MS,
  setupAttachmentSelection,
  setupMailList,
} from "../shared/dom";

const attachmentRow = (key: string) => `
  <article data-attachment-row data-attachment-key="${key}" tabindex="0">
    <div class="row-actions">
      <span class="row-menu-anchor" data-row-menu-anchor>
        <button class="row-menu-button" type="button" data-row-menu-button aria-expanded="false">&#8230;</button>
        <span class="row-menu" data-row-menu hidden>
          <form method="post" action="/attachments/dismiss" data-row-action-form data-row-action="dismiss">
            <input type="hidden" name="attachment_keys" value="${key}">
            <button type="submit">Dismiss attachment</button>
          </form>
          <form method="post" action="/attachments/restore" data-row-action-form data-row-action="restore" class="hidden">
            <input type="hidden" name="attachment_keys" value="${key}">
            <button type="submit">Restore attachment</button>
          </form>
        </span>
      </span>
    </div>
  </article>
`;

const mailRow = (key: string, dismissed = false) => `
  <article class="mail-row${dismissed ? " mail-row-dismissed" : ""}" data-mail-row data-account-id="4" data-message-key="${key}">
    <div class="row-actions">
      <span class="row-menu-anchor" data-row-menu-anchor>
        <button class="row-menu-button" type="button" data-row-menu-button aria-expanded="false">&#8230;</button>
        <span class="row-menu" data-row-menu hidden>
          <form method="post" action="/messages/dismiss" data-row-action-form data-row-action="dismiss"${dismissed ? ' class="hidden"' : ""}>
            <input type="hidden" name="account_id" value="4">
            <input type="hidden" name="message_key" value="${key}">
            <button type="submit">Dismiss message</button>
          </form>
          <form method="post" action="/messages/restore" data-row-action-form data-row-action="restore"${dismissed ? "" : ' class="hidden"'}>
            <input type="hidden" name="account_id" value="4">
            <input type="hidden" name="message_key" value="${key}">
            <button type="submit">Restore message</button>
          </form>
        </span>
      </span>
    </div>
  </article>
`;

describe("row menus", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    document.body.innerHTML = "";
  });

  it("opens the floating menu, closes it on outside click, and swaps open menus", () => {
    document.body.innerHTML = attachmentRow("first") + attachmentRow("second");
    const cleanup = setupAttachmentSelection(document);

    const buttons = document.querySelectorAll<HTMLButtonElement>(
      "[data-row-menu-button]",
    );
    const menus = document.querySelectorAll<HTMLElement>("[data-row-menu]");

    buttons[0]?.click();
    expect(menus[0]?.hidden).toBe(false);
    expect(buttons[0]?.getAttribute("aria-expanded")).toBe("true");

    buttons[1]?.click();
    expect(menus[0]?.hidden).toBe(true);
    expect(menus[1]?.hidden).toBe(false);

    document.body.click();
    expect(menus[1]?.hidden).toBe(true);

    const escape = new KeyboardEvent("keydown", {
      key: "Escape",
      bubbles: true,
    });
    buttons[0]?.click();
    document.dispatchEvent(escape);
    expect(menus[0]?.hidden).toBe(true);
    cleanup();
  });

  it("dismisses an attachment row: posts, fades the card out, and removes it", async () => {
    document.body.innerHTML = attachmentRow("first") + attachmentRow("second");
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL) =>
        new Response(
          JSON.stringify({ ok: true, message: "Attachment dismissed" }),
          {
            status: 200,
          },
        ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const cleanup = setupAttachmentSelection(document);

    const rows = document.querySelectorAll<HTMLElement>(
      "[data-attachment-row]",
    );
    const first = rows[0] as HTMLElement;
    const menu = first.querySelector<HTMLElement>("[data-row-menu]")!;
    menu.hidden = false;
    const form = first.querySelector<HTMLFormElement>(
      'form[data-row-action="dismiss"]',
    )!;
    form.dispatchEvent(
      new SubmitEvent("submit", { bubbles: true, cancelable: true }),
    );

    await vi.runAllTimersAsync();

    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining("/attachments/dismiss"),
      expect.objectContaining({ method: "POST" }),
    );
    expect(document.querySelectorAll("[data-attachment-row]")).toHaveLength(1);
    expect(document.querySelector(".toast.success")?.textContent).toBe(
      "Attachment dismissed",
    );
    cleanup();
    vi.unstubAllGlobals();
  });

  it("starts the dismissal collapse with the row height committed before collapsing", async () => {
    document.body.innerHTML = attachmentRow("first");
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL) =>
        new Response(
          JSON.stringify({ ok: true, message: "Attachment dismissed" }),
          {
            status: 200,
          },
        ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const cleanup = setupAttachmentSelection(document);
    const row = document.querySelector<HTMLElement>("[data-attachment-row]")!;
    const form = row.querySelector<HTMLFormElement>(
      'form[data-row-action="dismiss"]',
    )!;

    form.dispatchEvent(
      new SubmitEvent("submit", { bubbles: true, cancelable: true }),
    );
    await vi.advanceTimersByTimeAsync(0);

    expect(row.classList.contains("row-dismissing")).toBe(true);
    expect(row.style.overflow).toBe("hidden");
    expect(row.style.height).toBe("0px");
    expect(row.style.paddingTop).toBe("0px");
    expect(row.style.borderTopWidth).toBe("0px");

    vi.advanceTimersByTime(DISMISS_ROW_ANIMATION_MS - 1);
    expect(document.querySelector("[data-attachment-row]")).not.toBeNull();
    vi.advanceTimersByTime(1);
    expect(document.querySelector("[data-attachment-row]")).toBeNull();
    cleanup();
    vi.unstubAllGlobals();
  });

  it("restores a dismissed message in place", async () => {
    document.body.innerHTML = mailRow("noise@example.com", true);
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL) =>
        new Response(
          JSON.stringify({ ok: true, message: "Message restored" }),
          {
            status: 200,
          },
        ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const cleanup = setupMailList(document);

    const row = document.querySelector<HTMLElement>("[data-mail-row]")!;
    const form = row.querySelector<HTMLFormElement>(
      'form[data-row-action="restore"]',
    )!;
    form.dispatchEvent(
      new SubmitEvent("submit", { bubbles: true, cancelable: true }),
    );

    await vi.runAllTimersAsync();

    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining("/messages/restore"),
      expect.objectContaining({ method: "POST" }),
    );
    expect(row.classList.contains("mail-row-dismissed")).toBe(false);
    expect(row.querySelector("[data-dismissed-badge]")).toBeNull();
    const dismissForm = row.querySelector<HTMLFormElement>(
      'form[data-row-action="dismiss"]',
    )!;
    const restoreForm = row.querySelector<HTMLFormElement>(
      'form[data-row-action="restore"]',
    )!;
    expect(dismissForm.classList.contains("hidden")).toBe(false);
    expect(restoreForm.classList.contains("hidden")).toBe(true);
    expect(document.querySelector("[data-mail-row]")).not.toBeNull();
    cleanup();
    vi.unstubAllGlobals();
  });

  it("shows an error toast without removing the row when dismissal fails", async () => {
    document.body.innerHTML = attachmentRow("first");
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL) =>
        new Response(
          JSON.stringify({ ok: false, message: "dismissal failed" }),
          { status: 400 },
        ),
    );
    vi.stubGlobal("fetch", fetchMock);
    const cleanup = setupAttachmentSelection(document);

    const row = document.querySelector<HTMLElement>("[data-attachment-row]")!;
    const form = row.querySelector<HTMLFormElement>(
      'form[data-row-action="dismiss"]',
    )!;
    form.dispatchEvent(
      new SubmitEvent("submit", { bubbles: true, cancelable: true }),
    );

    await vi.runAllTimersAsync();

    expect(row.isConnected).toBe(true);
    expect(row.classList.contains("row-dismissing")).toBe(false);
    expect(document.querySelector(".toast.error")?.textContent).toBe(
      "dismissal failed",
    );
    cleanup();
    vi.unstubAllGlobals();
  });
});
