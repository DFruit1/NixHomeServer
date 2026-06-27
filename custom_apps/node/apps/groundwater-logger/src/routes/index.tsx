import { $, component$, useSignal, useStore, useVisibleTask$ } from '@builder.io/qwik';
import type { AppStatus, CommandPreset, Direction, MqttMessage, PayloadMode } from '../shared/types.js';

const preview = (text: string): string => (text.length > 140 ? `${text.slice(0, 140)}...` : text);

export default component$(() => {
  const status = useSignal<AppStatus>();
  const presets = useSignal<CommandPreset[]>([]);
  const messages = useSignal<MqttMessage[]>([]);
  const observedTopics = useSignal<string[]>([]);
  const error = useSignal('');
  const info = useSignal('');
  const expandedId = useSignal<number | undefined>();
  const publishing = useSignal(false);

  const publishForm = useStore({
    presetId: '',
    topic: 'cfg/desired',
    payloadMode: 'json' as PayloadMode,
    payload: '{\n  "Flush_mqtt": "1",\n  "Flush_sd": "1",\n  "Self_test": "1",\n  "Get_debuging": "1",\n  "Disable_Logging": "0"\n}',
    qos: 1 as 0 | 1 | 2,
    retain: false,
    confirm: '',
  });

  const filters = useStore({
    topic: '',
    direction: '' as '' | Direction,
    search: '',
    limit: 100,
  });

  const queryString = $(() => {
    const params = new URLSearchParams();
    if (filters.topic) {
      params.set('topic', filters.topic);
    }
    if (filters.direction) {
      params.set('direction', filters.direction);
    }
    if (filters.search) {
      params.set('search', filters.search);
    }
    params.set('limit', String(filters.limit));
    return params.toString();
  });

  const refresh = $(async () => {
    const [statusResponse, messagesResponse, presetsResponse, topicsResponse] = await Promise.all([
      fetch('/api/status'),
      fetch(`/api/messages?${await queryString()}`),
      fetch('/api/presets'),
      fetch('/api/topics'),
    ]);
    if (!statusResponse.ok || !messagesResponse.ok || !presetsResponse.ok || !topicsResponse.ok) {
      throw new Error('Could not load MQTT dashboard data');
    }
    status.value = await statusResponse.json();
    messages.value = await messagesResponse.json();
    presets.value = await presetsResponse.json();
    const topics = await topicsResponse.json();
    observedTopics.value = topics.observedTopics ?? [];
  });

  const applyPreset = $(() => {
    const preset = presets.value.find((item) => item.id === publishForm.presetId);
    if (!preset) {
      return;
    }
    publishForm.topic = preset.topic;
    publishForm.payloadMode = preset.payloadMode;
    publishForm.payload = preset.payload;
    publishForm.qos = preset.qos;
    publishForm.retain = preset.retain;
    publishForm.confirm = '';
  });

  const publish = $(async () => {
    publishing.value = true;
    error.value = '';
    info.value = '';
    try {
      const response = await fetch('/api/publish', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          topic: publishForm.topic,
          payload: publishForm.payload,
          payloadMode: publishForm.payloadMode,
          qos: publishForm.qos,
          retain: publishForm.retain,
          presetId: publishForm.presetId || undefined,
          confirm: publishForm.confirm || undefined,
        }),
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(body.error || 'Publish failed');
      }
      info.value = `Published message ${body.messageId}`;
      await refresh();
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      publishing.value = false;
    }
  });

  const exportHref = (format: 'csv' | 'jsonl') => `/api/messages/export?${filtersToQuery(filters, format)}`;

  useVisibleTask$(({ cleanup }) => {
    refresh().catch((caught) => {
      error.value = caught instanceof Error ? caught.message : String(caught);
    });
    const events = new EventSource('/api/events');
    events.onmessage = (event) => {
      const live = JSON.parse(event.data);
      if (live.type === 'status' && status.value) {
        status.value = {
          ...status.value,
          mqtt: live.status,
        };
      }
      if (live.type === 'message') {
        messages.value = [live.message, ...messages.value].slice(0, filters.limit);
        if (!observedTopics.value.includes(live.message.topic)) {
          observedTopics.value = [...observedTopics.value, live.message.topic].sort();
        }
      }
    };
    events.onerror = () => {
      error.value = 'Live event stream disconnected';
    };
    const timer = window.setInterval(() => {
      refresh().catch(() => undefined);
    }, 10000);
    cleanup(() => {
      events.close();
      window.clearInterval(timer);
    });
  });

  const currentPreset = presets.value.find((item) => item.id === publishForm.presetId);

  return (
    <main class="shell">
      <section class="topbar">
        <div>
          <h1>Groundwater Logger</h1>
          <p>{status.value?.mqtt.broker ?? 'Loading broker'}</p>
        </div>
        <div class={`status-pill ${status.value?.mqtt.state ?? 'connecting'}`}>
          <span />
          {status.value?.mqtt.state ?? 'connecting'}
        </div>
      </section>

      <section class="metrics">
        <div>
          <span>Subscribed</span>
          <strong>{status.value?.mqtt.subscribedTopics.length ?? 0}</strong>
        </div>
        <div>
          <span>Stored</span>
          <strong>{status.value?.database.messageCount ?? 0}</strong>
        </div>
        <div>
          <span>Latest</span>
          <strong>{status.value?.database.latestMessageAt ?? 'None'}</strong>
        </div>
      </section>

      {(error.value || info.value || status.value?.mqtt.lastError) && (
        <section class={{ notice: true, error: Boolean(error.value || status.value?.mqtt.lastError) }}>
          {error.value || status.value?.mqtt.lastError || info.value}
        </section>
      )}

      <section class="workspace">
        <form
          class="publisher"
          preventdefault:submit
          onSubmit$={() => {
            void publish();
          }}
        >
          <div class="section-title">
            <h2>Publish</h2>
            <button type="submit" disabled={publishing.value}>
              {publishing.value ? 'Publishing' : 'Publish'}
            </button>
          </div>

          <label>
            <span>Preset</span>
            <select
              value={publishForm.presetId}
              onChange$={(_, target) => {
                publishForm.presetId = target.value;
                void applyPreset();
              }}
            >
              <option value="">Raw message</option>
              {presets.value.map((preset) => (
                <option key={preset.id} value={preset.id}>
                  {preset.label}
                </option>
              ))}
            </select>
          </label>

          <label>
            <span>Topic</span>
            <input value={publishForm.topic} onInput$={(_, target) => (publishForm.topic = target.value)} />
          </label>

          <div class="inline-controls">
            <label>
              <span>Mode</span>
              <select value={publishForm.payloadMode} onChange$={(_, target) => (publishForm.payloadMode = target.value as PayloadMode)}>
                <option value="json">JSON</option>
                <option value="text">Text</option>
              </select>
            </label>
            <label>
              <span>QoS</span>
              <select value={publishForm.qos} onChange$={(_, target) => (publishForm.qos = Number(target.value) as 0 | 1 | 2)}>
                <option value={0}>0</option>
                <option value={1}>1</option>
                <option value={2}>2</option>
              </select>
            </label>
            <label class="checkbox">
              <input type="checkbox" checked={publishForm.retain} onChange$={(_, target) => (publishForm.retain = target.checked)} />
              <span>Retain</span>
            </label>
          </div>

          <label>
            <span>Payload</span>
            <textarea value={publishForm.payload} onInput$={(_, target) => (publishForm.payload = target.value)} />
          </label>

          {currentPreset?.dangerous && (
            <label class="danger-confirm">
              <span>Confirmation</span>
              <input
                value={publishForm.confirm}
                onInput$={(_, target) => (publishForm.confirm = target.value)}
                placeholder="DANGER"
              />
              <small>{currentPreset.dangerReason}</small>
            </label>
          )}
        </form>

        <section class="messages">
          <div class="section-title">
            <h2>Messages</h2>
            <div class="downloads">
              <a href={exportHref('csv')}>CSV</a>
              <a href={exportHref('jsonl')}>JSONL</a>
            </div>
          </div>

          <div class="filters">
            <label>
              <span>Topic</span>
              <input value={filters.topic} onInput$={(_, target) => (filters.topic = target.value)} />
            </label>
            <label>
              <span>Direction</span>
              <select value={filters.direction} onChange$={(_, target) => (filters.direction = target.value as '' | Direction)}>
                <option value="">All</option>
                <option value="inbound">Inbound</option>
                <option value="outbound">Outbound</option>
              </select>
            </label>
            <label>
              <span>Search</span>
              <input value={filters.search} onInput$={(_, target) => (filters.search = target.value)} />
            </label>
            <button
              type="button"
              onClick$={() => {
                void refresh();
              }}
            >
              Apply
            </button>
          </div>

          <div class="table">
            <div class="table-head">
              <span>Time</span>
              <span>Direction</span>
              <span>Topic</span>
              <span>Payload</span>
            </div>
            {messages.value.map((message) => (
              <button
                key={message.id}
                type="button"
                class={{ row: true, expanded: expandedId.value === message.id }}
                onClick$={() => (expandedId.value = expandedId.value === message.id ? undefined : message.id)}
              >
                <span>{message.createdAt}</span>
                <span class={`direction ${message.direction}`}>{message.direction}</span>
                <span>{message.topic}</span>
                <span>{preview(message.payloadText)}</span>
                {expandedId.value === message.id && (
                  <pre>
                    {message.payloadText}
                    {message.parseError ? `\n\nParse error: ${message.parseError}` : ''}
                  </pre>
                )}
              </button>
            ))}
          </div>
        </section>
      </section>
    </main>
  );
});

const filtersToQuery = (filters: { topic: string; direction: string; search: string; limit: number }, format: 'csv' | 'jsonl'): string => {
  const params = new URLSearchParams();
  params.set('format', format);
  if (filters.topic) {
    params.set('topic', filters.topic);
  }
  if (filters.direction) {
    params.set('direction', filters.direction);
  }
  if (filters.search) {
    params.set('search', filters.search);
  }
  params.set('limit', String(filters.limit));
  return params.toString();
};
