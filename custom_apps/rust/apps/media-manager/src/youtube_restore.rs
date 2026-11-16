//! The restore file of a split YouTube download: what the chapter files do
//! not hold of the original they were cut from.
//!
//! A media file is its coded streams (the audio and video packets) plus
//! container bytes around them: headers, timestamps, indexes, tags, cover art.
//! A chapter split keeps every packet, so the chapter files already hold the
//! streams. The restore file stores the original's remaining bytes and a map
//! saying where each run of stream data sat between them, so the original can
//! be rebuilt byte for byte.
//!
//! The map refers to each stream's *raw data*: its packets end to end, as
//! `ffmpeg -c copy -f data` writes them. Reading the chapter files in order
//! gives that same raw data whatever has since happened to their own tags or
//! covers, so a restore keeps working after the chapters are re-tagged.
//!
//! Layout (integers little-endian, varints unsigned LEB128), shared with the
//! YouTube Downloader's `restore-data.ts`:
//!
//! ```text
//! "YTDLRST1"            8 bytes
//! header length         u32
//! header                JSON, see `Header`
//! records               `recordBytes` bytes, `recordCount` of:
//!   literal   varint    container bytes to copy from the literal section
//!   stream    u8        which stream's raw data follows them
//!   skip      varint    raw-data bytes of that stream to pass over first
//!   copy      varint    raw-data bytes of that stream to copy
//! literal section       `literalBytes` bytes
//! ```
//!
//! Rebuilding walks the records in order and writes `literal` bytes, then
//! `copy` bytes of stream data. The result is only accepted when it has the
//! recorded size and SHA-256.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{BufWriter, Read, Write},
    os::unix::fs::{FileExt, OpenOptionsExt},
    path::Path,
};

pub const MAGIC: &[u8; 8] = b"YTDLRST1";
pub const VERSION: u32 = 1;
const CHUNK: usize = 1024 * 1024;
const MAX_HEADER_BYTES: usize = 1024 * 1024;
/// A record costs a few bytes; this bounds what a damaged header can ask for.
const MAX_RECORD_BYTES: u64 = 1024 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StreamData {
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Header {
    pub version: u32,
    pub original_size: u64,
    pub original_sha256: String,
    /// Each stream's raw data, in programme order.
    pub streams: Vec<StreamData>,
    pub record_count: u64,
    pub record_bytes: u64,
    pub literal_bytes: u64,
}

/// One coded packet of the original: its stream (by programme position),
/// where ffprobe saw it (`None` when the demuxer reports no position) and its
/// length.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Packet {
    pub stream: usize,
    pub pos: Option<u64>,
    pub size: u64,
}

fn hex(digest: impl AsRef<[u8]>) -> String {
    digest
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// A writer that hashes and counts what passes through it.
pub struct Hashing<W: Write> {
    inner: W,
    hasher: Sha256,
    bytes: u64,
}

impl<W: Write> Hashing<W> {
    pub fn new(inner: W) -> Self {
        Self {
            inner,
            hasher: Sha256::new(),
            bytes: 0,
        }
    }

    /// The SHA-256 and length of everything written, and the inner writer.
    pub fn finish(mut self) -> std::io::Result<(StreamData, W)> {
        self.inner.flush()?;
        Ok((
            StreamData {
                bytes: self.bytes,
                sha256: hex(self.hasher.finalize()),
            },
            self.inner,
        ))
    }
}

impl<W: Write> Write for Hashing<W> {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        let written = self.inner.write(buffer)?;
        self.hasher.update(&buffer[..written]);
        self.bytes += written as u64;
        Ok(written)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

/// SHA-256 and length of a whole file.
pub fn hash_file(file: &File) -> Result<StreamData, String> {
    let mut hashing = Hashing::new(std::io::sink());
    copy_range(file, 0, u64::MAX, &mut hashing, true)?;
    hashing
        .finish()
        .map(|(data, _)| data)
        .map_err(|error| error.to_string())
}

/// Copy `length` bytes of `file` from `position` (or to its end when
/// `to_end`), failing if it is shorter.
fn copy_range(
    file: &File,
    position: u64,
    length: u64,
    out: &mut impl Write,
    to_end: bool,
) -> Result<u64, String> {
    let mut buffer = vec![0u8; CHUNK];
    let mut done = 0u64;
    while done < length {
        let want = usize::try_from((length - done).min(CHUNK as u64)).unwrap_or(CHUNK);
        let read = file
            .read_at(&mut buffer[..want], position + done)
            .map_err(|error| format!("read: {error}"))?;
        if read == 0 {
            if to_end {
                break;
            }
            return Err("A file is shorter than recorded.".into());
        }
        out.write_all(&buffer[..read])
            .map_err(|error| format!("write: {error}"))?;
        done += read as u64;
    }
    Ok(done)
}

/// `stream_index=…,size=…,pos=…` lines of `ffprobe -of csv=p=0:nk=0`, for the
/// streams in `stream_indexes` (whose order gives the programme position).
pub fn parse_packet_list(output: &str, stream_indexes: &[usize]) -> Vec<Packet> {
    output
        .lines()
        .filter_map(|line| {
            let field = |name: &str| {
                line.split(',').find_map(|part| {
                    part.strip_prefix(name)
                        .and_then(|rest| rest.strip_prefix('='))
                        .and_then(|value| value.trim().parse::<u64>().ok())
                })
            };
            let index = usize::try_from(field("stream_index")?).ok()?;
            Some(Packet {
                stream: stream_indexes.iter().position(|known| *known == index)?,
                size: field("size")?,
                pos: field("pos"),
            })
        })
        .collect()
}

fn push_varint(mut value: u64, into: &mut Vec<u8>) {
    while value >= 128 {
        into.push((value % 128) as u8 | 128);
        value /= 128;
    }
    into.push(value as u8);
}

fn read_varint(bytes: &[u8], offset: &mut usize) -> Result<u64, String> {
    let mut value = 0u64;
    let mut shift = 0u32;
    loop {
        let byte = *bytes
            .get(*offset)
            .ok_or("The restore file ends inside a record.")?;
        *offset += 1;
        if shift >= 64 {
            return Err("The restore file holds an impossible number.".into());
        }
        value |= u64::from(byte & 127) << shift;
        if byte < 128 {
            return Ok(value);
        }
        shift += 7;
    }
}

fn read_at_most(file: &File, buffer: &mut [u8], position: u64) -> Result<usize, String> {
    let mut done = 0;
    while done < buffer.len() {
        let read = file
            .read_at(&mut buffer[done..], position + done as u64)
            .map_err(|error| format!("read: {error}"))?;
        if read == 0 {
            break;
        }
        done += read;
    }
    Ok(done)
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    let first = needle[0];
    let last_start = haystack.len() - needle.len();
    let mut from = 0;
    while from <= last_start {
        let offset = haystack[from..=last_start]
            .iter()
            .position(|byte| *byte == first)?;
        let start = from + offset;
        if &haystack[start..start + needle.len()] == needle {
            return Some(start);
        }
        from = start + 1;
    }
    None
}

struct Located {
    file: u64,
    length: u64,
    stream: usize,
    dump: u64,
}

/// How much further than its reported position a packet is looked for.
const SLACK: [usize; 3] = [0, 64, 4096];
/// Later packets of one Ogg page share the page's position.
const SAME_PAGE: u64 = 70_000;

/// Find where each packet's bytes sit in the original. ffprobe's position is
/// exact for some containers (MP4, FLAC, MP3, WAV) and the start of the
/// enclosing block or page for others (Matroska, Ogg), so the packet is looked
/// for from there, a little further each time. A packet that is not found
/// whole (an Ogg packet split across pages) simply stays in the literal bytes.
/// Any place the same bytes occur rebuilds the same file, so a match never has
/// to be the "true" one for the result to be exact.
fn locate(original: &File, dumps: &[File], packets: &[Packet]) -> Result<Vec<Located>, String> {
    let mut cursor = vec![0u64; dumps.len()];
    let mut last_end = vec![0u64; dumps.len()];
    let mut located = Vec::new();
    let mut payload = Vec::new();
    let mut window = Vec::new();
    for packet in packets {
        let stream = packet.stream;
        if stream >= dumps.len() {
            return Err("A packet names a stream that was not read.".into());
        }
        let dump = cursor[stream];
        cursor[stream] += packet.size;
        let size = usize::try_from(packet.size).map_err(|_| "A packet is too large.")?;
        if size == 0 {
            continue;
        }
        payload.resize(size, 0);
        if read_at_most(&dumps[stream], &mut payload, dump)? != size {
            return Err("A stream is shorter than its packet list.".into());
        }
        let mut start = packet.pos.unwrap_or(last_end[stream]);
        if last_end[stream] > start && last_end[stream] - start <= SAME_PAGE {
            start = last_end[stream];
        }
        for slack in SLACK {
            window.resize(size + slack, 0);
            let available = read_at_most(original, &mut window, start)?;
            if let Some(hit) = find(&window[..available], &payload) {
                let file = start + hit as u64;
                located.push(Located {
                    file,
                    length: packet.size,
                    stream,
                    dump,
                });
                last_end[stream] = file + packet.size;
                break;
            }
        }
    }
    Ok(located)
}

/// Write the restore file for `original` to `output` (which must not exist).
/// `dumps` are the raw data of the original's programme streams.
pub fn build(
    original: &File,
    original_sha256: &str,
    dumps: &[(File, StreamData)],
    packets: &[Packet],
    output: &Path,
) -> Result<Header, String> {
    let original_size = original
        .metadata()
        .map_err(|error| format!("inspect original: {error}"))?
        .len();
    let dump_files = dumps
        .iter()
        .map(|(file, _)| file.try_clone().map_err(|error| error.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    let mut located = locate(original, &dump_files, packets)?;
    located.sort_by_key(|run| run.file);

    // Runs of stream data that are contiguous in the file and in the stream's
    // raw data merge into one record.
    struct Pending {
        literal: u64,
        stream: usize,
        skip: u64,
        copy: u64,
    }
    let mut records = Vec::new();
    let mut record_count = 0u64;
    let mut literals: Vec<(u64, u64)> = Vec::new();
    let mut literal_bytes = 0u64;
    let mut cursor = vec![0u64; dumps.len()];
    let mut file_cursor = 0u64;
    let mut pending: Option<Pending> = None;
    let mut flush = |pending: &mut Option<Pending>, records: &mut Vec<u8>| {
        if let Some(record) = pending.take() {
            push_varint(record.literal, records);
            records.push(record.stream as u8);
            push_varint(record.skip, records);
            push_varint(record.copy, records);
            record_count += 1;
        }
    };
    if dumps.len() > usize::from(u8::MAX) {
        return Err("Too many streams.".into());
    }
    for run in &located {
        // A packet found overlapping one already placed, or behind its
        // stream's cursor, stays literal.
        if run.file < file_cursor || run.dump < cursor[run.stream] {
            continue;
        }
        let literal = run.file - file_cursor;
        let skip = run.dump - cursor[run.stream];
        match &mut pending {
            Some(record) if literal == 0 && skip == 0 && record.stream == run.stream => {
                record.copy += run.length;
            }
            _ => {
                flush(&mut pending, &mut records);
                if literal > 0 {
                    literals.push((file_cursor, run.file));
                    literal_bytes += literal;
                }
                pending = Some(Pending {
                    literal,
                    stream: run.stream,
                    skip,
                    copy: run.length,
                });
            }
        }
        file_cursor = run.file + run.length;
        cursor[run.stream] = run.dump + run.length;
    }
    flush(&mut pending, &mut records);
    if file_cursor < original_size {
        literals.push((file_cursor, original_size));
        literal_bytes += original_size - file_cursor;
        pending = Some(Pending {
            literal: original_size - file_cursor,
            stream: 0,
            skip: 0,
            copy: 0,
        });
        flush(&mut pending, &mut records);
    }

    let header = Header {
        version: VERSION,
        original_size,
        original_sha256: original_sha256.to_string(),
        streams: dumps.iter().map(|(_, data)| data.clone()).collect(),
        record_count,
        record_bytes: records.len() as u64,
        literal_bytes,
    };
    let header_json = serde_json::to_vec(&header).map_err(|error| error.to_string())?;
    let file = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o660)
        .open(output)
        .map_err(|error| format!("create restore file: {error}"))?;
    let mut out = BufWriter::new(file);
    let write = |out: &mut BufWriter<File>, bytes: &[u8]| {
        out.write_all(bytes)
            .map_err(|error| format!("write restore file: {error}"))
    };
    write(&mut out, MAGIC)?;
    write(&mut out, &(header_json.len() as u32).to_le_bytes())?;
    write(&mut out, &header_json)?;
    write(&mut out, &records)?;
    for (from, to) in literals {
        copy_range(original, from, to - from, &mut out, false)?;
    }
    out.into_inner()
        .map_err(|error| format!("write restore file: {error}"))?
        .sync_all()
        .map_err(|error| format!("write restore file: {error}"))?;
    Ok(header)
}

/// Read and check a restore file's header.
pub fn read_header(restore: &File) -> Result<(Header, u64), String> {
    let mut prefix = [0u8; 12];
    if read_at_most(restore, &mut prefix, 0)? != 12 || &prefix[..8] != MAGIC {
        return Err("This is not a restore file.".into());
    }
    let length = u32::from_le_bytes([prefix[8], prefix[9], prefix[10], prefix[11]]) as usize;
    if length > MAX_HEADER_BYTES {
        return Err("The restore file's header is too large.".into());
    }
    let mut bytes = vec![0u8; length];
    if read_at_most(restore, &mut bytes, 12)? != length {
        return Err("The restore file is truncated.".into());
    }
    let header: Header = serde_json::from_slice(&bytes)
        .map_err(|_| "The restore file's header cannot be read.".to_string())?;
    if header.version != VERSION {
        return Err("The restore file is from a newer version.".into());
    }
    Ok((header, 12 + length as u64))
}

/// Rebuild the original from a restore file and each stream's raw data,
/// writing it to `out`. The caller checks the result against the header's
/// `original_size` and `original_sha256`.
pub fn rebuild(restore: &File, dumps: &[File], out: &mut impl Write) -> Result<Header, String> {
    let (header, records_at) = read_header(restore)?;
    if header.streams.len() != dumps.len() || header.record_bytes > MAX_RECORD_BYTES {
        return Err("The restore file does not match these streams.".into());
    }
    let mut records = vec![0u8; header.record_bytes as usize];
    if read_at_most(restore, &mut records, records_at)? != records.len() {
        return Err("The restore file is truncated.".into());
    }
    let mut literal_at = records_at + header.record_bytes;
    let mut cursor = vec![0u64; dumps.len()];
    let mut offset = 0usize;
    for _ in 0..header.record_count {
        let literal = read_varint(&records, &mut offset)?;
        let stream = usize::from(
            *records
                .get(offset)
                .ok_or("The restore file ends inside a record.")?,
        );
        offset += 1;
        let skip = read_varint(&records, &mut offset)?;
        let copy = read_varint(&records, &mut offset)?;
        let dump = dumps
            .get(stream)
            .ok_or("The restore file names a stream that does not exist.")?;
        copy_range(restore, literal_at, literal, out, false)?;
        literal_at += literal;
        cursor[stream] += skip;
        copy_range(dump, cursor[stream], copy, out, false)?;
        cursor[stream] += copy;
    }
    Ok(header)
}

/// Rebuild into a hash only: the SHA-256 and size a rebuild would have.
pub fn rebuilt_hash(restore: &File, dumps: &[File]) -> Result<StreamData, String> {
    let mut hashing = Hashing::new(std::io::sink());
    rebuild(restore, dumps, &mut hashing)?;
    hashing
        .finish()
        .map(|(data, _)| data)
        .map_err(|error| error.to_string())
}

/// Append all of `source` to `out`, returning its length and SHA-256.
pub fn append_hashed(source: &mut impl Read, out: &mut impl Write) -> Result<StreamData, String> {
    let mut hashing = Hashing::new(out);
    std::io::copy(source, &mut hashing).map_err(|error| format!("copy stream data: {error}"))?;
    hashing
        .finish()
        .map(|(data, _)| data)
        .map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Seek;

    fn temp_with(bytes: &[u8]) -> File {
        let mut file = tempfile::tempfile().unwrap();
        file.write_all(bytes).unwrap();
        file.rewind().unwrap();
        file
    }

    fn data(bytes: &[u8]) -> StreamData {
        StreamData {
            bytes: bytes.len() as u64,
            sha256: hex(Sha256::digest(bytes)),
        }
    }

    /// A made-up container: a header, then packets of two streams each behind
    /// a small block header, one packet split in two, and a trailing index.
    fn container() -> (Vec<u8>, Vec<Vec<u8>>, Vec<Packet>) {
        // Coded media looks like noise; a tiny generator stands in for it.
        let mut seed = 0x2545_F491_4F6C_DD1Du64;
        let mut noise = |length: u32| -> Vec<u8> {
            (0..length)
                .map(|_| {
                    seed ^= seed << 13;
                    seed ^= seed >> 7;
                    seed ^= seed << 17;
                    (seed >> 24) as u8
                })
                .collect()
        };
        let video: Vec<Vec<u8>> = (0..40u32).map(|n| noise(300 + n * 7)).collect();
        let audio: Vec<Vec<u8>> = (0..90u32).map(|n| noise(40 + n % 5)).collect();
        let mut file = b"HEADER tags=title,artist cover=....".to_vec();
        let mut packets = Vec::new();
        let (mut v, mut a) = (0, 0);
        while v < video.len() || a < audio.len() {
            if v < video.len() {
                // Position reported a few bytes before the payload, like Matroska.
                let pos = file.len() as u64;
                file.extend_from_slice(&[0xA3, 0x81, 0x00, v as u8]);
                if v == 7 {
                    // Split across a page boundary: cannot be found whole.
                    let half = video[v].len() / 2;
                    file.extend_from_slice(&video[v][..half]);
                    file.extend_from_slice(b"<<page>>");
                    file.extend_from_slice(&video[v][half..]);
                } else {
                    file.extend_from_slice(&video[v]);
                }
                packets.push(Packet {
                    stream: 0,
                    pos: Some(pos),
                    size: video[v].len() as u64,
                });
                v += 1;
            }
            for _ in 0..3 {
                if a < audio.len() {
                    // Contiguous, exact positions, like MP4; some unreported.
                    let pos = (a % 4 != 3).then_some(file.len() as u64);
                    file.extend_from_slice(&audio[a]);
                    packets.push(Packet {
                        stream: 1,
                        pos,
                        size: audio[a].len() as u64,
                    });
                    a += 1;
                }
            }
        }
        file.extend_from_slice(b"INDEX................END");
        (file, vec![video.concat(), audio.concat()], packets)
    }

    #[test]
    fn rebuilds_the_original_byte_for_byte() {
        let (original, streams, packets) = container();
        let dir = tempfile::tempdir().unwrap();
        let restore_path = dir.path().join("item.restore");
        let dumps = streams
            .iter()
            .map(|stream| (temp_with(stream), data(stream)))
            .collect::<Vec<_>>();
        let header = build(
            &temp_with(&original),
            &data(&original).sha256,
            &dumps,
            &packets,
            &restore_path,
        )
        .unwrap();
        assert_eq!(header.original_size, original.len() as u64);
        // Only the container stays in the restore file: one split packet, the
        // block headers, the file header and the index.
        assert!(header.literal_bytes < 800, "{}", header.literal_bytes);

        let restore = File::open(&restore_path).unwrap();
        let dump_files = streams
            .iter()
            .map(|stream| temp_with(stream))
            .collect::<Vec<_>>();
        let mut rebuilt = Vec::new();
        rebuild(&restore, &dump_files, &mut rebuilt).unwrap();
        assert_eq!(rebuilt, original);
        assert_eq!(
            rebuilt_hash(&restore, &dump_files).unwrap(),
            data(&original)
        );
    }

    #[test]
    fn damaged_inputs_never_pass_for_the_original() {
        let (original, streams, packets) = container();
        let dir = tempfile::tempdir().unwrap();
        let restore_path = dir.path().join("item.restore");
        let dumps = streams
            .iter()
            .map(|stream| (temp_with(stream), data(stream)))
            .collect::<Vec<_>>();
        build(
            &temp_with(&original),
            &data(&original).sha256,
            &dumps,
            &packets,
            &restore_path,
        )
        .unwrap();
        let restore = File::open(&restore_path).unwrap();

        // A flipped bit in a stream changes the hash; a short stream is an error.
        let mut flipped = streams.clone();
        flipped[1][100] ^= 1;
        let files = flipped.iter().map(|s| temp_with(s)).collect::<Vec<_>>();
        assert_ne!(rebuilt_hash(&restore, &files).unwrap(), data(&original));
        let short = vec![temp_with(&streams[0][..100]), temp_with(&streams[1])];
        assert!(rebuilt_hash(&restore, &short).is_err());

        // Not a restore file, and a truncated one.
        assert!(read_header(&temp_with(b"something else entirely")).is_err());
        let bytes = std::fs::read(&restore_path).unwrap();
        let truncated = temp_with(&bytes[..bytes.len() - 10]);
        let files = streams.iter().map(|s| temp_with(s)).collect::<Vec<_>>();
        assert!(rebuilt_hash(&truncated, &files).is_err());
    }

    #[test]
    fn reads_the_packet_list_and_varints() {
        assert_eq!(
            parse_packet_list(
                "stream_index=1,size=10,pos=100\nstream_index=2,size=5,pos=7\nstream_index=0,size=20\n",
                &[0, 1]
            ),
            vec![
                Packet { stream: 1, pos: Some(100), size: 10 },
                Packet { stream: 0, pos: None, size: 20 },
            ]
        );
        for value in [0u64, 1, 127, 128, 300, 1 << 32, u64::MAX] {
            let mut bytes = Vec::new();
            push_varint(value, &mut bytes);
            assert_eq!(read_varint(&bytes, &mut 0).unwrap(), value);
        }
    }
}
