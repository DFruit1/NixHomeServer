export type Direction = 'inbound' | 'outbound';
export type PayloadMode = 'json' | 'text';
export type MqttConnectionState = 'offline' | 'connecting' | 'online' | 'error';

export type MqttMessage = {
  id: number;
  createdAt: string;
  direction: Direction;
  topic: string;
  qos?: number;
  retain: boolean;
  payloadText: string;
  payloadJson?: unknown;
  payloadEncoding: string;
  payloadBytes: number;
  parseError?: string;
  source: string;
};

export type MessageFilters = {
  topic?: string;
  direction?: Direction;
  from?: string;
  to?: string;
  search?: string;
  limit?: number;
  offset?: number;
};

export type PublishRequest = {
  topic: string;
  payload: string;
  payloadMode: PayloadMode;
  qos?: 0 | 1 | 2;
  retain?: boolean;
  presetId?: string;
  confirm?: string;
};

export type PublishResult = {
  ok: true;
  messageId: number;
};

export type CommandPreset = {
  id: string;
  label: string;
  topic: string;
  payloadMode: PayloadMode;
  payload: string;
  qos: 0 | 1 | 2;
  retain: boolean;
  dangerous: boolean;
  dangerReason?: string;
};

export type AppStatus = {
  mqtt: {
    state: MqttConnectionState;
    broker: string;
    subscribedTopics: string[];
    lastMessageAt?: string;
    lastError?: string;
  };
  database: {
    latestMessageAt?: string;
    messageCount: number;
  };
};

export type TopicsResponse = {
  subscribedTopics: string[];
  observedTopics: string[];
};

export type LiveEvent =
  | {
      type: 'message';
      message: MqttMessage;
    }
  | {
      type: 'status';
      status: AppStatus['mqtt'];
    };
