import type { MqttMessage } from '../shared/types.js';

export const csvCell = (value: unknown): string => {
  const text = value === null || value === undefined ? '' : String(value);
  return `"${text.replace(/"/g, '""')}"`;
};

export const csvHeader = (): string =>
  `${['id', 'created_at', 'direction', 'topic', 'qos', 'retain', 'payload_text', 'parse_error', 'source'].map(csvCell).join(',')}\n`;

export const messageToCsvRow = (message: MqttMessage): string =>
  `${[
    message.id,
    message.createdAt,
    message.direction,
    message.topic,
    message.qos ?? '',
    message.retain ? 1 : 0,
    message.payloadText,
    message.parseError ?? '',
    message.source,
  ].map(csvCell).join(',')}\n`;

export const messageToJsonlRow = (message: MqttMessage): string => `${JSON.stringify(message)}\n`;

export const messagesToCsv = (messages: MqttMessage[]): string =>
  csvHeader() + messages.map(messageToCsvRow).join('');

export const messagesToJsonl = (messages: MqttMessage[]): string => messages.map(messageToJsonlRow).join('');
