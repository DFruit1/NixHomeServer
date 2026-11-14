/** Touch listeners must be synchronous/non-passive so a held drag can take over
 * from ordinary scrolling. A swipe before the hold still scrolls normally. */
export function installPhotoSelection(
  grid: HTMLElement,
  selection: {
    get: () => string[];
    set: (ids: string[]) => void;
    start: () => void;
    loadMore: () => void;
  },
): () => void {
  let timer = 0;
  let frame = 0;
  let active = false;
  let anchor = "";
  let base: string[] = [];
  let removing = false;
  let x = 0;
  let y = 0;
  let startX = 0;
  let startY = 0;
  let suppressClickUntil = 0;
  let lastPainted = "";
  const tiles = () =>
    Array.from(grid.querySelectorAll<HTMLElement>("[data-photo-id]"));
  const paint = (id: string) => {
    if (id === lastPainted) return;
    const ids = tiles().map((tile) => tile.dataset.photoId!);
    const first = ids.indexOf(anchor);
    const last = ids.indexOf(id);
    if (first < 0 || last < 0) return;
    lastPainted = id;
    const range = ids.slice(Math.min(first, last), Math.max(first, last) + 1);
    const next = removing
      ? base.filter((id) => !range.includes(id))
      : [...new Set([...base, ...range])];
    if (next.join() !== selection.get().join()) selection.set(next);
  };
  const hit = () => {
    const tile = document
      .elementFromPoint(x, y)
      ?.closest<HTMLElement>("[data-photo-id]");
    if (tile && grid.contains(tile)) paint(tile.dataset.photoId!);
  };
  const scroll = () => {
    if (!active) return;
    // The phone navigation owns the bottom edge; leave it clear during a drag.
    const top = Math.max(grid.getBoundingClientRect().top, 100);
    const bottom = Math.min(
      grid.getBoundingClientRect().bottom,
      window.innerHeight - 88,
    );
    const delta =
      y < top + 56
        ? -Math.min(18, (top + 56 - y) / 3)
        : y > bottom - 56
          ? Math.min(18, (y - bottom + 56) / 3)
          : 0;
    if (delta) window.scrollBy(0, delta);
    hit();
    if (grid.getBoundingClientRect().bottom < window.innerHeight + 100)
      selection.loadMore();
    frame = requestAnimationFrame(scroll);
  };
  const stop = () => {
    window.clearTimeout(timer);
    cancelAnimationFrame(frame);
    timer = 0;
    if (active) suppressClickUntil = Date.now() + 800;
    active = false;
    grid.classList.remove("images-grid--dragging");
  };
  const start = (event: TouchEvent) => {
    stop();
    if (event.touches.length !== 1 || window.innerWidth > 920) return;
    const tile = (event.target as Element).closest<HTMLElement>(
      "[data-photo-id]",
    );
    if (!tile || tile.matches(":disabled")) return;
    anchor = tile.dataset.photoId!;
    x = startX = event.touches[0].clientX;
    y = startY = event.touches[0].clientY;
    timer = window.setTimeout(() => {
      timer = 0;
      active = true;
      base = [...selection.get()];
      removing = base.includes(anchor);
      const heldTop = tile.getBoundingClientRect().top;
      selection.start();
      grid.classList.add("images-grid--dragging");
      lastPainted = "";
      paint(anchor);
      // Keep the held photo under the finger when the action bar mounts.
      frame = requestAnimationFrame(() => {
        frame = requestAnimationFrame(() => {
          if (!active) return;
          window.scrollBy(0, tile.getBoundingClientRect().top - heldTop);
          scroll();
        });
      });
    }, 400);
  };
  const move = (event: TouchEvent) => {
    if (event.touches.length !== 1) return stop();
    x = event.touches[0].clientX;
    y = event.touches[0].clientY;
    if (active) {
      event.preventDefault();
      hit();
    } else if (Math.hypot(x - startX, y - startY) > 10) {
      window.clearTimeout(timer);
      timer = 0;
    }
  };
  const click = (event: MouseEvent) => {
    if (Date.now() < suppressClickUntil) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  };
  const context = (event: Event) => {
    if (timer || active || Date.now() < suppressClickUntil)
      event.preventDefault();
  };
  grid.addEventListener("touchstart", start, { passive: true });
  grid.addEventListener("touchmove", move, { passive: false });
  grid.addEventListener("touchend", stop);
  grid.addEventListener("touchcancel", stop);
  grid.addEventListener("click", click, true);
  grid.addEventListener("contextmenu", context);
  return () => {
    stop();
    grid.removeEventListener("touchstart", start);
    grid.removeEventListener("touchmove", move);
    grid.removeEventListener("touchend", stop);
    grid.removeEventListener("touchcancel", stop);
    grid.removeEventListener("click", click, true);
    grid.removeEventListener("contextmenu", context);
  };
}
