import { EventEmitter } from 'node:events';
import mqtt, {
  type IClientOptions,
  type IClientPublishOptions,
  type ISubscriptionGrant,
  type MqttClient,
  type MqttClientEventCallbacks,
} from 'mqtt';
import type { AppConfig } from './config.js';
import { publicBrokerLabel } from './config.js';
import type { Database } from './db.js';
import type { AppStatus, LiveEvent, MqttConnectionState, MqttMessage, PublishRequest } from '../shared/types.js';
import { validatePublishRequest } from './presets.js';

export type MqttPublisher = {
  publish(topic: string, payload: string, options: { qos: 0 | 1 | 2; retain: boolean }): Promise<void>;
  end(force?: boolean): void;
  on(event: 'connect' | 'reconnect' | 'close' | 'offline' | 'error', listener: (error?: Error) => void): void;
  on(event: 'message', listener: (topic: string, payload: Buffer, packet: { qos?: number; retain?: boolean }) => void): void;
  subscribe(topics: string[], options: { qos: 0 | 1 | 2 }, callback: (error?: Error) => void): void;
};

type MqttFactory = (url: string, options: IClientOptions) => MqttPublisher;

export class MqttBridge {
  private client?: MqttPublisher;
  private state: MqttConnectionState = 'offline';
  private lastError?: string;
  private lastMessageAt?: string;
  private readonly events = new EventEmitter();

  constructor(
    private readonly config: AppConfig,
    private readonly db: Database,
    private readonly mqttFactory: MqttFactory = (url, options) => wrapMqttClient(mqtt.connect(url, options)),
  ) {}

  start(): void {
    this.state = 'connecting';
    this.client = this.mqttFactory(this.config.mqttUrl, {
      username: this.config.mqttUsername,
      password: this.config.mqttPassword,
      clean: true,
      reconnectPeriod: 5000,
      keepalive: 60,
    });

    this.client.on('connect', () => {
      this.state = 'online';
      this.lastError = undefined;
      this.client?.subscribe(this.config.mqttSubscribeTopics, { qos: this.config.mqttDefaultQos }, (error) => {
        if (error) {
          this.lastError = error.message;
          this.emitStatus();
        }
      });
      this.emitStatus();
    });
    this.client.on('reconnect', () => {
      this.state = 'connecting';
      this.emitStatus();
    });
    this.client.on('close', () => {
      this.state = 'offline';
      this.emitStatus();
    });
    this.client.on('offline', () => {
      this.state = 'offline';
      this.emitStatus();
    });
    this.client.on('error', (error) => {
      this.state = 'error';
      this.lastError = error?.message ?? 'MQTT connection error';
      this.emitStatus();
    });
    this.client.on('message', (topic, payload, packet) => {
      void this.storeInbound(topic, payload, packet).catch((error) => {
        this.lastError = error instanceof Error ? error.message : String(error);
        this.emitStatus();
      });
    });
  }

  stop(): void {
    this.client?.end(true);
    this.client = undefined;
    this.state = 'offline';
  }

  async publish(rawRequest: PublishRequest): Promise<MqttMessage> {
    const request = validatePublishRequest(rawRequest);
    if (!this.client) {
      throw new Error('MQTT client is not started');
    }
    await this.client.publish(request.topic, request.payload, {
      qos: request.qos ?? this.config.mqttDefaultQos,
      retain: Boolean(request.retain),
    });
    const payloadJson = request.payloadMode === 'json' ? JSON.parse(request.payload) : undefined;
    const id = await this.db.insertMessage({
      direction: 'outbound',
      topic: request.topic,
      payloadText: request.payload,
      payloadJson,
      qos: request.qos ?? this.config.mqttDefaultQos,
      retain: Boolean(request.retain),
      source: rawRequest.presetId ? `ui:preset:${rawRequest.presetId}` : 'ui:raw',
    });
    const [message] = await this.db.listMessages({ limit: 1 });
    if (!message || message.id !== id) {
      return {
        id,
        createdAt: new Date().toISOString(),
        direction: 'outbound',
        topic: request.topic,
        qos: request.qos ?? this.config.mqttDefaultQos,
        retain: Boolean(request.retain),
        payloadText: request.payload,
        payloadJson,
        payloadEncoding: 'utf8',
        payloadBytes: Buffer.byteLength(request.payload),
        source: rawRequest.presetId ? `ui:preset:${rawRequest.presetId}` : 'ui:raw',
      };
    }
    this.emitMessage(message);
    return message;
  }

  onEvent(listener: (event: LiveEvent) => void): () => void {
    this.events.on('event', listener);
    listener({
      type: 'status',
      status: this.mqttStatus(),
    });
    return () => {
      this.events.off('event', listener);
    };
  }

  async status(): Promise<AppStatus> {
    return {
      mqtt: this.mqttStatus(),
      database: await this.db.summary(),
    };
  }

  mqttStatus(): AppStatus['mqtt'] {
    return {
      state: this.state,
      broker: publicBrokerLabel(this.config.mqttUrl),
      subscribedTopics: this.config.mqttSubscribeTopics,
      lastMessageAt: this.lastMessageAt,
      lastError: this.lastError,
    };
  }

  private async storeInbound(topic: string, payload: Buffer, packet: { qos?: number; retain?: boolean }): Promise<void> {
    const payloadText = payload.toString('utf8');
    let payloadJson: unknown;
    let parseError: string | undefined;
    try {
      payloadJson = JSON.parse(payloadText);
    } catch (error) {
      parseError = error instanceof Error ? error.message : String(error);
    }
    const id = await this.db.insertMessage({
      direction: 'inbound',
      topic,
      payloadText,
      payloadJson,
      qos: packet.qos,
      retain: Boolean(packet.retain),
      parseError,
      source: 'mqtt',
    });
    const [message] = await this.db.listMessages({ limit: 1 });
    this.lastMessageAt = message?.createdAt ?? new Date().toISOString();
    if (message && message.id === id) {
      this.emitMessage(message);
    }
    this.emitStatus();
  }

  private emitMessage(message: MqttMessage): void {
    this.events.emit('event', {
      type: 'message',
      message,
    } satisfies LiveEvent);
  }

  private emitStatus(): void {
    this.events.emit('event', {
      type: 'status',
      status: this.mqttStatus(),
    } satisfies LiveEvent);
  }
}

const wrapMqttClient = (client: MqttClient): MqttPublisher => ({
  publish: (topic: string, payload: string, options: { qos: 0 | 1 | 2; retain: boolean }): Promise<void> =>
    new Promise((resolve, reject) => {
      client.publish(topic, payload, options as IClientPublishOptions, (error?: Error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    }),
  end: (force?: boolean): void => {
    client.end(Boolean(force));
  },
  on: ((event: string, listener: (...args: unknown[]) => void): void => {
    client.on(event as keyof MqttClientEventCallbacks, listener as MqttClientEventCallbacks[keyof MqttClientEventCallbacks]);
  }) as MqttPublisher['on'],
  subscribe: (topics: string[], options: { qos: 0 | 1 | 2 }, callback: (error?: Error) => void): void => {
    client.subscribe(topics, options, (error: Error | null, _granted?: ISubscriptionGrant[]) => callback(error ?? undefined));
  },
});
