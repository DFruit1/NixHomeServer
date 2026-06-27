import { describe, expect, it, vi } from "vitest";
import { setupAttachmentSelection, submitPaperlessForm } from "../shared/dom";

const setup = () => {
  document.body.innerHTML = `
    <button data-select-page type="button">Select page</button>
    <span data-selected-count></span>
    <form id="attachment-download-form"><button data-bulk-action type="submit">Download</button></form>
    <form id="attachment-paperless-form" action="/attachments/send-paperless" data-paperless-form><button data-bulk-action type="submit">Send selected</button></form>
    <article data-attachment-row data-attachment-key="first" tabindex="0">
      <form action="/attachments/send-paperless" data-paperless-form>
        <input type="hidden" name="attachment_keys" value="first">
        <button type="submit">Send</button>
      </form>
    </article>
    <article data-attachment-row data-attachment-key="second" tabindex="0"><button type="button">Inner</button></article>
  `;
  return setupAttachmentSelection(document);
};

describe("attachment selection island helpers", () => {
  it("toggles row selection and syncs hidden bulk form inputs", () => {
    const cleanup = setup();
    document
      .querySelector<HTMLElement>('[data-attachment-key="first"]')
      ?.click();

    expect(
      document
        .querySelector('[data-attachment-key="first"]')
        ?.getAttribute("aria-selected"),
    ).toBe("true");
    expect(
      Array.from(
        document.querySelectorAll<HTMLInputElement>(
          '#attachment-download-form input[name="attachment_keys"]',
        ),
      ).map((input) => input.value),
    ).toEqual(["first"]);
    expect(
      Array.from(
        document.querySelectorAll<HTMLInputElement>(
          '#attachment-paperless-form input[name="attachment_keys"]',
        ),
      ).map((input) => input.value),
    ).toEqual(["first"]);
    expect(document.querySelector("[data-selected-count]")?.textContent).toBe(
      "1 selected",
    );
    cleanup();
  });

  it("toggles every visible row with select page", () => {
    const cleanup = setup();
    const selectPage =
      document.querySelector<HTMLElement>("[data-select-page]");
    selectPage?.click();

    expect(
      Array.from(
        document.querySelectorAll<HTMLInputElement>(
          '#attachment-download-form input[name="attachment_keys"]',
        ),
      ).map((input) => input.value),
    ).toEqual(["first", "second"]);
    expect(selectPage?.textContent).toBe("Deselect all");

    selectPage?.click();
    expect(
      document.querySelectorAll(
        '#attachment-download-form input[name="attachment_keys"]',
      ),
    ).toHaveLength(0);
    expect(selectPage?.textContent).toBe("Select page");
    cleanup();
  });

  it("opens filter dialogs, copies current filters, and warns before changing auto-export presets", () => {
    document.body.innerHTML = `
      <form id="attachment-search-form">
        <input name="q" value="rent review">
        <select name="priority"><option value="high" selected>High</option></select>
        <input type="checkbox" name="include_inline" value="1" checked>
      </form>
      <button type="button" data-open-dialog="attachment-presets-dialog">Filter Presets...</button>
      <dialog id="attachment-presets-dialog">
        <form method="post" data-copy-filters-from="attachment-search-form" data-auto-export-preset-names="Invoices">
          <input name="preset_name" value="Invoices">
          <span data-copied-filter-fields></span>
          <button type="submit">Save</button>
        </form>
        <button type="button" data-close-dialog>Close</button>
      </dialog>
    `;
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    const cleanup = setupAttachmentSelection(document);

    document.querySelector<HTMLElement>("[data-open-dialog]")?.click();
    expect(
      document
        .querySelector<HTMLDialogElement>("#attachment-presets-dialog")
        ?.hasAttribute("open"),
    ).toBe(true);

    const form = document.querySelector<HTMLFormElement>(
      "form[data-copy-filters-from]",
    )!;
    const event = new SubmitEvent("submit", {
      bubbles: true,
      cancelable: true,
    });
    form.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(confirm).toHaveBeenCalledOnce();
    expect(
      Array.from(
        form.querySelectorAll<HTMLInputElement>(
          "[data-copied-filter-fields] input",
        ),
      ).map((input) => [input.name, input.value]),
    ).toEqual([
      ["q", "rent review"],
      ["priority", "high"],
      ["include_inline", "1"],
    ]);

    cleanup();
    confirm.mockRestore();
  });

  it("ignores clicks on interactive children", () => {
    const cleanup = setup();
    document
      .querySelector<HTMLButtonElement>('[data-attachment-key="second"] button')
      ?.click();

    expect(
      document
        .querySelector('[data-attachment-key="second"]')
        ?.getAttribute("aria-selected"),
    ).toBe("false");
    expect(
      document.querySelectorAll(
        '#attachment-download-form input[name="attachment_keys"]',
      ),
    ).toHaveLength(0);
    cleanup();
  });

  it("supports keyboard activation", () => {
    const cleanup = setup();
    document
      .querySelector<HTMLElement>('[data-attachment-key="second"]')
      ?.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Enter", bubbles: true }),
      );

    expect(
      document
        .querySelector('[data-attachment-key="second"]')
        ?.getAttribute("aria-selected"),
    ).toBe("true");
    cleanup();
  });

  it("sends attachments to Paperless without reloading and marks sent rows", async () => {
    document.body.innerHTML = `
      <article data-attachment-row data-attachment-key="first" tabindex="0">
        <form action="/attachments/send-paperless" data-paperless-form>
          <input type="hidden" name="attachment_keys" value="first">
          <button type="submit">Send</button>
        </form>
      </article>
    `;
    const form = document.querySelector<HTMLFormElement>(
      "form[data-paperless-form]",
    )!;
    const fetchMock = async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(init?.headers).toMatchObject({
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
      });
      expect(init?.body).toBeInstanceOf(URLSearchParams);
      const body = init?.body as URLSearchParams;
      expect(body.get("attachment_keys")).toBe("first");

      return new Response(
        JSON.stringify({
          ok: true,
          message: "1 attachment sent to Paperless",
          sent_attachment_keys: ["first"],
        }),
        { status: 200 },
      );
    };

    const result = await submitPaperlessForm(form, {
      fetch: fetchMock as typeof fetch,
      doc: document,
    });

    expect(result.ok).toBe(true);
    expect(document.querySelector("form[data-paperless-form]")).toBeNull();
    expect(document.querySelector(".paperless-sent-button")).not.toBeNull();
  });
});
