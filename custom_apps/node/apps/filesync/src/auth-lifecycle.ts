export function isTerminalSessionError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : typeof error === 'string' ? error : '';
  return /invalid_grant|session expired or was revoked/i.test(message);
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

export function createCallbackOwnership(): {
  begin(): number;
  claim(sequence: number, observedGeneration: number, currentGeneration: number): boolean;
  recordGeneration(sequence: number, generation: number): void;
  isCurrent(sequence: number, observedGeneration: number, currentGeneration: number): boolean;
} {
  let dispatched = 0;
  let committed = 0;
  let committedGeneration: number | undefined;
  const ownsGeneration = (observed: number, current: number) => observed === current || current === committedGeneration;
  return {
    begin: () => ++dispatched,
    claim: (sequence, observed, current) => {
      if (sequence < committed || !ownsGeneration(observed, current)) return false;
      committed = sequence;
      return true;
    },
    recordGeneration: (sequence, generation) => {
      if (sequence === committed) committedGeneration = generation;
    },
    isCurrent: (sequence, observed, current) => sequence >= committed && ownsGeneration(observed, current),
  };
}

export function createStartupGeneration(): { begin(): number; current(): number; invalidate(): void; isCurrent(generation: number): boolean } {
  let generation = 0;
  return {
    begin: () => ++generation,
    current: () => generation,
    invalidate: () => { generation += 1; },
    isCurrent: (candidate) => generation === candidate,
  };
}
