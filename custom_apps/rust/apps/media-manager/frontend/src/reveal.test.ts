import { afterEach, expect, it, vi } from "vitest";
import { revealWhenMounted } from "./reveal";

afterEach(() => {
  vi.unstubAllGlobals();
});

function scrollableElement() {
  const element = document.createElement("div");
  const scrollIntoView = vi.fn();
  element.scrollIntoView = scrollIntoView;
  return { element, scrollIntoView };
}

it("reveals an element that is already mounted", async () => {
  vi.stubGlobal("matchMedia", () => ({ matches: true }));
  const { element, scrollIntoView } = scrollableElement();
  document.body.append(element);
  revealWhenMounted(() => element);
  await vi.waitFor(() => expect(scrollIntoView).toHaveBeenCalled());
  expect(scrollIntoView).toHaveBeenCalledWith({
    block: "start",
    behavior: "auto",
  });
  element.remove();
});

it("retries until the element mounts", async () => {
  vi.stubGlobal("matchMedia", () => ({ matches: true }));
  const { element, scrollIntoView } = scrollableElement();
  let mounted: HTMLElement | null = null;
  revealWhenMounted(() => mounted);
  await new Promise((resolve) => setTimeout(resolve, 80));
  mounted = element;
  document.body.append(element);
  await vi.waitFor(() => expect(scrollIntoView).toHaveBeenCalled());
  element.remove();
});

it("does nothing when the element never appears", async () => {
  vi.stubGlobal("matchMedia", () => ({ matches: true }));
  revealWhenMounted(() => undefined, 1);
  await new Promise((resolve) => setTimeout(resolve, 80));
});
