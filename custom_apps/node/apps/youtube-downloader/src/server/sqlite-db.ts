import { existsSync } from 'node:fs';
import { Worker } from 'node:worker_threads';

export const sqlValue = (value: string | number | null | undefined): string => {
  if (value === null || value === undefined) {
    return 'null';
  }
  if (typeof value === 'number') {
    return Number.isFinite(value) ? String(value) : 'null';
  }
  return `'${value.replace(/'/g, "''")}'`;
};

export const jsonValue = (value: unknown): string => sqlValue(JSON.stringify(value));

export class SqliteDatabase {
  private worker?: Worker;
  private nextId = 0;
  private pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
  private closing?: Promise<void>;

  constructor(protected readonly databasePath: string) {}

  protected request<T>(operation: string, sql = '', retentionDays?: number): Promise<T> {
    if (this.closing && operation !== 'close') return Promise.reject(new Error('Database is closing'));
    if (operation !== 'close' && this.pending.size >= 128) return Promise.reject(new Error('Database is busy'));
    if (!this.worker) {
      const compiled = new URL('./sqlite-worker.js', import.meta.url);
      const source = existsSync(compiled) ? compiled : new URL('./sqlite-worker.ts', import.meta.url);
      const worker = new Worker(source, { workerData: { databasePath: this.databasePath } });
      this.worker = worker;
      worker.on('message', ({ id, value, error }) => {
        const request = this.pending.get(id);
        if (!request) return;
        this.pending.delete(id);
        if (error) request.reject(new Error(error)); else request.resolve(value);
        if (!this.pending.size) worker.unref();
      });
      const fail = (error: Error) => {
        if (this.worker !== worker) return;
        for (const request of this.pending.values()) request.reject(error);
        this.pending.clear();
        if (this.worker === worker) this.worker = undefined;
        worker.unref();
      };
      worker.on('error', fail);
      worker.on('exit', () => fail(new Error('Database worker stopped')));
    }
    this.worker.ref();
    const id = ++this.nextId;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: (value) => resolve(value as T), reject });
      this.worker!.postMessage({ id, operation, sql, retentionDays });
    });
  }

  async exec(sql: string): Promise<void> { await this.request('exec', sql); }
  async query<T>(sql: string): Promise<T[]> { return this.request<T[]>('query', sql); }
  protected async transaction(sql: string): Promise<void> { await this.request('transaction', sql); }

  close(): Promise<void> {
    if (this.closing) return this.closing;
    const worker = this.worker;
    if (!worker) {
      this.closing = Promise.resolve();
      return this.closing;
    }
    this.closing = (async () => {
      try { await this.request('close'); } finally { await worker.terminate(); }
    })();
    return this.closing;
  }
}
