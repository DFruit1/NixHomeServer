import { afterEach, describe, expect, it, vi } from "vitest";
import { connectLive, latestRequest, type LiveSource } from "../live";

afterEach(() => vi.useRealTimers());
describe("live updates", () => {
  it("refetches on messages, resync and reconnection; polls while disconnected", () => {
    vi.useFakeTimers();
    const refresh = vi.fn(),
      status = vi.fn();
    const handlers: Record<string, () => void> = {};
    const source: LiveSource = {
      readyState: 0,
      onopen: null,
      onerror: null,
      onmessage: null,
      addEventListener: (key, handler) => {
        handlers[key] = handler;
      },
      close: vi.fn(),
    };
    const close = connectLive(refresh, status, () => source);
    vi.advanceTimersByTime(30000);
    expect(refresh).toHaveBeenCalledTimes(1);
    source.readyState = 1;
    source.onopen?.(new Event("open"));
    vi.advanceTimersByTime(300);
    expect(status).toHaveBeenLastCalledWith("Live");
    expect(refresh).toHaveBeenCalledTimes(2);
    handlers.resync();
    source.onmessage?.(new MessageEvent("message"));
    vi.advanceTimersByTime(300);
    expect(refresh).toHaveBeenCalledTimes(3);
    vi.advanceTimersByTime(30000);
    expect(refresh).toHaveBeenCalledTimes(3);
    source.readyState = 0;
    source.onerror?.(new Event("error"));
    vi.advanceTimersByTime(30000);
    expect(status).toHaveBeenLastCalledWith(
      "Reconnecting · polling every 30 s",
    );
    expect(refresh).toHaveBeenCalledTimes(4);
    close();
    vi.advanceTimersByTime(60000);
    expect(refresh).toHaveBeenCalledTimes(4);
    expect(source.close).toHaveBeenCalledOnce();
  });
  it("polls when EventSource is unavailable", () => {
    vi.useFakeTimers();
    const refresh = vi.fn(),
      status = vi.fn();
    const close = connectLive(refresh, status, () => {
      throw new Error("unsupported");
    });
    vi.advanceTimersByTime(30000);
    expect(refresh).toHaveBeenCalledOnce();
    expect(status).toHaveBeenCalledWith("Polling every 30 s");
    close();
  });
  it("ignores old device responses even if the transport ignores abort", async () => {
    const latest = latestRequest(),
      apply = vi.fn(),
      fail = vi.fn();
    let resolveOld!: (value: string) => void;
    latest.run(
      () =>
        new Promise<string>((resolve) => {
          resolveOld = resolve;
        }),
      apply,
      fail,
    );
    latest.run(() => Promise.resolve("device B"), apply, fail);
    await Promise.resolve();
    resolveOld("device A");
    await Promise.resolve();
    expect(apply).toHaveBeenCalledExactlyOnceWith("device B");
    expect(fail).not.toHaveBeenCalled();
  });
  it("does not apply responses after unmount", async () => {
    const latest = latestRequest(),
      apply = vi.fn();
    latest.run(() => Promise.resolve("old"), apply, vi.fn());
    latest.cancel();
    await Promise.resolve();
    expect(apply).not.toHaveBeenCalled();
  });
});
