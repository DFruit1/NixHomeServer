import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

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
  protected connection?: DatabaseSync;

  constructor(protected readonly databasePath: string) {}

  protected getConnection(): DatabaseSync {
    if (!this.connection) {
      mkdirSync(path.dirname(this.databasePath), { recursive: true });
      this.connection = new DatabaseSync(this.databasePath);
      this.connection.exec('pragma foreign_keys = on; pragma busy_timeout = 5000; pragma journal_mode = wal;');
    }
    return this.connection;
  }

  async exec(sql: string): Promise<void> {
    this.getConnection().exec(sql);
  }

  async query<T>(sql: string): Promise<T[]> {
    return this.getConnection().prepare(sql).all() as unknown as T[];
  }

  close(): void {
    this.connection?.close();
    this.connection = undefined;
  }

  protected transaction(sql: string): void {
    const connection = this.getConnection();
    connection.exec('begin immediate;');
    try {
      connection.exec(sql);
      connection.exec('commit;');
    } catch (error) {
      connection.exec('rollback;');
      throw error;
    }
  }
}
