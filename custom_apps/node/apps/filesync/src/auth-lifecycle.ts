export function isTerminalSessionError(error: unknown): boolean {
  return error instanceof Error && /invalid_grant|session expired or was revoked/i.test(error.message);
}

export function shouldRestoreSessionBackup(error: unknown): boolean {
  return !isTerminalSessionError(error);
}

export function createCallbackProcessor<T>(finish: (url: string) => Promise<T>): (url: string) => Promise<T> {
  const pending = new Map<string, Promise<T>>();
  const completed = new Set<string>();
  return (url) => {
    if (completed.has(url)) return pending.get(url)!;
    const existing = pending.get(url);
    if (existing) return existing;
    const operation = finish(url).then((result) => {
      completed.add(url);
      return result;
    }).finally(() => {
      if (!completed.has(url)) pending.delete(url);
    });
    pending.set(url, operation);
    return operation;
  };
}

export function createStartupGeneration(): { begin(): number; invalidate(): void; isCurrent(generation: number): boolean } {
  let generation = 0;
  return {
    begin: () => ++generation,
    invalidate: () => { generation += 1; },
    isCurrent: (candidate) => generation === candidate,
  };
}
