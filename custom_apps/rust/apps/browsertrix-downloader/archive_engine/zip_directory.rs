//! Preflight untrusted ZIP metadata before zip's allocating/deduplicating reader.
//! Layout follows PKWARE APPNOTE 6.3.10 sections 4.3 and 4.5.3.
use super::streaming::{MAX_INFLATED, MAX_METADATA};
use std::{
    collections::BTreeSet,
    fs::File,
    io::{self, Read, Seek, SeekFrom},
    os::unix::fs::FileExt,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

pub(super) struct Directory {
    pub count: usize,
    start: u64,
    data: Vec<u8>,
}
/// During construction zip only sees the frozen, bounded directory. Its EOCD
/// fallback scanner cannot discover another unvalidated directory in payloads.
pub(super) struct Input {
    file: Arc<File>,
    directory: Directory,
    position: u64,
    pub metadata_only: Arc<AtomicBool>,
}
impl Input {
    pub fn new(file: Arc<File>, directory: Directory) -> Self {
        Self {
            file,
            directory,
            position: 0,
            metadata_only: Arc::new(AtomicBool::new(true)),
        }
    }
}
impl Read for Input {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if !self.metadata_only.load(Ordering::Relaxed) {
            let n = self.file.read_at(out, self.position)?;
            self.position += n as u64;
            return Ok(n);
        }
        let end = self.directory.start + self.directory.data.len() as u64;
        let n = out.len().min(end.saturating_sub(self.position) as usize);
        if n == 0 {
            return Ok(0);
        }
        let prefix = self
            .directory
            .start
            .saturating_sub(self.position)
            .min(n as u64) as usize;
        if prefix == n {
            return Err(io::Error::other(
                "ZIP metadata parser left preflighted directory",
            ));
        }
        out[..prefix].fill(0);
        let at = (self.position + prefix as u64 - self.directory.start) as usize;
        out[prefix..n].copy_from_slice(&self.directory.data[at..at + n - prefix]);
        self.position += n as u64;
        Ok(n)
    }
}
impl Seek for Input {
    fn seek(&mut self, from: SeekFrom) -> io::Result<u64> {
        let next = match from {
            SeekFrom::Start(n) => Some(n),
            SeekFrom::Current(n) => self.position.checked_add_signed(n),
            SeekFrom::End(n) => {
                (self.directory.start + self.directory.data.len() as u64).checked_add_signed(n)
            }
        }
        .ok_or_else(|| io::Error::other("Invalid ZIP seek"))?;
        self.position = next;
        Ok(next)
    }
}

const MAX_MEMBERS: u64 = 10_000;
const MAX_NAME: usize = 1024;
fn u16le(b: &[u8], p: usize) -> u16 {
    u16::from_le_bytes(b[p..p + 2].try_into().unwrap())
}
fn u32le(b: &[u8], p: usize) -> u32 {
    u32::from_le_bytes(b[p..p + 4].try_into().unwrap())
}
fn u64le(b: &[u8], p: usize) -> u64 {
    u64::from_le_bytes(b[p..p + 8].try_into().unwrap())
}
fn bytes(file: &File, start: u64, length: usize) -> Result<Vec<u8>, String> {
    let mut data = vec![0; length];
    file.read_exact_at(&mut data, start)
        .map_err(|e| e.to_string())?;
    Ok(data)
}
fn extra<'a>(data: &'a [u8], name: &[u8]) -> Result<Option<&'a [u8]>, String> {
    let mut p = 0;
    let mut zip64 = None;
    while p < data.len() {
        if data.len() - p < 4 {
            return Err("Truncated ZIP extra field".into());
        }
        let tag = u16le(data, p);
        let end = p + 4 + u16le(data, p + 2) as usize;
        let value = data.get(p + 4..end).ok_or("Truncated ZIP extra field")?;
        if tag == 1 && zip64.replace(value).is_some() {
            return Err("Duplicate ZIP64 extra field".into());
        }
        // A Unicode override must not change the preflighted identity. Native
        // UTF-8 names and redundant Unicode fields remain supported.
        if tag == 0x7075 && (value.len() < 5 || &value[5..] != name) {
            return Err("ZIP Unicode path override unsupported".into());
        }
        p = end;
    }
    Ok(zip64)
}
fn take64(data: &[u8], p: &mut usize) -> Result<u64, String> {
    let value = data.get(*p..*p + 8).ok_or("Missing ZIP64 size/offset")?;
    *p += 8;
    Ok(u64le(value, 0))
}

pub(super) fn validate(file: &File, size: u64) -> Result<Directory, String> {
    let tail_len = size.min(22 + u16::MAX as u64) as usize;
    let tail_start = size - tail_len as u64;
    let tail = bytes(file, tail_start, tail_len)?;
    let eocd = (0..tail.len().saturating_sub(21))
        .rev()
        .find(|p| {
            tail[*p..].starts_with(b"PK\x05\x06")
                && *p + 22 + u16le(&tail, *p + 20) as usize == tail.len()
        })
        .ok_or("ZIP end directory missing or trailing bytes unsupported")?;
    let end = &tail[eocd..];
    if u16le(end, 4) != 0 || u16le(end, 6) != 0 || u16le(end, 8) != u16le(end, 10) {
        return Err("Multi-disk ZIP unsupported".into());
    }
    let end_at = tail_start + eocd as u64;
    let mut count = u16le(end, 10) as u64;
    let mut length = u32le(end, 12) as u64;
    let mut start = u32le(end, 16) as u64;
    let mut directory_end = end_at;
    let locator = if end_at >= 20 {
        bytes(file, end_at - 20, 20)?
    } else {
        vec![]
    };
    if locator.starts_with(b"PK\x06\x07") {
        if u32le(&locator, 4) != 0 || u32le(&locator, 16) != 1 {
            return Err("Multi-disk ZIP64 unsupported".into());
        }
        let at = u64le(&locator, 8);
        if at.checked_add(56).is_none_or(|n| n > end_at - 20) {
            return Err("Invalid ZIP64 directory offset".into());
        }
        let z = bytes(file, at, 56)?;
        if !z.starts_with(b"PK\x06\x06") || u64le(&z, 4) != 44 || at + 56 != end_at - 20 {
            return Err("Unsupported ZIP64 end directory layout".into());
        }
        if u32le(&z, 16) != 0 || u32le(&z, 20) != 0 || u64le(&z, 24) != u64le(&z, 32) {
            return Err("Multi-disk ZIP64 unsupported".into());
        }
        let values = (u64le(&z, 32), u64le(&z, 40), u64le(&z, 48));
        if (count != u16::MAX as u64 && count != values.0)
            || (length != u32::MAX as u64 && length != values.1)
            || (start != u32::MAX as u64 && start != values.2)
        {
            return Err("ZIP and ZIP64 directory disagreement".into());
        }
        (count, length, start) = values;
        directory_end = at;
    } else if count == u16::MAX as u64 || length == u32::MAX as u64 || start == u32::MAX as u64 {
        return Err("ZIP64 end directory missing".into());
    }
    if count > MAX_MEMBERS {
        return Err("ZIP member count exceeds 10000".into());
    }
    if length > MAX_METADATA as u64 {
        return Err("ZIP central directory exceeds 32 MiB".into());
    }
    if start.checked_add(length) != Some(directory_end) {
        return Err("Invalid ZIP central directory span; prefixed ZIP unsupported".into());
    }
    // This is the sole aggregate allocation and occurs only after raw size and
    // count bounds. Parse the exact snapshot handed to zip, not mutable rereads.
    let snapshot = bytes(file, start, (size - start) as usize)?;
    let overlap = start.max(tail_start);
    if snapshot[(overlap - start) as usize..] != tail[(overlap - tail_start) as usize..] {
        return Err("ZIP directory changed during preflight".into());
    }
    for (p, sig) in snapshot.windows(4).enumerate() {
        let at = start + p as u64;
        if (sig == b"PK\x05\x06" && at != end_at)
            || (sig == b"PK\x06\x06" && at != directory_end)
            || (sig == b"PK\x06\x07" && (directory_end == end_at || at != end_at - 20))
        {
            return Err("Ambiguous nested ZIP end directory signature unsupported".into());
        }
    }
    let metadata = |at: u64, length: usize| -> Result<&[u8], String> {
        snapshot
            .get((at - start) as usize..(at - start) as usize + length)
            .ok_or_else(|| "Truncated ZIP directory metadata".into())
    };
    let mut position = start;
    let mut names = BTreeSet::new();
    let mut ranges = Vec::new();
    let mut inflated = 0u64;
    for _ in 0..count {
        if position.checked_add(46).is_none_or(|n| n > directory_end) {
            return Err("Truncated ZIP central directory".into());
        }
        let h = metadata(position, 46)?;
        if !h.starts_with(b"PK\x01\x02") {
            return Err("Invalid ZIP central directory record".into());
        }
        let name_len = u16le(&h, 28) as usize;
        let extra_len = u16le(&h, 30) as usize;
        let comment_len = u16le(&h, 32) as usize;
        let next = position + 46 + (name_len + extra_len + comment_len) as u64;
        if next > directory_end || name_len == 0 || name_len > MAX_NAME {
            return Err("ZIP member name/metadata bound exceeded".into());
        }
        let name = metadata(position + 46, name_len)?;
        let text = std::str::from_utf8(&name).map_err(|_| "Non-UTF8 ZIP names unsupported")?;
        let flags = u16le(&h, 8);
        if (flags & 0x800 == 0 && !text.is_ascii())
            || text.contains(['\\', ':'])
            || text.chars().any(char::is_control)
            || text.starts_with('/')
            || text.split('/').any(|s| s == "." || s == "..")
            || flags & 0x2041 != 0
        {
            return Err("Unsafe ZIP member name or encryption".into());
        }
        if !names.insert(name.to_vec()) {
            return Err("Duplicate ZIP member".into());
        }
        let extras = metadata(position + 46 + name_len as u64, extra_len)?;
        let z = extra(&extras, &name)?.unwrap_or(&[]);
        let mut p = 0;
        let mut unpacked = u32le(&h, 24) as u64;
        let mut packed = u32le(&h, 20) as u64;
        let mut local = u32le(&h, 42) as u64;
        if unpacked == u32::MAX as u64 {
            unpacked = take64(z, &mut p)?;
        }
        if packed == u32::MAX as u64 {
            packed = take64(z, &mut p)?;
        }
        if local == u32::MAX as u64 {
            local = take64(z, &mut p)?;
        }
        let disk = if u16le(&h, 34) == u16::MAX {
            u32le(z.get(p..p + 4).ok_or("Missing ZIP64 disk")?, 0)
        } else {
            u16le(&h, 34) as u32
        };
        if disk != 0 {
            return Err("Multi-disk ZIP member unsupported".into());
        }
        inflated = inflated
            .checked_add(unpacked)
            .filter(|n| *n <= MAX_INFLATED)
            .ok_or("ZIP inflated byte limit exceeded")?;
        let method = u16le(&h, 10);
        if !matches!(method, 0 | 8) || (method == 0 && packed != unpacked) {
            return Err("Unsupported ZIP compression or STORE size mismatch".into());
        }
        if local.checked_add(30).is_none_or(|n| n > start) {
            return Err("ZIP local header outside member area".into());
        }
        let lh = bytes(file, local, 30)?;
        if !lh.starts_with(b"PK\x03\x04")
            || u16le(&lh, 6) != flags
            || u16le(&lh, 8) != method
            || u16le(&lh, 26) as usize != name_len
        {
            return Err("ZIP local/central header mismatch".into());
        }
        let local_extra = u16le(&lh, 28) as usize;
        let data = local + 30 + (name_len + local_extra) as u64;
        let data_end = data
            .checked_add(packed)
            .filter(|n| *n <= start)
            .ok_or("ZIP member outside member area")?;
        if bytes(file, local + 30, name_len)? != name {
            return Err("ZIP local/central name mismatch".into());
        }
        extra(
            &bytes(file, local + 30 + name_len as u64, local_extra)?,
            &name,
        )?;
        ranges.push((local, data_end));
        position = next;
    }
    if position != directory_end {
        return Err("ZIP raw member count differs from end directory".into());
    }
    ranges.sort_unstable();
    if ranges.windows(2).any(|w| w[0].1 > w[1].0) {
        return Err("Overlapping ZIP members".into());
    }
    Ok(Directory {
        count: count as usize,
        start,
        data: snapshot,
    })
}
