import { describe, expect, it, vi } from "vitest";
import {
  priorityFailureMessage,
  setPriorityClass,
  submitPriorityChange,
} from "../shared/dom";

const selectElement = () => {
  document.body.innerHTML = `
    <select
      class="priority-select priority-select-normal"
      data-priority-select
      data-sender-kind="address"
      data-sender-value="billing@example.test"
      data-return-to="/search?q=invoice"
      data-previous-priority="normal"
    >
      <option value="high">High</option>
      <option value="normal" selected>Normal</option>
      <option value="low">Low</option>
    </select>
  `;
  return document.querySelector<HTMLSelectElement>("select")!;
};

describe("priority select island helpers", () => {
  it("updates priority classes", () => {
    const select = selectElement();
    setPriorityClass(select, "high");
    expect(select.classList.contains("priority-select-high")).toBe(true);
    expect(select.classList.contains("priority-select-normal")).toBe(false);
  });

  it("submits expected form data and redirects on success", async () => {
    const select = selectElement();
    select.value = "high";
    const assign = vi.fn();
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      const body = init.body as URLSearchParams;
      expect(body.get("sender_kind")).toBe("address");
      expect(body.get("sender_value")).toBe("billing@example.test");
      expect(body.get("priority")).toBe("high");
      return new Response(
        JSON.stringify({ ok: true, return_to: "/search?q=invoice" }),
        { status: 200 },
      );
    });

    const result = await submitPriorityChange(select, {
      fetch: fetchMock as unknown as typeof fetch,
      assign,
      currentPath: () => "/search",
    });

    expect(result.ok).toBe(true);
    expect(assign).toHaveBeenCalledWith("/search?q=invoice");
  });

  it("restores previous value and class on failure", async () => {
    const select = selectElement();
    select.value = "low";
    const result = await submitPriorityChange(select, {
      fetch: vi.fn(
        async () =>
          new Response(JSON.stringify({ ok: false, message: "denied" }), {
            status: 403,
          }),
      ) as unknown as typeof fetch,
      assign: vi.fn(),
      currentPath: () => "/search",
    });

    expect(result.ok).toBe(false);
    expect(select.value).toBe("normal");
    expect(select.disabled).toBe(false);
    expect(select.classList.contains("priority-select-normal")).toBe(true);
  });

  it("renders a useful failure message", () => {
    expect(priorityFailureMessage("denied")).toContain(
      "Priority change failed.",
    );
    expect(priorityFailureMessage("denied")).toContain(
      "Server response: denied",
    );
  });
});
