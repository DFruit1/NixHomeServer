import { describe, expect, it } from "vitest";
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

  it("selects every visible row with select page", () => {
    const cleanup = setup();
    document.querySelector<HTMLElement>("[data-select-page]")?.click();

    expect(
      Array.from(
        document.querySelectorAll<HTMLInputElement>(
          '#attachment-download-form input[name="attachment_keys"]',
        ),
      ).map((input) => input.value),
    ).toEqual(["first", "second"]);
    cleanup();
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
    const fetchMock = async () =>
      new Response(
        JSON.stringify({
          ok: true,
          message: "1 attachment sent to Paperless",
          sent_attachment_keys: ["first"],
        }),
        { status: 200 },
      );

    const result = await submitPaperlessForm(form, {
      fetch: fetchMock as typeof fetch,
      doc: document,
    });

    expect(result.ok).toBe(true);
    expect(document.querySelector("form[data-paperless-form]")).toBeNull();
    expect(document.querySelector(".paperless-sent-button")).not.toBeNull();
  });
});
