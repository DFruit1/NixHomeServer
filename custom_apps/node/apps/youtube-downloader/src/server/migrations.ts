import type { SqliteDatabase } from './sqlite-db.js';

export const migrateJobsSchema = async (db: SqliteDatabase): Promise<void> => {
  await db.exec(`
    pragma journal_mode = wal;
    create table if not exists schema_migrations (
      version integer primary key,
      applied_at text not null
    );

    create table if not exists jobs (
      id text primary key,
      parent_id text references jobs(id) on delete set null,
      created_at text not null,
      updated_at text not null,
      created_by text not null,
      status text not null,
      request_json text not null,
      alert_json text,
      source_json text,
      progress_json text,
      output_root text,
      output_folder text,
      error text
    );

    create index if not exists jobs_status_created_at_idx on jobs(status, created_at);
    create index if not exists jobs_created_by_created_at_idx on jobs(created_by, created_at);

    create table if not exists job_files (
      id integer primary key autoincrement,
      job_id text not null references jobs(id) on delete cascade,
      path text not null,
      kind text not null,
      created_at text not null
    );

    create index if not exists job_files_job_id_idx on job_files(job_id);

    create table if not exists job_events (
      id integer primary key autoincrement,
      job_id text not null references jobs(id) on delete cascade,
      created_at text not null,
      event_type text not null,
      message text,
      data_json text
    );

    create index if not exists job_events_job_id_created_at_idx on job_events(job_id, created_at);

    insert or ignore into schema_migrations(version, applied_at) values (1, datetime('now'));
  `);

  const columns = await db.query<{ name: string }>(`select name from pragma_table_info('jobs');`);
  if (!columns.some((column) => column.name === 'alert_json')) {
    await db.exec(`alter table jobs add column alert_json text;`);
  }

  await db.exec(`insert or ignore into schema_migrations(version, applied_at) values (2, datetime('now'));`);
};
