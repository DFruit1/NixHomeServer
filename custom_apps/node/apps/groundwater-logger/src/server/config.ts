import { readFileSync } from 'node:fs';

export type AppConfig = {
  host: string;
  port: number;
  stateDir: string;
  databasePath: string;
  staticDir: string;
  mqttUrl: string;
  mqttUsername: string;
  mqttPassword: string;
  mqttSubscribeTopics: string[];
  mqttDefaultQos: 0 | 1 | 2;
  retentionDays: number;
  maximumMessages: number;
};

const numberFromEnv = (name: string, fallback: number): number => {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
};

const qosFromEnv = (name: string, fallback: 0 | 1 | 2): 0 | 1 | 2 => {
  const value = numberFromEnv(name, fallback);
  return value === 0 || value === 1 || value === 2 ? value : fallback;
};

const readPassword = (): string => {
  const raw = process.env.GROUNDWATER_MQTT_PASSWORD;
  if (raw) {
    return raw;
  }
  const file = process.env.GROUNDWATER_MQTT_PASSWORD_FILE;
  if (!file) {
    return '';
  }
  return readFileSync(file, 'utf8').trim();
};

const listFromEnv = (name: string, fallback: string[]): string[] => {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  return raw
    .split(',')
    .map((topic) => topic.trim())
    .filter(Boolean);
};

export const loadConfig = (): AppConfig => {
  const stateDir = process.env.GROUNDWATER_LOGGER_STATE_DIR ?? '/var/lib/groundwater-logger/state';
  return {
    host: process.env.GROUNDWATER_LOGGER_HOST ?? '127.0.0.1',
    port: numberFromEnv('GROUNDWATER_LOGGER_PORT', 8091),
    stateDir,
    databasePath: process.env.GROUNDWATER_LOGGER_DATABASE ?? `${stateDir}/messages.sqlite`,
    staticDir: process.env.GROUNDWATER_LOGGER_STATIC_DIR ?? new URL('../../client', import.meta.url).pathname,
    mqttUrl: process.env.GROUNDWATER_MQTT_URL ?? 'mqtt://127.0.0.1:1883',
    mqttUsername: process.env.GROUNDWATER_MQTT_USERNAME ?? 'groundwater-app',
    mqttPassword: readPassword(),
    mqttSubscribeTopics: listFromEnv('GROUNDWATER_MQTT_SUBSCRIBE_TOPICS', [
      'azman1/feeds/#',
      'testtopic/9',
      'requesttesta',
      'cmd/#',
      'cfg/#',
    ]),
    mqttDefaultQos: qosFromEnv('GROUNDWATER_MQTT_DEFAULT_QOS', 1),
    retentionDays: numberFromEnv('GROUNDWATER_LOGGER_RETENTION_DAYS', 90),
    maximumMessages: numberFromEnv('GROUNDWATER_LOGGER_MAXIMUM_MESSAGES', 500000),
  };
};

export const publicBrokerLabel = (mqttUrl: string): string => {
  try {
    const url = new URL(mqttUrl);
    url.username = '';
    url.password = '';
    return url.toString();
  } catch {
    return mqttUrl.replace(/\/\/[^@]+@/, '//');
  }
};
