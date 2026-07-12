import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import type { Direction, MessageFilters, MqttMessage } from '../shared/types.js';

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

type MessageRow = {
  id: number;
  created_at: string;
  direction: Direction;
  topic: string;
  qos?: number | null;
  retain: number;
  payload_text: string;
  payload_json?: string | null;
  payload_encoding: string;
  payload_bytes: number;
  parse_error?: string | null;
  source: string;
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

  async migrate(): Promise<void> {
    await this.exec(`
      pragma journal_mode = wal;
      create table if not exists schema_migrations (
        version integer primary key,
        applied_at text not null
      );

      create table if not exists messages (
        id integer primary key autoincrement,
        created_at text not null,
        direction text not null check(direction in ('inbound', 'outbound')),
        topic text not null,
        qos integer,
        retain integer not null default 0,
        payload_text text not null,
        payload_json text,
        payload_encoding text not null default 'utf8',
        payload_bytes integer not null,
        parse_error text,
        source text not null
      );

      create index if not exists messages_created_at_idx on messages(created_at);
      create index if not exists messages_topic_created_at_idx on messages(topic, created_at);
      create index if not exists messages_direction_created_at_idx on messages(direction, created_at);

      insert or ignore into schema_migrations(version, applied_at) values (1, datetime('now'));
    `);
  }

  async insertMessage(params: {
    direction: Direction;
    topic: string;
    payloadText: string;
    payloadJson?: unknown;
    qos?: number;
    retain?: boolean;
    payloadEncoding?: string;
    parseError?: string;
    source: string;
  }): Promise<number> {
    const bytes = Buffer.byteLength(params.payloadText);
    await this.exec(`
      insert into messages(created_at, direction, topic, qos, retain, payload_text, payload_json, payload_encoding, payload_bytes, parse_error, source)
      values (
        datetime('now'),
        ${sqlValue(params.direction)},
        ${sqlValue(params.topic)},
        ${sqlValue(params.qos)},
        ${params.retain ? 1 : 0},
        ${sqlValue(params.payloadText)},
        ${params.payloadJson === undefined ? 'null' : jsonValue(params.payloadJson)},
        ${sqlValue(params.payloadEncoding ?? 'utf8')},
        ${sqlValue(bytes)},
        ${sqlValue(params.parseError)},
        ${sqlValue(params.source)}
      );
    `);
    const rows = await this.query<{ id: number }>('select id from messages order by id desc limit 1;');
    return rows[0]?.id ?? 0;
  }

  async listMessages(filters: MessageFilters = {}): Promise<MqttMessage[]> {
    const where = this.whereClause(filters);
    const limit = Math.max(1, Math.min(filters.limit ?? 100, 1000));
    const offset = Math.max(0, filters.offset ?? 0);
    const rows = await this.query<MessageRow>(`
      select *
      from messages
      ${where}
      order by created_at desc, id desc
      limit ${limit}
      offset ${offset};
    `);
    return rows.map(rowToMessage);
  }

  async exportMessages(filters: MessageFilters = {}): Promise<MqttMessage[]> {
    const where = this.whereClause(filters);
    const rows = await this.query<MessageRow>(`
      select *
      from messages
      ${where}
      order by created_at asc, id asc;
    `);
    return rows.map(rowToMessage);
  }

  async observedTopics(): Promise<string[]> {
    const rows = await this.query<{ topic: string }>(`
      select distinct topic
      from messages
      order by topic asc;
    `);
    return rows.map((row) => row.topic);
  }

  async summary(): Promise<{ latestMessageAt?: string; messageCount: number }> {
    const rows = await this.query<{ latest_message_at?: string | null; message_count: number }>(`
      select max(created_at) as latest_message_at, count(*) as message_count
      from messages;
    `);
    return {
      latestMessageAt: rows[0]?.latest_message_at ?? undefined,
      messageCount: rows[0]?.message_count ?? 0,
    };
  }

  private whereClause(filters: MessageFilters): string {
    const clauses: string[] = [];
    if (filters.topic) {
      clauses.push(`topic = ${sqlValue(filters.topic)}`);
    }
    if (filters.direction) {
      clauses.push(`direction = ${sqlValue(filters.direction)}`);
    }
    if (filters.from) {
      clauses.push(`created_at >= ${sqlValue(filters.from)}`);
    }
    if (filters.to) {
      clauses.push(`created_at <= ${sqlValue(filters.to)}`);
    }
    if (filters.search) {
      clauses.push(`payload_text like ${sqlValue(`%${filters.search}%`)}`);
    }
    return clauses.length ? `where ${clauses.join(' and ')}` : '';
  }
}

const rowToMessage = (row: MessageRow): MqttMessage => {
  let payloadJson: unknown;
  if (row.payload_json) {
    try {
      payloadJson = JSON.parse(row.payload_json);
    } catch {
      payloadJson = undefined;
    }
  }
  return {
    id: row.id,
    createdAt: row.created_at,
    direction: row.direction,
    topic: row.topic,
    qos: row.qos ?? undefined,
    retain: row.retain === 1,
    payloadText: row.payload_text,
    payloadJson,
    payloadEncoding: row.payload_encoding,
    payloadBytes: row.payload_bytes,
    parseError: row.parse_error ?? undefined,
    source: row.source,
  };
};
