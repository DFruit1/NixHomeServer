function scrollIntoView(element: HTMLElement, behavior: ScrollBehavior): void {
  element.scrollIntoView({ block: "start", behavior });
}

function isComfortablyVisible(element: HTMLElement): boolean {
  const rect = element.getBoundingClientRect();
  if (rect.width === 0 && rect.height === 0) return false;
  return rect.top >= 0 && rect.top < window.innerHeight * 0.5;
}

export function revealWhenMounted(
  getElement: () => HTMLElement | null | undefined,
  attempts = 20,
): void {
  if (typeof window === "undefined") return;
  const reduceMotion =
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const reveal = (remaining: number): void => {
    const element = getElement();
    if (!element) {
      if (remaining > 0) window.setTimeout(() => reveal(remaining - 1), 50);
      return;
    }
    if (reduceMotion) {
      scrollIntoView(element, "auto");
      return;
    }
    scrollIntoView(element, "smooth");
    window.setTimeout(() => {
      const current = getElement();
      if (current && !isComfortablyVisible(current))
        scrollIntoView(current, "auto");
    }, 400);
  };
  window.setTimeout(() => reveal(attempts), 0);
}
