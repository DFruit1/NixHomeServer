import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { SqliteDatabase } from '../sqlite-db.js';

class TransactionTestDatabase extends SqliteDatabase {
  runTransaction(sql: string): Promise<void> { return this.transaction(sql); }
}

describe('database request execution', () => {
  it('keeps the event loop responsive during an expensive query', async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), 'sqlite-worker-'));
    const db = new SqliteDatabase(path.join(root, 'state.sqlite'));
    try {
      await db.exec('CREATE TABLE fixture(id INTEGER)');
      let timerRan = false;
      const timer = new Promise<void>((resolve) => setTimeout(() => { timerRan = true; resolve(); }, 0));
      const query = db.query('WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<2000000) SELECT sum(x) FROM n');
      expect(timerRan).toBe(false);
      await timer;
      let finished = false;
      void query.then(() => { finished = true; });
      await Promise.resolve();
      expect(finished).toBe(false);
      await query;
      expect(await db.query('SELECT count(*) AS total FROM fixture')).toEqual([{ total: 0 }]);
    } finally {
      await db.close();
      await rm(root, { recursive: true, force: true });
    }
  });
});


describe('database worker lifecycle', () => {
  it('keeps an unopened database closed without starting a worker', async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), 'sqlite-worker-'));
    const db = new SqliteDatabase(path.join(root, 'state.sqlite'));
    try {
      await db.close();
      await expect(db.query('SELECT 1')).rejects.toThrow('closing');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it('rolls back every write in a failed transaction and remains usable', async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), 'sqlite-worker-'));
    const db = new TransactionTestDatabase(path.join(root, 'state.sqlite'));
    try {
      await db.exec('CREATE TABLE fixture(id INTEGER PRIMARY KEY)');
      await expect(db.runTransaction('INSERT INTO fixture VALUES(1); INSERT INTO fixture VALUES(1);')).rejects.toThrow('UNIQUE');
      expect(await db.query('SELECT id FROM fixture')).toEqual([]);
      await db.runTransaction('INSERT INTO fixture VALUES(2);');
      expect(await db.query('SELECT id FROM fixture')).toEqual([{ id: 2 }]);
    } finally {
      await db.close();
      await rm(root, { recursive: true, force: true });
    }
  });

  it('rejects excess work without losing accepted requests', async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), 'sqlite-worker-'));
    const db = new SqliteDatabase(path.join(root, 'state.sqlite'));
    try {
      await db.exec('CREATE TABLE fixture(id INTEGER PRIMARY KEY); BEGIN IMMEDIATE');
      const accepted = Array.from({ length: 128 }, (_, id) => db.exec(`INSERT INTO fixture VALUES(${id})`));
      const complete = Promise.all(accepted);
      await expect(db.exec('INSERT INTO fixture VALUES(999)')).rejects.toThrow('busy');
      await complete;
      await db.exec('COMMIT');
      expect(await db.query('SELECT count(*) AS total FROM fixture')).toEqual([{ total: 128 }]);
    } finally {
      await db.close();
      await rm(root, { recursive: true, force: true });
    }
  });

  it('drains accepted requests when closed at the admission limit', async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), 'sqlite-worker-'));
    const databasePath = path.join(root, 'state.sqlite');
    const db = new SqliteDatabase(databasePath);
    try {
      await db.exec('CREATE TABLE fixture(id INTEGER PRIMARY KEY); BEGIN IMMEDIATE');
      const accepted = Array.from({ length: 128 }, (_, id) => db.exec(`INSERT INTO fixture VALUES(${id}); ${id === 127 ? 'COMMIT' : ''}`));
      const complete = Promise.allSettled(accepted);
      const closing = db.close();
      await expect(db.query('SELECT 1')).rejects.toThrow('closing');
      await closing;
      expect((await complete).every((result) => result.status === 'fulfilled')).toBe(true);
      const reopened = new SqliteDatabase(databasePath);
      try {
        expect(await reopened.query('SELECT count(*) AS total FROM fixture')).toEqual([{ total: 128 }]);
      } finally {
        await reopened.close();
      }
    } finally {
      await db.close().catch(() => undefined);
      await rm(root, { recursive: true, force: true });
    }
  });
});
