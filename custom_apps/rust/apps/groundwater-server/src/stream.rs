//! `data/stream` batches ("GWB1") and `data/file` chunks ("GWF1").
//!
//! Wire contract: `docs/gwl-v1-rev2.md` §4 and Rev2 "MQTT data/stream" /
//! "Zone 5 — the ring". Everything is little-endian.
//!
//! A batch is a 32-byte header, whole ring frames and a CRC-32 over every byte
//! before it. Each frame is `A5 5A | type | len | seq u32 | payload | crc8`,
//! where the CRC-8/AUTOSAR covers `type .. payload` (not the magic).
//!
//! The firmware sends the bytes either raw (`AT+QMTPUBEX`) or as ASCII hex
//! through `AT+QMTPUB` when the modem cannot publish binary. The magic decides:
//! a payload beginning with the bytes `GWB1` is binary, one beginning with the
//! ASCII text `47574231` is hex. Both decode to the same bytes.
//!
//! This module is pure: it validates and splits bytes, and leaves dedupe,
//! storage and time reconstruction to [`crate::rev2_store`].

use crate::crc::{crc32, crc8_autosar};

pub const BATCH_MAGIC: &[u8; 4] = b"GWB1";
pub const FILE_MAGIC: &[u8; 4] = b"GWF1";
pub const BATCH_HEADER_LEN: usize = 32;
/// Rev2: at most 1,464 bytes of frames per message, 1,500 bytes in total.
pub const MAX_BATCH_BYTES: usize = 1500;
/// `data/file`: at most 1,024 data bytes per chunk.
pub const MAX_FILE_CHUNK_DATA: usize = 1024;
pub const FILE_HEADER_LEN: usize = 18;
pub const FRAME_MAGIC: [u8; 2] = [0xA5, 0x5A];
pub const FRAME_OVERHEAD: usize = 9;
/// Largest damaged item the firmware sends (contract: CRC-invalid bytes go
/// in chunks of at most 264 bytes, one maximum frame).
pub const DAMAGED_ITEM_MAX: usize = 264;
/// Envelope (frame format) version this decoder understands.
pub const ENVELOPE_VERSION: u8 = 1;
/// Payload schemas this decoder understands (`records.rs`).
pub const SUPPORTED_PAYLOAD_SCHEMAS: [u16; 1] = [1];

/// How the payload travelled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Encoding {
    Binary,
    Hex,
}

impl Encoding {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Binary => "bin",
            Self::Hex => "hex",
        }
    }
}

/// Why a whole message was refused. The raw bytes are still stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamError {
    /// Neither the binary nor the hex magic.
    BadMagic,
    /// Hex form with an odd length or a non-hex character.
    BadHex,
    /// Shorter than its own header plus CRC.
    Truncated,
    /// Larger than the protocol allows.
    TooLarge(usize),
    /// CRC-32 over the message does not match.
    BadCrc { expected: u32, actual: u32 },
    /// `header_len` below 32.
    BadHeaderLength(u8),
    /// The data length field does not match the payload.
    LengthMismatch { declared: usize, actual: usize },
}

impl StreamError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::BadMagic => "bad-magic",
            Self::BadHex => "bad-hex",
            Self::Truncated => "truncated",
            Self::TooLarge(_) => "too-large",
            Self::BadCrc { .. } => "bad-crc32",
            Self::BadHeaderLength(_) => "bad-header-length",
            Self::LengthMismatch { .. } => "length-mismatch",
        }
    }
}

impl std::fmt::Display for StreamError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadMagic => f.write_str("payload has neither the binary nor the hex magic"),
            Self::BadHex => f.write_str("hex payload has an odd length or a non-hex character"),
            Self::Truncated => f.write_str("payload is shorter than its header and CRC"),
            Self::TooLarge(n) => {
                write!(f, "payload decodes to {n} bytes, above the protocol limit")
            }
            Self::BadCrc { expected, actual } => {
                write!(
                    f,
                    "CRC-32 mismatch: message says {expected:08X}, bytes give {actual:08X}"
                )
            }
            Self::BadHeaderLength(n) => write!(f, "header_len {n} is below 32"),
            Self::LengthMismatch { declared, actual } => {
                write!(
                    f,
                    "declared length {declared} but {actual} bytes are present"
                )
            }
        }
    }
}

/// Decodes the binary or hex form of a message whose binary form starts with
/// `magic`.
pub fn decode_payload(payload: &[u8], magic: &[u8; 4]) -> Result<(Vec<u8>, Encoding), StreamError> {
    if payload.starts_with(magic) {
        return Ok((payload.to_vec(), Encoding::Binary));
    }
    let hex_magic: String = magic.iter().map(|b| format!("{b:02X}")).collect();
    // Tolerate a trailing newline from a terminal-style publisher; nothing else.
    let text = payload.strip_suffix(b"\n").unwrap_or(payload);
    let text = text.strip_suffix(b"\r").unwrap_or(text);
    if text.len() >= 8 && text[..8].eq_ignore_ascii_case(hex_magic.as_bytes()) {
        return hex_decode(text)
            .map(|bytes| (bytes, Encoding::Hex))
            .ok_or(StreamError::BadHex);
    }
    Err(StreamError::BadMagic)
}

pub fn hex_decode(text: &[u8]) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    let digit = |c: u8| -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            b'A'..=b'F' => Some(c - b'A' + 10),
            _ => None,
        }
    };
    text.chunks(2)
        .map(|pair| Some(digit(pair[0])? << 4 | digit(pair[1])?))
        .collect()
}

pub fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02X}")).collect()
}

fn u16_at(bytes: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([bytes[at], bytes[at + 1]])
}
fn u32_at(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

/// The 32-byte `GWB1` header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BatchHeader {
    pub header_len: u8,
    pub envelope_version: u8,
    pub payload_schema: u16,
    pub log_id: u32,
    pub first_seq: u32,
    pub last_seq: u32,
    pub start_pos: u32,
    pub end_pos: u32,
    pub frame_count: u16,
    pub flags: u8,
}

impl BatchHeader {
    /// bit0: the batch is a resend.
    pub fn resend(&self) -> bool {
        self.flags & 0x01 != 0
    }
    /// bit1: this destination permanently missed data before `start_pos`.
    pub fn gap_before(&self) -> bool {
        self.flags & 0x02 != 0
    }
    /// bit2: the frames were read back from the SD archive.
    pub fn read_from_sd(&self) -> bool {
        self.flags & 0x04 != 0
    }
}

/// One ring frame whose CRC-8 matched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    /// Byte offset inside the frame area of the batch.
    pub offset: usize,
    /// Logical ring position, when the batch's positions are consistent.
    pub pos: Option<u32>,
    pub record_type: u8,
    pub seq: u32,
    pub payload: Vec<u8>,
    /// The exact frame bytes, magic and CRC included.
    pub raw: Vec<u8>,
}

impl Frame {
    pub fn size(&self) -> usize {
        self.raw.len()
    }
}

/// A part of the frame area that did not parse as a valid frame. The bytes
/// remain in the stored raw batch; decoders resynchronise after them.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct FrameIssue {
    pub offset: usize,
    pub length: usize,
    pub code: &'static str,
    /// Sequence from the damaged header, untrusted.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claimed_seq: Option<u32>,
}

/// A verified batch, split into frames.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    pub header: BatchHeader,
    pub frames: Vec<Frame>,
    pub issues: Vec<FrameIssue>,
    /// Header-level inconsistencies that did not stop decoding.
    pub warnings: Vec<String>,
    /// True when `end_pos - start_pos` equals the frame bytes, so every frame
    /// has a trustworthy logical position.
    pub positions_valid: bool,
}

/// Validates a decoded `GWB1` message and splits its frames.
pub fn parse_batch(bytes: &[u8]) -> Result<Batch, StreamError> {
    if !bytes.starts_with(BATCH_MAGIC) {
        return Err(StreamError::BadMagic);
    }
    if bytes.len() > MAX_BATCH_BYTES {
        return Err(StreamError::TooLarge(bytes.len()));
    }
    if bytes.len() < BATCH_HEADER_LEN + 4 {
        return Err(StreamError::Truncated);
    }
    let body = bytes.len() - 4;
    let expected = u32_at(bytes, body);
    let actual = crc32(&bytes[..body]);
    if expected != actual {
        return Err(StreamError::BadCrc { expected, actual });
    }
    let header = BatchHeader {
        header_len: bytes[4],
        envelope_version: bytes[5],
        payload_schema: u16_at(bytes, 6),
        log_id: u32_at(bytes, 8),
        first_seq: u32_at(bytes, 12),
        last_seq: u32_at(bytes, 16),
        start_pos: u32_at(bytes, 20),
        end_pos: u32_at(bytes, 24),
        frame_count: u16_at(bytes, 28),
        flags: bytes[30],
    };
    let header_len = usize::from(header.header_len);
    if header_len < BATCH_HEADER_LEN {
        return Err(StreamError::BadHeaderLength(header.header_len));
    }
    if header_len > body {
        return Err(StreamError::Truncated);
    }
    let area = &bytes[header_len..body];
    let mut warnings = Vec::new();
    let positions_valid = header.end_pos.wrapping_sub(header.start_pos) as usize == area.len()
        && header.end_pos >= header.start_pos;
    if !positions_valid {
        warnings.push(format!(
            "end_pos - start_pos = {} but the frame area is {} bytes; positions ignored",
            i64::from(header.end_pos) - i64::from(header.start_pos),
            area.len()
        ));
    }
    let (mut frames, issues) = split_frames(area);
    if positions_valid {
        for frame in &mut frames {
            frame.pos = Some(header.start_pos.wrapping_add(frame.offset as u32));
        }
    }
    // The firmware counts each damaged item in frame_count.
    let damaged_items = issues.len();
    if frames.len() + damaged_items != usize::from(header.frame_count) {
        warnings.push(format!(
            "header says {} frames, found {} valid and {} damaged",
            header.frame_count,
            frames.len(),
            damaged_items
        ));
    }
    if let (Some(first), Some(last)) = (frames.first(), frames.last())
        && issues.is_empty()
        && (first.seq != header.first_seq || last.seq != header.last_seq)
    {
        warnings.push(format!(
            "header seq range {}..{} differs from frames {}..{}",
            header.first_seq, header.last_seq, first.seq, last.seq
        ));
    }
    Ok(Batch {
        header,
        frames,
        issues,
        warnings,
        positions_valid,
    })
}

/// Parses a frame starting at `at`, verifying its CRC-8.
fn frame_at(area: &[u8], at: usize) -> Result<Frame, (&'static str, Option<u32>)> {
    let rest = &area[at..];
    if rest.len() < FRAME_OVERHEAD {
        return Err(("truncated-frame", None));
    }
    if rest[..2] != FRAME_MAGIC {
        return Err(("bad-frame-magic", None));
    }
    let length = usize::from(rest[3]);
    let size = length + FRAME_OVERHEAD;
    let seq = u32_at(rest, 4);
    if rest.len() < size {
        return Err(("truncated-frame", Some(seq)));
    }
    if rest[2] == 0xFF {
        return Err(("reserved-type-255", Some(seq)));
    }
    if crc8_autosar(&rest[2..8 + length]) != rest[8 + length] {
        return Err(("bad-crc8", Some(seq)));
    }
    Ok(Frame {
        offset: at,
        pos: None,
        record_type: rest[2],
        seq,
        payload: rest[8..8 + length].to_vec(),
        raw: rest[..size].to_vec(),
    })
}

/// Splits a frame area exactly as the firmware cuts it (`gwl_batch.c`
/// `range_peek`): bytes that are not a CRC-valid frame form one damaged item
/// that ends at the first later offset holding a CRC-valid frame, and is at
/// most [`DAMAGED_ITEM_MAX`] bytes long. A damaged length byte is never
/// trusted (Rev2 "Faults and recovery": decoders resynchronise on magic and
/// CRC), so a valid frame right after a damaged one is never skipped.
pub fn split_frames(area: &[u8]) -> (Vec<Frame>, Vec<FrameIssue>) {
    let mut frames = Vec::new();
    let mut issues = Vec::new();
    let mut at = 0;
    while at < area.len() {
        match frame_at(area, at) {
            Ok(frame) => {
                at += frame.size();
                frames.push(frame);
            }
            Err((code, claimed_seq)) => {
                let limit = (area.len() - at).min(DAMAGED_ITEM_MAX);
                let length = (1..limit)
                    .find(|&skip| frame_at(area, at + skip).is_ok())
                    .unwrap_or(limit);
                issues.push(FrameIssue {
                    offset: at,
                    length,
                    code,
                    claimed_seq,
                });
                at += length;
            }
        }
    }
    (frames, issues)
}

/// One `data/file` chunk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileChunk {
    pub command_id: u32,
    pub offset: u32,
    pub total_size: u32,
    pub data: Vec<u8>,
}

/// Validates a decoded `GWF1` message.
pub fn parse_file_chunk(bytes: &[u8]) -> Result<FileChunk, StreamError> {
    if !bytes.starts_with(FILE_MAGIC) {
        return Err(StreamError::BadMagic);
    }
    if bytes.len() < FILE_HEADER_LEN + 4 {
        return Err(StreamError::Truncated);
    }
    let length = usize::from(u16_at(bytes, 16));
    if length > MAX_FILE_CHUNK_DATA {
        return Err(StreamError::TooLarge(length));
    }
    if bytes.len() != FILE_HEADER_LEN + length + 4 {
        return Err(StreamError::LengthMismatch {
            declared: FILE_HEADER_LEN + length + 4,
            actual: bytes.len(),
        });
    }
    let body = FILE_HEADER_LEN + length;
    let expected = u32_at(bytes, body);
    let actual = crc32(&bytes[..body]);
    if expected != actual {
        return Err(StreamError::BadCrc { expected, actual });
    }
    Ok(FileChunk {
        command_id: u32_at(bytes, 4),
        offset: u32_at(bytes, 8),
        total_size: u32_at(bytes, 12),
        data: bytes[FILE_HEADER_LEN..body].to_vec(),
    })
}

/// Test-only encoders. Kept beside the decoder so a layout change is visible
/// in one diff; the independent Python vectors in `tests/fixtures` guard
/// against the two drifting together.
#[cfg(test)]
pub mod encode {
    use super::*;

    pub fn frame(record_type: u8, seq: u32, payload: &[u8]) -> Vec<u8> {
        let mut out = vec![0xA5, 0x5A, record_type, payload.len() as u8];
        out.extend_from_slice(&seq.to_le_bytes());
        out.extend_from_slice(payload);
        out.push(crc8_autosar(&out[2..]));
        out
    }

    #[allow(clippy::too_many_arguments)]
    pub fn batch(log_id: u32, start_pos: u32, flags: u8, frames: &[Vec<u8>]) -> Vec<u8> {
        let area: Vec<u8> = frames.concat();
        let seq = |f: &Vec<u8>| u32::from_le_bytes([f[4], f[5], f[6], f[7]]);
        let mut out = Vec::new();
        out.extend_from_slice(BATCH_MAGIC);
        out.push(32);
        out.push(1);
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&log_id.to_le_bytes());
        out.extend_from_slice(&frames.first().map(seq).unwrap_or(0).to_le_bytes());
        out.extend_from_slice(&frames.last().map(seq).unwrap_or(0).to_le_bytes());
        out.extend_from_slice(&start_pos.to_le_bytes());
        out.extend_from_slice(&(start_pos + area.len() as u32).to_le_bytes());
        out.extend_from_slice(&(frames.len() as u16).to_le_bytes());
        out.push(flags);
        out.push(0);
        out.extend_from_slice(&area);
        let crc = crc32(&out);
        out.extend_from_slice(&crc.to_le_bytes());
        out
    }

    pub fn file_chunk(command_id: u32, offset: u32, total: u32, data: &[u8]) -> Vec<u8> {
        let mut out = FILE_MAGIC.to_vec();
        out.extend_from_slice(&command_id.to_le_bytes());
        out.extend_from_slice(&offset.to_le_bytes());
        out.extend_from_slice(&total.to_le_bytes());
        out.extend_from_slice(&(data.len() as u16).to_le_bytes());
        out.extend_from_slice(data);
        let crc = crc32(&out);
        out.extend_from_slice(&crc.to_le_bytes());
        out
    }
}

#[cfg(test)]
mod tests {
    use super::encode::*;
    use super::*;

    fn sample_batch() -> Vec<u8> {
        batch(
            0x6A1B_2C3D,
            1000,
            0,
            &[
                frame(0, 7, &[1, 0, 0xD2, 0x04, 0x39, 0x30, 0, 0, 0]),
                frame(12, 8, &[0x10, 0x27, 0, 0, 1, 0x7B, 0]),
            ],
        )
    }

    #[test]
    fn binary_and_hex_forms_decode_to_the_same_batch() {
        let raw = sample_batch();
        let (binary, encoding) = decode_payload(&raw, BATCH_MAGIC).unwrap();
        assert_eq!(encoding, Encoding::Binary);
        let hex = hex_encode(&raw);
        assert!(hex.starts_with("47574231"));
        let (decoded, encoding) = decode_payload(hex.as_bytes(), BATCH_MAGIC).unwrap();
        assert_eq!(encoding, Encoding::Hex);
        assert_eq!(decoded, binary);
        // Lower-case hex and a trailing newline are tolerated.
        let lower = format!("{}\n", hex.to_ascii_lowercase());
        assert_eq!(
            decode_payload(lower.as_bytes(), BATCH_MAGIC).unwrap().0,
            raw
        );
        assert_eq!(
            decode_payload(b"4757423", BATCH_MAGIC),
            Err(StreamError::BadMagic)
        );
        assert_eq!(
            decode_payload(b"47574231Z0", BATCH_MAGIC),
            Err(StreamError::BadHex)
        );
        assert_eq!(
            decode_payload(b"{\"v\":2}", BATCH_MAGIC),
            Err(StreamError::BadMagic)
        );
    }

    #[test]
    fn batch_header_and_frames_are_split_with_positions() {
        let parsed = parse_batch(&sample_batch()).unwrap();
        assert_eq!(parsed.header.log_id, 0x6A1B_2C3D);
        assert_eq!(parsed.header.first_seq, 7);
        assert_eq!(parsed.header.last_seq, 8);
        assert_eq!(parsed.header.frame_count, 2);
        assert_eq!(parsed.header.payload_schema, 1);
        assert!(parsed.positions_valid);
        assert!(parsed.warnings.is_empty(), "{:?}", parsed.warnings);
        assert_eq!(parsed.frames.len(), 2);
        assert_eq!(parsed.frames[0].pos, Some(1000));
        assert_eq!(parsed.frames[1].pos, Some(1000 + 18));
        assert_eq!(parsed.frames[1].record_type, 12);
        assert_eq!(parsed.frames[1].seq, 8);
        assert_eq!(parsed.header.end_pos, 1000 + 18 + 16);
    }

    #[test]
    fn a_wrong_batch_crc_rejects_the_whole_message() {
        let mut raw = sample_batch();
        let n = raw.len();
        raw[n - 1] ^= 0xFF;
        assert!(matches!(parse_batch(&raw), Err(StreamError::BadCrc { .. })));
        // A flipped payload bit fails too, before any frame is trusted.
        let mut raw = sample_batch();
        raw[40] ^= 0x01;
        assert!(matches!(parse_batch(&raw), Err(StreamError::BadCrc { .. })));
        assert_eq!(parse_batch(&raw[..20]), Err(StreamError::Truncated));
        let mut big = sample_batch();
        big.resize(MAX_BATCH_BYTES + 1, 0);
        assert!(matches!(parse_batch(&big), Err(StreamError::TooLarge(_))));
    }

    #[test]
    fn a_damaged_frame_is_skipped_and_its_neighbours_survive() {
        let good_a = frame(0, 1, &[1, 0, 0xFF, 0xFF, 0, 0, 0, 0x80, 0]);
        let mut bad = frame(12, 2, &[0x10, 0x27, 0, 0, 1, 0x7B, 0]);
        bad[9] ^= 0x40; // payload bit flip, CRC-8 now wrong
        let good_b = frame(12, 3, &[0x10, 0x27, 0, 0, 1, 0x7B, 0]);
        let raw = batch(1, 0, 0, &[good_a, bad, good_b]);
        let parsed = parse_batch(&raw).unwrap();
        assert_eq!(
            parsed.frames.iter().map(|f| f.seq).collect::<Vec<_>>(),
            vec![1, 3]
        );
        assert_eq!(parsed.issues.len(), 1);
        assert_eq!(parsed.issues[0].code, "bad-crc8");
        assert_eq!(parsed.issues[0].claimed_seq, Some(2));
        assert_eq!(parsed.frames[1].pos, Some(18 + 16));
    }

    #[test]
    fn a_damaged_length_byte_resynchronises_on_the_next_valid_frame() {
        let mut bad = frame(12, 2, &[0x10, 0x27, 0, 0, 1, 0x7B, 0]);
        bad[3] = 200; // length now runs past the batch
        let good = frame(12, 3, &[0x10, 0x27, 0, 0, 1, 0x7B, 0]);
        let raw = batch(1, 0, 0, &[bad, good]);
        let parsed = parse_batch(&raw).unwrap();
        assert_eq!(parsed.frames.len(), 1);
        assert_eq!(parsed.frames[0].seq, 3);
        assert_eq!(parsed.issues[0].offset, 0);
        assert_eq!(parsed.issues[0].length, 16);
    }

    // Losing a CRC-valid frame is permanent: a resend repeats the same bytes.
    // A damaged length that happens to point at a later valid frame must not
    // swallow the valid frame in between (Rev2: resynchronise on magic and
    // CRC, never on a damaged length).
    #[test]
    fn a_damaged_length_never_swallows_the_next_valid_frame() {
        let mut bad = frame(12, 1, &[0x10, 0x27, 0, 0, 1, 0x7B, 0]);
        bad[3] = 23; // 16-byte frame now claims 32 bytes: itself plus the next
        let middle = frame(12, 2, &[0x11, 0x27, 0, 0, 1, 0x7B, 0]);
        let last = frame(12, 3, &[0x12, 0x27, 0, 0, 1, 0x7B, 0]);
        let parsed = parse_batch(&batch(1, 0, 0, &[bad, middle, last])).unwrap();
        assert_eq!(
            parsed.frames.iter().map(|f| f.seq).collect::<Vec<_>>(),
            vec![2, 3]
        );
        assert_eq!(parsed.issues.len(), 1);
        assert_eq!((parsed.issues[0].offset, parsed.issues[0].length), (0, 16));
        assert!(parsed.warnings.is_empty(), "{:?}", parsed.warnings);
    }

    // The firmware cuts a damaged run into items of at most 264 bytes, each
    // counted in frame_count; the decoder must count them the same way.
    #[test]
    fn a_long_damaged_run_is_counted_in_firmware_sized_items() {
        let mut area = vec![0x55u8; 600];
        area.extend(frame(12, 9, &[0, 0, 0, 0, 1, 1, 0]));
        let (frames, issues) = split_frames(&area);
        assert_eq!(frames.len(), 1);
        assert_eq!(
            issues.iter().map(|i| i.length).collect::<Vec<_>>(),
            vec![264, 264, 72]
        );
    }

    #[test]
    fn inconsistent_positions_are_flagged_not_trusted() {
        let mut raw = batch(1, 100, 0, &[frame(12, 1, &[0, 0, 0, 0, 1, 1, 0])]);
        raw[24..28].copy_from_slice(&999u32.to_le_bytes());
        let n = raw.len() - 4;
        let crc = crc32(&raw[..n]);
        raw[n..].copy_from_slice(&crc.to_le_bytes());
        let parsed = parse_batch(&raw).unwrap();
        assert!(!parsed.positions_valid);
        assert_eq!(parsed.frames[0].pos, None);
        assert!(!parsed.warnings.is_empty());
    }

    #[test]
    fn file_chunks_verify_length_and_crc() {
        let raw = file_chunk(77, 1024, 5000, b"hello");
        let chunk = parse_file_chunk(&raw).unwrap();
        assert_eq!(chunk.command_id, 77);
        assert_eq!(chunk.offset, 1024);
        assert_eq!(chunk.total_size, 5000);
        assert_eq!(chunk.data, b"hello");
        let hex = hex_encode(&raw);
        assert!(hex.starts_with("47574631"));
        assert_eq!(decode_payload(hex.as_bytes(), FILE_MAGIC).unwrap().0, raw);
        let mut bad = raw.clone();
        bad[20] ^= 1;
        assert!(matches!(
            parse_file_chunk(&bad),
            Err(StreamError::BadCrc { .. })
        ));
        assert!(matches!(
            parse_file_chunk(&raw[..raw.len() - 1]),
            Err(StreamError::LengthMismatch { .. })
        ));
    }
}
