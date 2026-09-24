import { describe, expect, it } from 'vitest';
import { shouldQueueLocally } from '../client/queue-fallback.js';

describe('shouldQueueLocally', () => {
  it('never queues in the browser runtime', () => {
    expect(shouldQueueLocally(new Error('network down'), false)).toBe(false);
  });

  it('queues transport failures reported as plain strings', () => {
    expect(shouldQueueLocally('error sending request', true)).toBe(true);
  });

  it('queues errors without an HTTP status', () => {
    expect(shouldQueueLocally(new Error('network down'), true)).toBe(true);
  });

  it('queues when the session is missing or expired', () => {
    const unauthorized = Object.assign(new Error('Authentication is required'), { httpStatus: 401 });
    const forbidden = Object.assign(new Error('not authorised'), { httpStatus: 403 });
    expect(shouldQueueLocally(unauthorized, true)).toBe(true);
    expect(shouldQueueLocally(forbidden, true)).toBe(true);
  });

  it('keeps other server rejections as errors', () => {
    const invalid = Object.assign(new Error('A valid YouTube URL is required.'), { httpStatus: 400 });
    const conflict = Object.assign(new Error('already queued'), { httpStatus: 409 });
    expect(shouldQueueLocally(invalid, true)).toBe(false);
    expect(shouldQueueLocally(conflict, true)).toBe(false);
  });
});
