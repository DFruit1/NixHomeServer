// Node 24's synchronous SQLite connection stays on one reusable worker.
// https://nodejs.org/docs/latest-v24.x/api/worker_threads.html
import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { parentPort, workerData } from 'node:worker_threads';

mkdirSync(path.dirname(workerData.databasePath), { recursive: true });
const connection = new DatabaseSync(workerData.databasePath);
connection.exec('pragma foreign_keys=on; pragma busy_timeout=5000; pragma journal_mode=wal;');

parentPort!.on('message', ({ id, operation, sql, retentionDays }: { id: number; operation: string; sql: string; retentionDays?: number }) => {
  try {
    let value: unknown;
    if (operation === 'query') value = connection.prepare(sql).all();
    else if (operation === 'exec') connection.exec(sql);
    else if (operation === 'transaction' || operation === 'claim') {
      connection.exec('begin immediate');
      try {
        if (operation === 'transaction') connection.exec(sql);
        else {
          const row = connection.prepare("SELECT id FROM jobs WHERE status='queued' ORDER BY created_at,id LIMIT 1").get();
          if (row) {
            connection.prepare("UPDATE jobs SET status='probing',updated_at=datetime('now'),error=NULL WHERE id=? AND status='queued'").run(row.id);
            connection.prepare("INSERT INTO job_events(job_id,created_at,event_type,message,data_json) VALUES(?,datetime('now'),'probing','Job claimed by worker',NULL)").run(row.id);
            value = row.id;
          }
        }
        connection.exec('commit');
      } catch (error) {
        connection.exec('rollback');
        throw error;
      }
    } else if (operation === 'prune') {
      const statement = connection.prepare(sql);
      let deleted = 0;
      for (;;) {
        const changes = Number(statement.run(`-${Math.max(1, retentionDays ?? 1)} days`).changes);
        deleted += changes;
        if (changes < 10000) break;
      }
      connection.exec('pragma wal_checkpoint(passive); pragma optimize;');
      value = deleted;
    } else if (operation === 'close') connection.close();
    else throw new Error('Unknown database operation');
    parentPort!.postMessage({ id, value });
  } catch (error) {
    parentPort!.postMessage({ id, error: error instanceof Error ? error.message : String(error) });
  }
});
