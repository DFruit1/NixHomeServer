export type GeneratedSshKey = {
  privateKey: string;
  publicKey: string;
  fingerprint: string;
};

const encoder = new TextEncoder();

const concat = (parts: Uint8Array[]): Uint8Array => {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const output = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
};

const uint32 = (value: number): Uint8Array => {
  const output = new Uint8Array(4);
  new DataView(output.buffer).setUint32(0, value, false);
  return output;
};

const sshString = (value: Uint8Array | string): Uint8Array => {
  const bytes = typeof value === 'string' ? encoder.encode(value) : value;
  return concat([uint32(bytes.length), bytes]);
};

const toBase64 = (bytes: Uint8Array): string => {
  let binary = '';
  const chunkSize = 0x8000;
  for (let index = 0; index < bytes.length; index += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
  }
  return btoa(binary);
};

const randomUint32 = (): number => {
  const bytes = crypto.getRandomValues(new Uint8Array(4));
  return new DataView(bytes.buffer).getUint32(0, false);
};

const padPrivateSection = (section: Uint8Array): Uint8Array => {
  const blockSize = 8;
  const remainder = section.length % blockSize;
  if (remainder === 0) {
    return section;
  }
  const paddingLength = blockSize - remainder;
  const padding = new Uint8Array(paddingLength);
  for (let index = 0; index < paddingLength; index += 1) {
    padding[index] = index + 1;
  }
  return concat([section, padding]);
};

const wrapPem = (label: string, bytes: Uint8Array): string => {
  const base64 = toBase64(bytes);
  const lines = base64.match(/.{1,70}/g) ?? [];
  return `-----BEGIN ${label}-----\n${lines.join('\n')}\n-----END ${label}-----\n`;
};

const sshFingerprint = async (publicKeyBlob: Uint8Array): Promise<string> => {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', publicKeyBlob as unknown as BufferSource));
  return `SHA256:${toBase64(digest).replace(/=+$/, '')}`;
};

export const sshKeyGenerationSupported = (): boolean =>
  typeof crypto !== 'undefined' && typeof crypto.subtle?.generateKey === 'function';

export const generateEd25519SshKey = async (comment = ''): Promise<GeneratedSshKey> => {
  if (!sshKeyGenerationSupported()) {
    throw new Error('This browser cannot generate keys. Use a current browser or paste an existing public key.');
  }

  let pair: CryptoKeyPair;
  try {
    pair = (await crypto.subtle.generateKey({ name: 'Ed25519' } as AlgorithmIdentifier, true, ['sign', 'verify'])) as CryptoKeyPair;
  } catch {
    throw new Error('This browser does not support Ed25519 key generation. Paste an existing public key instead.');
  }

  const rawPublic = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  const seed = pkcs8.subarray(pkcs8.length - 32);
  const privateBlob = concat([seed, rawPublic]);

  const keyType = 'ssh-ed25519';
  const publicBlob = concat([sshString(keyType), sshString(rawPublic)]);
  const publicKey = `${keyType} ${toBase64(publicBlob)}${comment ? ` ${comment}` : ''}`;

  const checkInt = randomUint32();
  const privateSection = padPrivateSection(concat([
    uint32(checkInt),
    uint32(checkInt),
    sshString(keyType),
    sshString(rawPublic),
    sshString(privateBlob),
    sshString(comment),
  ]));

  return {
    privateKey: wrapPem('OPENSSH PRIVATE KEY', concat([
      encoder.encode('openssh-key-v1\0'),
      sshString('none'),
      sshString('none'),
      sshString(new Uint8Array(0)),
      uint32(1),
      sshString(publicBlob),
      sshString(privateSection),
    ])),
    publicKey,
    fingerprint: await sshFingerprint(publicBlob),
  };
};
