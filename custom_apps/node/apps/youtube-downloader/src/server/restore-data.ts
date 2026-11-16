import { createHash, type Hash } from 'node:crypto';
import { closeSync, createReadStream, fstatSync, openSync, readSync, writeSync } from 'node:fs';

/*
 * The restore file: everything needed, beside the chapter files, to rebuild
 * the original file a split was cut from byte for byte.
 *
 * A media file is its coded streams (the audio and video packets) plus
 * container bytes around them: headers, timestamps, indexes, tags, cover art.
 * A chapter split keeps every packet, so the chapter files already hold the
 * streams; what they do not hold is the original's container. The restore
 * file stores exactly those bytes, and a map saying where each run of stream
 * data sat between them.
 *
 * The map refers to each stream's *raw data*: its packets end to end, as
 * `ffmpeg -c copy -f data` writes them. Reading the chapter files in order
 * gives that same raw data whatever has since happened to their own tags or
 * covers, so a restore keeps working after the chapters are re-tagged.
 *
 * Layout (integers little-endian, varints unsigned LEB128):
 *
 *   "YTDLRST1"                      8 bytes
 *   header length                   u32
 *   header                          JSON, see `RestoreHeader`
 *   records                         `recordBytes` bytes, `recordCount` of:
 *     literal   varint   container bytes to copy from the literal section
 *     stream    u8       which stream's raw data follows them
 *     skip      varint   raw-data bytes of that stream to pass over first
 *     copy      varint   raw-data bytes of that stream to copy
 *   literal section                 `literalBytes` bytes
 *
 * Rebuilding walks the records in order and writes `literal` bytes, then
 * `copy` bytes of stream data; the result must have the recorded size and
 * SHA-256. Media Manager reads the same format (`youtube_restore.rs`).
 */
export const RESTORE_MAGIC = 'YTDLRST1';
export const RESTORE_VERSION = 1;

export type RestoreHeader = {
  version: typeof RESTORE_VERSION;
  originalSize: number;
  originalSha256: string;
  /** Size and SHA-256 of each stream's raw data, in programme order. */
  streams: { bytes: number; sha256: string }[];
  recordCount: number;
  recordBytes: number;
  literalBytes: number;
};

/** One coded packet of the original: which stream, where ffprobe saw it, how long. */
export type PacketList = {
  stream: number[];
  /** Byte position in the file, or -1 when the demuxer does not report one. */
  pos: number[];
  size: number[];
};

const CHUNK = 1024 * 1024;
const yieldToEventLoop = (): Promise<void> => new Promise((resolve) => setImmediate(resolve));

export const sha256File = (file: string): Promise<{ sha256: string; bytes: number }> =>
  new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    let bytes = 0;
    createReadStream(file, { highWaterMark: CHUNK })
      .on('data', (chunk) => {
        hash.update(chunk);
        bytes += chunk.length;
      })
      .on('error', reject)
      .on('end', () => resolve({ sha256: hash.digest('hex'), bytes }));
  });

/** Feed a whole file into `hashes`, returning its length. */
export const hashFileInto = (file: string, hashes: Hash[]): Promise<number> =>
  new Promise((resolve, reject) => {
    let bytes = 0;
    createReadStream(file, { highWaterMark: CHUNK })
      .on('data', (chunk) => {
        for (const hash of hashes) {
          hash.update(chunk);
        }
        bytes += chunk.length;
      })
      .on('error', reject)
      .on('end', () => resolve(bytes));
  });

/** `stream_index=…,size=…,pos=…` lines of `ffprobe -of csv=p=0:nk=0`, for the listed streams. */
export const parsePacketList = (output: string, streamIndexes: number[]): PacketList => {
  const packets: PacketList = { stream: [], pos: [], size: [] };
  let lineStart = 0;
  while (lineStart < output.length) {
    let lineEnd = output.indexOf('\n', lineStart);
    if (lineEnd < 0) {
      lineEnd = output.length;
    }
    const line = output.slice(lineStart, lineEnd);
    lineStart = lineEnd + 1;
    const index = /(?:^|,)stream_index=(\d+)/.exec(line)?.[1];
    const size = /(?:^|,)size=(\d+)/.exec(line)?.[1];
    if (index == null || size == null) {
      continue;
    }
    const stream = streamIndexes.indexOf(Number.parseInt(index, 10));
    if (stream < 0) {
      continue;
    }
    const pos = /(?:^|,)pos=(\d+)/.exec(line)?.[1];
    packets.stream.push(stream);
    packets.size.push(Number.parseInt(size, 10));
    packets.pos.push(pos == null ? -1 : Number.parseInt(pos, 10));
  }
  return packets;
};

const encodeVarint = (value: number, into: number[]): void => {
  let rest = value;
  while (rest >= 128) {
    into.push((rest % 128) + 128);
    rest = Math.floor(rest / 128);
  }
  into.push(rest);
};

const readExact = (fd: number, buffer: Buffer, length: number, position: number): number => {
  let done = 0;
  while (done < length) {
    const read = readSync(fd, buffer, done, length - done, position + done);
    if (read === 0) {
      break;
    }
    done += read;
  }
  return done;
};

type Located = { file: number; length: number; stream: number; dump: number };

/*
 * Find where each packet's bytes sit in the original. ffprobe's position is
 * exact for some containers (MP4, FLAC, MP3, WAV) and the start of the
 * enclosing block or page for others (Matroska, Ogg), so the packet is looked
 * for from there, a little further each time. A packet that is not found
 * whole (an Ogg packet split across pages) simply stays in the literal bytes.
 * Any place the same bytes occur rebuilds the same file, so a match never has
 * to be the "true" one for the result to be exact.
 */
const SLACK = [0, 64, 4096];
// Later packets of one Ogg page share the page's position.
const SAME_PAGE = 70_000;

const locatePackets = async (original: number, dumps: number[], packets: PacketList): Promise<Located[]> => {
  const cursor = dumps.map(() => 0);
  const lastEnd = dumps.map(() => 0);
  const located: Located[] = [];
  let payload = Buffer.alloc(64 * 1024);
  let window = Buffer.alloc(64 * 1024 + SLACK[SLACK.length - 1]);
  for (let index = 0; index < packets.size.length; index += 1) {
    if (index % 2000 === 1999) {
      await yieldToEventLoop();
    }
    const stream = packets.stream[index];
    const size = packets.size[index];
    const dump = cursor[stream];
    cursor[stream] += size;
    if (size === 0) {
      continue;
    }
    if (payload.length < size) {
      payload = Buffer.alloc(size * 2);
      window = Buffer.alloc(size * 2 + SLACK[SLACK.length - 1]);
    }
    if (readExact(dumps[stream], payload, size, dump) !== size) {
      throw new Error('a stream is shorter than its packet list');
    }
    let start = packets.pos[index] >= 0 ? packets.pos[index] : lastEnd[stream];
    if (lastEnd[stream] > start && lastEnd[stream] - start <= SAME_PAGE) {
      start = lastEnd[stream];
    }
    const wanted = payload.subarray(0, size);
    for (const slack of SLACK) {
      const available = readExact(original, window, size + slack, start);
      const hit = window.subarray(0, available).indexOf(wanted);
      if (hit >= 0) {
        located.push({ file: start + hit, length: size, stream, dump });
        lastEnd[stream] = start + hit + size;
        break;
      }
    }
  }
  return located;
};

export type BuildRestoreInput = {
  original: string;
  originalSha256: string;
  /** Raw data of each programme stream of the original, in programme order. */
  dumps: { file: string; bytes: number; sha256: string }[];
  packets: PacketList;
  output: string;
};

export const buildRestoreFile = async (input: BuildRestoreInput): Promise<RestoreHeader> => {
  const original = openSync(input.original, 'r');
  const dumps = input.dumps.map((dump) => openSync(dump.file, 'r'));
  let output: number | undefined;
  try {
    const originalSize = fstatSync(original).size;
    const located = await locatePackets(original, dumps, input.packets);
    located.sort((a, b) => a.file - b.file);

    // Records: runs of stream data that are contiguous in the file and in the
    // stream's raw data merge into one.
    const records: number[] = [];
    const literals: { from: number; to: number }[] = [];
    const cursor = dumps.map(() => 0);
    let fileCursor = 0;
    let recordCount = 0;
    let literalBytes = 0;
    let pending: { literal: number; stream: number; skip: number; copy: number } | undefined;
    const flush = (): void => {
      if (pending) {
        encodeVarint(pending.literal, records);
        records.push(pending.stream);
        encodeVarint(pending.skip, records);
        encodeVarint(pending.copy, records);
        recordCount += 1;
        pending = undefined;
      }
    };
    for (const run of located) {
      // A packet found overlapping one already placed, or behind its stream's
      // cursor, stays literal.
      if (run.file < fileCursor || run.dump < cursor[run.stream]) {
        continue;
      }
      const literal = run.file - fileCursor;
      const skip = run.dump - cursor[run.stream];
      if (pending && literal === 0 && skip === 0 && pending.stream === run.stream) {
        pending.copy += run.length;
      } else {
        flush();
        if (literal > 0) {
          literals.push({ from: fileCursor, to: run.file });
          literalBytes += literal;
        }
        pending = { literal, stream: run.stream, skip, copy: run.length };
      }
      fileCursor = run.file + run.length;
      cursor[run.stream] = run.dump + run.length;
    }
    flush();
    if (fileCursor < originalSize) {
      pending = { literal: originalSize - fileCursor, stream: 0, skip: 0, copy: 0 };
      literals.push({ from: fileCursor, to: originalSize });
      literalBytes += originalSize - fileCursor;
      flush();
    }

    const header: RestoreHeader = {
      version: RESTORE_VERSION,
      originalSize,
      originalSha256: input.originalSha256,
      streams: input.dumps.map((dump) => ({ bytes: dump.bytes, sha256: dump.sha256 })),
      recordCount,
      recordBytes: records.length,
      literalBytes,
    };
    const headerJson = Buffer.from(JSON.stringify(header), 'utf8');
    const prefix = Buffer.alloc(12);
    prefix.write(RESTORE_MAGIC, 0, 'latin1');
    prefix.writeUInt32LE(headerJson.length, 8);
    output = openSync(input.output, 'wx', 0o660);
    writeSync(output, prefix);
    writeSync(output, headerJson);
    writeSync(output, Buffer.from(records));
    const buffer = Buffer.alloc(CHUNK);
    for (const literal of literals) {
      for (let position = literal.from; position < literal.to; ) {
        const want = Math.min(CHUNK, literal.to - position);
        if (readExact(original, buffer, want, position) !== want) {
          throw new Error('the original ended while its container bytes were being saved');
        }
        writeSync(output, buffer, 0, want);
        position += want;
      }
      await yieldToEventLoop();
    }
    return header;
  } finally {
    closeSync(original);
    dumps.forEach((dump) => closeSync(dump));
    if (output != null) {
      closeSync(output);
    }
  }
};

const readVarint = (bytes: Buffer, at: { offset: number }): number => {
  let value = 0;
  let scale = 1;
  for (;;) {
    if (at.offset >= bytes.length) {
      throw new Error('the restore file ends inside a record');
    }
    const byte = bytes[at.offset];
    at.offset += 1;
    value += (byte % 128) * scale;
    if (byte < 128) {
      return value;
    }
    scale *= 128;
  }
};

/**
 * Rebuild the original from a restore file and each stream's raw data,
 * handing the bytes to `write` in order. Returns the restore file's header;
 * the caller checks the result against `originalSha256`.
 */
export const rebuildOriginal = async (restoreFile: string, dumpFiles: string[], write: (chunk: Buffer) => void): Promise<RestoreHeader> => {
  const restore = openSync(restoreFile, 'r');
  const dumps = dumpFiles.map((file) => openSync(file, 'r'));
  try {
    const prefix = Buffer.alloc(12);
    if (readExact(restore, prefix, 12, 0) !== 12 || prefix.toString('latin1', 0, 8) !== RESTORE_MAGIC) {
      throw new Error('not a restore file');
    }
    const headerLength = prefix.readUInt32LE(8);
    const headerBytes = Buffer.alloc(headerLength);
    readExact(restore, headerBytes, headerLength, 12);
    const header = JSON.parse(headerBytes.toString('utf8')) as RestoreHeader;
    if (header.version !== RESTORE_VERSION || header.streams.length !== dumps.length) {
      throw new Error('the restore file does not match these streams');
    }
    const records = Buffer.alloc(header.recordBytes);
    if (readExact(restore, records, header.recordBytes, 12 + headerLength) !== header.recordBytes) {
      throw new Error('the restore file is truncated');
    }
    let literalAt = 12 + headerLength + header.recordBytes;
    const cursor = dumps.map(() => 0);
    const buffer = Buffer.alloc(CHUNK);
    const copy = (fd: number, position: number, length: number): void => {
      for (let done = 0; done < length; ) {
        const want = Math.min(CHUNK, length - done);
        if (readExact(fd, buffer, want, position + done) !== want) {
          throw new Error('a stream or the restore file is shorter than recorded');
        }
        // `write` may keep the chunk, so it gets its own copy.
        write(Buffer.from(buffer.subarray(0, want)));
        done += want;
      }
    };
    const at = { offset: 0 };
    for (let record = 0; record < header.recordCount; record += 1) {
      if (record % 2000 === 1999) {
        await yieldToEventLoop();
      }
      const literal = readVarint(records, at);
      const stream = records[at.offset];
      at.offset += 1;
      const skip = readVarint(records, at);
      const length = readVarint(records, at);
      if (stream >= dumps.length) {
        throw new Error('the restore file names a stream that does not exist');
      }
      copy(restore, literalAt, literal);
      literalAt += literal;
      cursor[stream] += skip;
      copy(dumps[stream], cursor[stream], length);
      cursor[stream] += length;
    }
    return header;
  } finally {
    closeSync(restore);
    dumps.forEach((dump) => closeSync(dump));
  }
};

/** Rebuild into a hash only, to prove a restore file before the original is let go. */
export const rebuiltSha256 = async (restoreFile: string, dumpFiles: string[]): Promise<{ sha256: string; bytes: number }> => {
  const hash = createHash('sha256');
  let bytes = 0;
  await rebuildOriginal(restoreFile, dumpFiles, (chunk) => {
    hash.update(chunk);
    bytes += chunk.length;
  });
  return { sha256: hash.digest('hex'), bytes };
};
