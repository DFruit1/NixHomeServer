import type { CommandPreset, PayloadMode, PublishRequest } from '../shared/types.js';

const jsonPreset = (
  id: string,
  label: string,
  topic: string,
  payload: unknown,
  dangerous = false,
  dangerReason?: string,
): CommandPreset => ({
  id,
  label,
  topic,
  payloadMode: 'json',
  payload: JSON.stringify(payload, null, 2),
  qos: 1,
  retain: false,
  dangerous,
  dangerReason,
});

export const commandPresets: CommandPreset[] = [
  jsonPreset('project-settings', 'Project settings', 'azman1/feeds/project-settings-slash-configuration', {
    NA: '3',
    l: 'Al',
    id: 'Salam there',
    fac: '1.10,1.10,1.10,1.10',
    fst: '26-05-05T11:55:00',
    lf: '00:02',
    sf: '00:10',
    mG: '0',
    MG: '67',
    S: '1011',
    ltost: '5:00',
  }),
  {
    id: 'request-test',
    label: 'Request test',
    topic: 'requesttesta',
    payloadMode: 'text',
    payload: '1',
    qos: 1,
    retain: false,
    dangerous: false,
  },
  jsonPreset(
    'cfg-desired',
    'Desired config',
    'cfg/desired',
    {
      Flush_mqtt: '1',
      Flush_sd: '1',
      Self_test: '1',
      Get_debuging: '1',
      Disable_Logging: '0',
    },
    true,
    'This preset can request MQTT or SD flush operations.',
  ),
  jsonPreset(
    'cmd-danger',
    'Danger command',
    'cmd/danger',
    {
      'Factory reset': '0',
      Wipe_mqtt: '1',
      Wipe_sd: '1',
      'Self test': '1',
      'Disable Logging': '0',
      Reboot: '0',
      'Erase keys': '0',
    },
    true,
    'This preset contains wipe, reset, reboot, erase, or self-test controls.',
  ),
];

const dangerousKeys = [
  'factory reset',
  'wipe_mqtt',
  'wipe sd',
  'wipe_sd',
  'flush_mqtt',
  'flush_sd',
  'self test',
  'self_test',
  'reboot',
  'erase keys',
  'erase_keys',
];

export const normalizeQos = (value: unknown, fallback: 0 | 1 | 2): 0 | 1 | 2 => {
  return value === 0 || value === 1 || value === 2 ? value : fallback;
};

export const validatePublishTopic = (topic: string): string => {
  const normalized = topic.trim();
  if (!normalized) {
    throw new Error('topic is required');
  }
  if (normalized.includes('#') || normalized.includes('+')) {
    throw new Error('publish topic must not contain MQTT wildcards');
  }
  if (normalized.includes('\u0000') || normalized.length > 65535) {
    throw new Error('publish topic is invalid');
  }
  return normalized;
};

export const parsePayload = (payload: string, payloadMode: PayloadMode): { payloadText: string; payloadJson?: unknown } => {
  if (payloadMode === 'text') {
    return { payloadText: payload };
  }
  try {
    const payloadJson = JSON.parse(payload);
    return {
      payloadText: JSON.stringify(payloadJson),
      payloadJson,
    };
  } catch {
    throw new Error('payload must be valid JSON');
  }
};

const truthyCommandValue = (value: unknown): boolean =>
  value === true || value === 1 || value === '1' || value === 'true' || value === 'yes' || value === 'on';

export const payloadHasDangerousCommand = (payloadJson: unknown): boolean => {
  if (!payloadJson || typeof payloadJson !== 'object' || Array.isArray(payloadJson)) {
    return false;
  }
  return Object.entries(payloadJson).some(([key, value]) => dangerousKeys.includes(key.trim().toLowerCase()) && truthyCommandValue(value));
};

export const validatePublishRequest = (request: PublishRequest): PublishRequest => {
  const topic = validatePublishTopic(request.topic);
  const payloadMode = request.payloadMode === 'text' ? 'text' : 'json';
  const parsed = parsePayload(request.payload, payloadMode);
  const preset = request.presetId ? commandPresets.find((item) => item.id === request.presetId) : undefined;
  const dangerous = Boolean(preset?.dangerous) || payloadHasDangerousCommand(parsed.payloadJson);
  if (dangerous && request.confirm !== 'DANGER') {
    throw new Error('type DANGER to publish this command');
  }
  return {
    ...request,
    topic,
    payload: parsed.payloadText,
    payloadMode,
    qos: normalizeQos(request.qos, 1),
    retain: Boolean(request.retain),
  };
};
