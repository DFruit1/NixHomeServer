import type { MqttMessage } from '../shared/types.js';

const csvCell = (value: unknown): string => {
  const text = value === null || value === undefined ? '' : String(value);
  return `"${text.replace(/"/g, '""')}"`;
};

export const messagesToCsv = (messages: MqttMessage[]): string => {
  const header = ['id', 'created_at', 'direction', 'topic', 'qos', 'retain', 'payload_text', 'parse_error', 'source'];
  const rows = messages.map((message) =>
    [
      message.id,
      message.createdAt,
      message.direction,
      message.topic,
      message.qos ?? '',
      message.retain ? 1 : 0,
      message.payloadText,
      message.parseError ?? '',
      message.source,
    ]
      .map(csvCell)
      .join(','),
  );
  return `${header.map(csvCell).join(',')}\n${rows.join('\n')}${rows.length ? '\n' : ''}`;
};

export const messagesToJsonl = (messages: MqttMessage[]): string =>
  messages.map((message) => JSON.stringify(message)).join('\n') + (messages.length ? '\n' : '');
