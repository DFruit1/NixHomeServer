import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { normalizeDownloadUrl } from '../shared/url.js';
import type { CreateJobRequest, Job, JobAlert, JobProgress, JobStatus, ProbeResponse } from '../shared/types.js';

const sqlValue = (value: string | number | null | undefined): string => {
  if (value === null || value === undefined) {
    return 'null';
  }
  if (typeof value === 'number') {
    return Number.isFinite(value) ? String(value) : 'null';
  }
  return `'${value.replace(/'/g, "''")}'`;
};

const jsonValue = (value: unknown): string => sqlValue(JSON.stringify(value));

type JobRow = {
  id: string;
  parent_id?: string | null;
  created_at: string;
  updated_at: string;
  created_by: string;
  status: JobStatus;
  request_json: string;
  alert_json?: string | null;
  source_json?: string | null;
  progress_json?: string | null;
  output_root?: string | null;
  output_folder?: string | null;
  error?: string | null;
};

export class Database {
  private connection?: DatabaseSync;

  constructor(private readonly databasePath: string) {}

  private getConnection(): DatabaseSync {
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

  private transaction(sql: string): void {
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

  async migrate(): Promise<void> {
    await this.exec(`
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

    const columns = await this.query<{ name: string }>(`select name from pragma_table_info('jobs');`);
    if (!columns.some((column) => column.name === 'alert_json')) {
      await this.exec(`alter table jobs add column alert_json text;`);
    }

    await this.exec(`insert or ignore into schema_migrations(version, applied_at) values (2, datetime('now'));`);
  }

  async markInterrupted(): Promise<void> {
    await this.exec(`
      update jobs
      set status = 'failed',
          updated_at = datetime('now'),
          error = 'interrupted by service restart',
          progress_json = null
      where status in ('probing', 'running', 'postprocessing');
    `);
  }

  async createJob(params: {
    id: string;
    parentId?: string;
    createdBy: string;
    request: CreateJobRequest;
    initialStatus?: JobStatus;
    alert?: JobAlert;
  }): Promise<void> {
    const status = params.initialStatus ?? 'queued';
    this.transaction(`
      insert into jobs(id, parent_id, created_at, updated_at, created_by, status, request_json, alert_json)
      values (
        ${sqlValue(params.id)},
        ${sqlValue(params.parentId)},
        datetime('now'),
        datetime('now'),
        ${sqlValue(params.createdBy)},
        ${sqlValue(status)},
        ${jsonValue(params.request)},
        ${params.alert ? jsonValue(params.alert) : 'null'}
      );
      insert into job_events(job_id, created_at, event_type, message, data_json)
      values (
        ${sqlValue(params.id)}, datetime('now'), ${sqlValue(status)},
        ${sqlValue(status === 'alert' ? params.alert?.message : 'Job queued')},
        ${params.alert ? jsonValue(params.alert) : 'null'}
      );
    `);
  }

  async addEvent(jobId: string, eventType: string, message?: string, data?: unknown): Promise<void> {
    await this.exec(`
      insert into job_events(job_id, created_at, event_type, message, data_json)
      values (${sqlValue(jobId)}, datetime('now'), ${sqlValue(eventType)}, ${sqlValue(message)}, ${data === undefined ? 'null' : jsonValue(data)});
    `);
  }

  async addFile(jobId: string, filePath: string, kind: string): Promise<void> {
    await this.exec(`
      insert into job_files(job_id, path, kind, created_at)
      values (${sqlValue(jobId)}, ${sqlValue(filePath)}, ${sqlValue(kind)}, datetime('now'));
    `);
  }

  async setStatus(jobId: string, status: JobStatus, error?: string): Promise<void> {
    this.transaction(`
      update jobs
      set status = ${sqlValue(status)},
          updated_at = datetime('now'),
          error = ${sqlValue(error)},
          alert_json = ${status === 'alert' ? 'alert_json' : 'null'}
      where id = ${sqlValue(jobId)};
      insert into job_events(job_id, created_at, event_type, message, data_json)
      values (${sqlValue(jobId)}, datetime('now'), ${sqlValue(status)}, ${sqlValue(error)}, null);
    `);
  }

  async setAlert(jobId: string, alert: JobAlert): Promise<void> {
    this.transaction(`
      update jobs
      set status = 'alert',
          updated_at = datetime('now'),
          error = null,
          progress_json = null,
          alert_json = ${jsonValue(alert)}
      where id = ${sqlValue(jobId)};
      insert into job_events(job_id, created_at, event_type, message, data_json)
      values (${sqlValue(jobId)}, datetime('now'), 'alert', ${sqlValue(alert.message)}, ${jsonValue(alert)});
    `);
  }

  async clearAlertAndQueue(jobId: string, request?: CreateJobRequest): Promise<void> {
    await this.exec(`
      update jobs
      set status = 'queued',
          updated_at = datetime('now'),
          request_json = ${request ? jsonValue(request) : 'request_json'},
          alert_json = null,
          error = null,
          progress_json = null
      where id = ${sqlValue(jobId)} and status = 'alert';
    `);
    await this.addEvent(jobId, 'queued', 'Job queued');
  }

  async updateRequest(jobId: string, request: CreateJobRequest): Promise<void> {
    await this.exec(`
      update jobs
      set request_json = ${jsonValue(request)},
          updated_at = datetime('now')
      where id = ${sqlValue(jobId)};
    `);
  }

  async setProgress(jobId: string, progress: JobProgress | null): Promise<void> {
    await this.exec(`
      update jobs
      set progress_json = ${progress ? jsonValue(progress) : 'null'},
          updated_at = datetime('now')
      where id = ${sqlValue(jobId)};
    `);
  }

  async setSource(jobId: string, source: ProbeResponse): Promise<void> {
    await this.exec(`
      update jobs
      set source_json = ${jsonValue(source)},
          updated_at = datetime('now')
      where id = ${sqlValue(jobId)};
    `);
  }

  async setOutput(jobId: string, outputRoot: string, outputFolder: string): Promise<void> {
    await this.exec(`
      update jobs
      set output_root = ${sqlValue(outputRoot)},
          output_folder = ${sqlValue(outputFolder)},
          updated_at = datetime('now')
      where id = ${sqlValue(jobId)};
    `);
  }

  async listJobs(createdBy: string, limit = 100): Promise<Job[]> {
    const rows = await this.query<JobRow>(`
      select *
      from jobs
      where created_by = ${sqlValue(createdBy)}
      order by created_at desc
      limit ${Math.max(1, Math.min(limit, 500))};
    `);
    return Promise.all(rows.map((row) => this.rowToJob(row)));
  }

  async getJob(id: string): Promise<Job | undefined> {
    const [row] = await this.query<JobRow>(`select * from jobs where id = ${sqlValue(id)} limit 1;`);
    return row ? this.rowToJob(row) : undefined;
  }

  async getJobForUser(id: string, createdBy: string): Promise<Job | undefined> {
    const [row] = await this.query<JobRow>(`
      select * from jobs
      where id = ${sqlValue(id)} and created_by = ${sqlValue(createdBy)}
      limit 1;
    `);
    return row ? this.rowToJob(row) : undefined;
  }

  async queuedJobs(): Promise<Job[]> {
    const rows = await this.query<JobRow>(`
      select *
      from jobs
      where status = 'queued'
      order by created_at asc;
    `);
    return Promise.all(rows.map((row) => this.rowToJob(row)));
  }

  /** Atomically reserves one queued job so concurrent queue pumps cannot start it twice. */
  async claimNextQueuedJob(): Promise<Job | undefined> {
    const connection = this.getConnection();
    connection.exec('begin immediate;');
    try {
      const row = connection.prepare(`
        select * from jobs
        where status = 'queued'
        order by created_at asc, id asc
        limit 1;
      `).get() as JobRow | undefined;
      if (!row) {
        connection.exec('commit;');
        return undefined;
      }
      const claimed = connection.prepare(`
        update jobs
        set status = 'probing', updated_at = datetime('now'), error = null
        where id = ? and status = 'queued';
      `).run(row.id);
      if (Number(claimed.changes) !== 1) {
        connection.exec('rollback;');
        return undefined;
      }
      connection.prepare(`
        insert into job_events(job_id, created_at, event_type, message, data_json)
        values (?, datetime('now'), 'probing', 'Job claimed by worker', null);
      `).run(row.id);
      connection.exec('commit;');
      return this.getJob(row.id);
    } catch (error) {
      connection.exec('rollback;');
      throw error;
    }
  }

  async findCompletedDownload(request: CreateJobRequest, createdBy: string, excludeJobId?: string): Promise<Job | undefined> {
    const rows = await this.query<JobRow>(`
      select *
      from jobs
      where status = 'completed' and created_by = ${sqlValue(createdBy)}
      order by updated_at desc, created_at desc;
    `);
    const normalizedUrl = normalizeDownloadUrl(request.url);
    for (const row of rows) {
      if (row.id === excludeJobId) {
        continue;
      }
      const rowRequest = JSON.parse(row.request_json) as CreateJobRequest;
      if (rowRequest.mediaType === request.mediaType && normalizeDownloadUrl(rowRequest.url) === normalizedUrl) {
        return this.rowToJob(row);
      }
    }
    return undefined;
  }

  async deleteJob(id: string, createdBy: string): Promise<void> {
    await this.exec(`
      delete from jobs
      where id = ${sqlValue(id)}
        and created_by = ${sqlValue(createdBy)}
        and status in ('completed', 'failed', 'cancelled');
    `);
  }

  async clearHistory(createdBy: string): Promise<void> {
    await this.exec(`
      delete from jobs
      where created_by = ${sqlValue(createdBy)}
        and status in ('completed', 'failed', 'cancelled');
    `);
  }

  async pruneEvents(retentionDays: number): Promise<number> {
    const connection = this.getConnection();
    const statement = connection.prepare(`
      delete from job_events
      where id in (
        select id from job_events
        where created_at < datetime('now', ?)
          and job_id in (select id from jobs where status in ('completed', 'failed', 'cancelled'))
        order by id asc
        limit 10000
      );
    `);
    let deleted = 0;
    for (;;) {
      const result = statement.run(`-${Math.max(1, retentionDays)} days`);
      const changes = Number(result.changes);
      deleted += changes;
      if (changes < 10000) {
        break;
      }
    }
    connection.exec('pragma wal_checkpoint(passive); pragma optimize;');
    return deleted;
  }

  private async rowToJob(row: JobRow): Promise<Job> {
    const files = await this.query<{ path: string }>(`
      select path
      from job_files
      where job_id = ${sqlValue(row.id)}
      order by id asc;
    `);
    return {
      id: row.id,
      parentId: row.parent_id ?? undefined,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      createdBy: row.created_by,
      request: JSON.parse(row.request_json) as CreateJobRequest,
      status: row.status,
      progress: row.progress_json ? (JSON.parse(row.progress_json) as JobProgress) : undefined,
      alert: row.alert_json ? (JSON.parse(row.alert_json) as JobAlert) : undefined,
      source: row.source_json ? (JSON.parse(row.source_json) as ProbeResponse) : undefined,
      outputRoot: row.output_root ?? undefined,
      outputFolder: row.output_folder ?? undefined,
      files: files.map((file) => file.path),
      error: row.error ?? undefined,
    };
  }
}
