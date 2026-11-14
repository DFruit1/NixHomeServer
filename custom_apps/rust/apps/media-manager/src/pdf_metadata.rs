//! Lossless PDF document-metadata edits.
//!
//! A PDF can be amended by appending an incremental update (ISO 32000-1
//! §7.5.6): new revisions of the changed objects, a cross-reference section
//! for them and a trailer whose `/Prev` points at the previous section. Every
//! original byte stays where it was, so page content cannot be damaged and the
//! prior revision remains intact inside the file. Kavita reads the document
//! XMP packet and the Info dictionary, so an update replaces both.
//!
//! The reader is deliberately small and bounded: it resolves only the
//! cross-reference chain, the catalog, the Info dictionary and the XMP stream,
//! so a large scanned book is streamed rather than loaded. Encrypted documents
//! and filters other than FlateDecode are refused instead of guessed at.

use flate2::read::ZlibDecoder;
use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read, Seek, SeekFrom, Write};

const TAIL_WINDOW: u64 = 64 * 1024;
const INITIAL_WINDOW: u64 = 64 * 1024;
const MAX_WINDOW: u64 = 64 * 1024 * 1024;
const MAX_STREAM_BYTES: u64 = 64 * 1024 * 1024;
const MAX_XREF_SECTIONS: usize = 512;
const MAX_NESTING: usize = 64;
const MAX_XMP_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq)]
enum Object {
    Null,
    Bool(bool),
    Integer(i64),
    Real(String),
    String(Vec<u8>),
    Name(Vec<u8>),
    Array(Vec<Object>),
    Dictionary(Dictionary),
    Reference(u32, u16),
}

type Dictionary = Vec<(Vec<u8>, Object)>;

fn get<'a>(dictionary: &'a Dictionary, key: &[u8]) -> Option<&'a Object> {
    dictionary
        .iter()
        .find(|(candidate, _)| candidate == key)
        .map(|(_, value)| value)
}

fn set(dictionary: &mut Dictionary, key: &[u8], value: Object) {
    dictionary.retain(|(candidate, _)| candidate != key);
    dictionary.push((key.to_vec(), value));
}

#[derive(Debug)]
enum ParseError {
    /// The window ended before the construct did; retry with more bytes.
    Truncated,
    Invalid(String),
}

impl From<String> for ParseError {
    fn from(message: String) -> Self {
        ParseError::Invalid(message)
    }
}

fn invalid<T>(message: impl Into<String>) -> Result<T, ParseError> {
    Err(ParseError::Invalid(message.into()))
}

fn is_whitespace(byte: u8) -> bool {
    matches!(byte, b'\0' | b'\t' | b'\n' | b'\x0c' | b'\r' | b' ')
}

fn is_delimiter(byte: u8) -> bool {
    matches!(
        byte,
        b'(' | b')' | b'<' | b'>' | b'[' | b']' | b'{' | b'}' | b'/' | b'%'
    )
}

fn is_regular(byte: u8) -> bool {
    !is_whitespace(byte) && !is_delimiter(byte)
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
    /// Whether `bytes` reaches the end of the file, so running out is final.
    complete: bool,
}

impl<'a> Parser<'a> {
    fn new(bytes: &'a [u8], complete: bool) -> Self {
        Self {
            bytes,
            pos: 0,
            complete,
        }
    }

    fn end(&self) -> ParseError {
        if self.complete {
            ParseError::Invalid("unexpected end of PDF data".to_string())
        } else {
            ParseError::Truncated
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_whitespace(&mut self) {
        while let Some(byte) = self.peek() {
            if is_whitespace(byte) {
                self.pos += 1;
            } else if byte == b'%' {
                while let Some(byte) = self.peek() {
                    if byte == b'\n' || byte == b'\r' {
                        break;
                    }
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn token(&mut self) -> Result<&'a [u8], ParseError> {
        self.skip_whitespace();
        let start = self.pos;
        while self.peek().is_some_and(is_regular) {
            self.pos += 1;
        }
        if self.pos == self.bytes.len() && !self.complete {
            return Err(ParseError::Truncated);
        }
        if start == self.pos {
            return invalid("expected a PDF token");
        }
        Ok(&self.bytes[start..self.pos])
    }

    fn keyword(&mut self, expected: &[u8]) -> Result<(), ParseError> {
        let token = self.token()?;
        if token != expected {
            return invalid(format!(
                "expected PDF keyword {}",
                String::from_utf8_lossy(expected)
            ));
        }
        Ok(())
    }

    fn unsigned(&mut self) -> Result<u64, ParseError> {
        let token = self.token()?;
        if token.is_empty() || !token.iter().all(u8::is_ascii_digit) || token.len() > 19 {
            return invalid("expected an unsigned PDF integer");
        }
        Ok(std::str::from_utf8(token)
            .expect("ASCII digits")
            .parse()
            .expect("bounded digits"))
    }

    fn object(&mut self, depth: usize) -> Result<Object, ParseError> {
        if depth > MAX_NESTING {
            return invalid("PDF object nesting is too deep");
        }
        self.skip_whitespace();
        let Some(byte) = self.peek() else {
            return Err(self.end());
        };
        match byte {
            b'/' => {
                self.pos += 1;
                Ok(Object::Name(self.name()?))
            }
            b'(' => {
                self.pos += 1;
                Ok(Object::String(self.literal_string()?))
            }
            b'<' if self.bytes.get(self.pos + 1) == Some(&b'<') => {
                self.pos += 2;
                let mut dictionary = Dictionary::new();
                loop {
                    self.skip_whitespace();
                    match (self.peek(), self.bytes.get(self.pos + 1)) {
                        (Some(b'>'), Some(b'>')) => {
                            self.pos += 2;
                            return Ok(Object::Dictionary(dictionary));
                        }
                        (Some(b'/'), _) => {
                            self.pos += 1;
                            let key = self.name()?;
                            let value = self.object(depth + 1)?;
                            set(&mut dictionary, &key, value);
                        }
                        (None, _) | (Some(b'>'), None) => return Err(self.end()),
                        _ => return invalid("PDF dictionary key is not a name"),
                    }
                }
            }
            b'<' => {
                self.pos += 1;
                Ok(Object::String(self.hex_string()?))
            }
            b'[' => {
                self.pos += 1;
                let mut items = Vec::new();
                loop {
                    self.skip_whitespace();
                    match self.peek() {
                        Some(b']') => {
                            self.pos += 1;
                            return Ok(Object::Array(items));
                        }
                        None => return Err(self.end()),
                        _ => items.push(self.object(depth + 1)?),
                    }
                }
            }
            b'0'..=b'9' | b'+' | b'-' | b'.' => self.number(),
            _ => match self.token()? {
                b"true" => Ok(Object::Bool(true)),
                b"false" => Ok(Object::Bool(false)),
                b"null" => Ok(Object::Null),
                other => invalid(format!(
                    "unexpected PDF token {}",
                    String::from_utf8_lossy(&other[..other.len().min(32)])
                )),
            },
        }
    }

    fn number(&mut self) -> Result<Object, ParseError> {
        let token = self.token()?;
        let text = std::str::from_utf8(token).map_err(|_| "invalid PDF number".to_string())?;
        if text.contains('.') {
            if text.parse::<f64>().is_err() {
                return invalid("invalid PDF real number");
            }
            return Ok(Object::Real(text.to_string()));
        }
        let value: i64 = text
            .parse()
            .map_err(|_| "invalid PDF integer".to_string())?;
        // `n g R` is an indirect reference; anything else leaves the integer.
        if (0..=i64::from(u32::MAX)).contains(&value) {
            let saved = self.pos;
            let reference = (|| -> Result<Option<u16>, ParseError> {
                let generation = self.token()?;
                if !generation.iter().all(u8::is_ascii_digit) || generation.len() > 5 {
                    return Ok(None);
                }
                let generation: u32 = std::str::from_utf8(generation)
                    .expect("ASCII digits")
                    .parse()
                    .expect("bounded digits");
                if generation > u32::from(u16::MAX) || self.token()? != b"R" {
                    return Ok(None);
                }
                Ok(Some(generation as u16))
            })();
            match reference {
                Ok(Some(generation)) => return Ok(Object::Reference(value as u32, generation)),
                Err(ParseError::Truncated) => return Err(ParseError::Truncated),
                _ => self.pos = saved,
            }
        }
        Ok(Object::Integer(value))
    }

    fn name(&mut self) -> Result<Vec<u8>, ParseError> {
        let mut name = Vec::new();
        while let Some(byte) = self.peek() {
            if !is_regular(byte) {
                break;
            }
            self.pos += 1;
            if byte == b'#' {
                let digits = self
                    .bytes
                    .get(self.pos..self.pos + 2)
                    .ok_or_else(|| self.end())?;
                let value = std::str::from_utf8(digits)
                    .ok()
                    .and_then(|digits| u8::from_str_radix(digits, 16).ok())
                    .ok_or_else(|| "invalid PDF name escape".to_string())?;
                name.push(value);
                self.pos += 2;
            } else {
                name.push(byte);
            }
        }
        if self.pos == self.bytes.len() && !self.complete {
            return Err(ParseError::Truncated);
        }
        Ok(name)
    }

    fn literal_string(&mut self) -> Result<Vec<u8>, ParseError> {
        let mut output = Vec::new();
        let mut depth = 1usize;
        loop {
            let Some(byte) = self.peek() else {
                return Err(self.end());
            };
            self.pos += 1;
            match byte {
                b'(' => {
                    depth += 1;
                    output.push(byte);
                }
                b')' => {
                    depth -= 1;
                    if depth == 0 {
                        return Ok(output);
                    }
                    output.push(byte);
                }
                b'\r' => {
                    if self.peek() == Some(b'\n') {
                        self.pos += 1;
                    }
                    output.push(b'\n');
                }
                b'\\' => {
                    let Some(escaped) = self.peek() else {
                        return Err(self.end());
                    };
                    self.pos += 1;
                    match escaped {
                        b'n' => output.push(b'\n'),
                        b'r' => output.push(b'\r'),
                        b't' => output.push(b'\t'),
                        b'b' => output.push(0x08),
                        b'f' => output.push(0x0c),
                        b'\r' => {
                            if self.peek() == Some(b'\n') {
                                self.pos += 1;
                            }
                        }
                        b'\n' => {}
                        b'0'..=b'7' => {
                            let mut value = u32::from(escaped - b'0');
                            for _ in 0..2 {
                                match self.peek() {
                                    Some(digit @ b'0'..=b'7') => {
                                        value = value * 8 + u32::from(digit - b'0');
                                        self.pos += 1;
                                    }
                                    _ => break,
                                }
                            }
                            output.push((value & 0xff) as u8);
                        }
                        other => output.push(other),
                    }
                }
                other => output.push(other),
            }
        }
    }

    fn hex_string(&mut self) -> Result<Vec<u8>, ParseError> {
        let mut output = Vec::new();
        let mut high: Option<u8> = None;
        loop {
            let Some(byte) = self.peek() else {
                return Err(self.end());
            };
            self.pos += 1;
            if byte == b'>' {
                if let Some(high) = high {
                    output.push(high << 4);
                }
                return Ok(output);
            }
            if is_whitespace(byte) {
                continue;
            }
            let nibble = (byte as char)
                .to_digit(16)
                .ok_or_else(|| "invalid PDF hex string".to_string())?
                as u8;
            match high.take() {
                Some(value) => output.push((value << 4) | nibble),
                None => high = Some(nibble),
            }
        }
    }
}

#[derive(Clone, Copy, Debug)]
enum XrefEntry {
    Free,
    Offset { offset: u64, generation: u16 },
    Compressed { stream: u32, index: u32 },
}

struct IndirectObject {
    number: u32,
    generation: u16,
    object: Object,
    /// Absolute offset of the stream data when the object is a stream.
    stream_offset: Option<u64>,
}

/// A PDF opened for metadata access, with its merged cross-reference table.
struct PdfDocument<'f, F: Read + Seek> {
    file: &'f mut F,
    len: u64,
    entries: BTreeMap<u32, XrefEntry>,
    /// The newest trailer (or cross-reference stream dictionary).
    trailer: Dictionary,
    startxref: u64,
    newest_is_stream: bool,
}

impl<'f, F: Read + Seek> PdfDocument<'f, F> {
    fn open(file: &'f mut F) -> Result<Self, String> {
        let len = file
            .seek(SeekFrom::End(0))
            .map_err(|error| format!("measure PDF: {error}"))?;
        let tail_start = len.saturating_sub(TAIL_WINDOW);
        let tail = read_at(file, tail_start, len - tail_start)?;
        if !tail.windows(5).any(|window| window == b"%%EOF") {
            return Err("PDF has no end-of-file marker".to_string());
        }
        let marker = tail
            .windows(9)
            .rposition(|window| window == b"startxref")
            .ok_or_else(|| "PDF has no startxref pointer".to_string())?;
        let mut parser = Parser::new(&tail[marker + 9..], true);
        let startxref = parser
            .unsigned()
            .map_err(|_| "PDF startxref pointer is invalid".to_string())?;
        if startxref >= len {
            return Err("PDF startxref pointer is outside the file".to_string());
        }
        let mut document = Self {
            file,
            len,
            entries: BTreeMap::new(),
            trailer: Dictionary::new(),
            startxref,
            newest_is_stream: false,
        };
        // Newest section first. A hybrid section's /XRefStm is consulted
        // before its /Prev; entries already defined are never overwritten.
        let mut pending = vec![(startxref, true)];
        let mut visited = BTreeSet::new();
        let mut first = true;
        while let Some((offset, follow_prev)) = pending.pop() {
            if !visited.insert(offset) || visited.len() > MAX_XREF_SECTIONS {
                return Err("PDF cross-reference chain loops or is too long".to_string());
            }
            let (trailer, is_stream) = document.load_xref_section(offset)?;
            if first {
                document.trailer = trailer.clone();
                document.newest_is_stream = is_stream;
                first = false;
            }
            if follow_prev && let Some(Object::Integer(previous)) = get(&trailer, b"Prev") {
                pending.push((offset_value(*previous, len)?, true));
            }
            if !is_stream && let Some(Object::Integer(stream)) = get(&trailer, b"XRefStm") {
                pending.push((offset_value(*stream, len)?, false));
            }
        }
        Ok(document)
    }

    fn insert(&mut self, number: u32, entry: XrefEntry) {
        self.entries.entry(number).or_insert(entry);
    }

    fn load_xref_section(&mut self, offset: u64) -> Result<(Dictionary, bool), String> {
        let head = read_at(self.file, offset, 4.min(self.len - offset))?;
        if head.starts_with(b"xref") {
            let (entries, trailer) = self.with_window(offset, |parser| {
                parser.keyword(b"xref")?;
                let mut entries = Vec::new();
                loop {
                    parser.skip_whitespace();
                    if parser.bytes[parser.pos..].starts_with(b"trailer") {
                        parser.keyword(b"trailer")?;
                        let Object::Dictionary(trailer) = parser.object(0)? else {
                            return invalid("PDF trailer is not a dictionary");
                        };
                        return Ok((entries, trailer));
                    }
                    let start = parser.unsigned()?;
                    let count = parser.unsigned()?;
                    if start.saturating_add(count) > u64::from(u32::MAX) {
                        return invalid("PDF cross-reference subsection is out of range");
                    }
                    for index in 0..count {
                        let entry_offset = parser.unsigned()?;
                        let generation = parser.unsigned()?;
                        let kind = parser.token()?;
                        let number = (start + index) as u32;
                        let entry = match kind {
                            b"n" if generation <= u64::from(u16::MAX) => XrefEntry::Offset {
                                offset: entry_offset,
                                generation: generation as u16,
                            },
                            b"f" => XrefEntry::Free,
                            _ => return invalid("PDF cross-reference entry is invalid"),
                        };
                        entries.push((number, entry));
                    }
                }
            })?;
            for (number, entry) in entries {
                self.insert(number, entry);
            }
            return Ok((trailer, false));
        }
        let object = self.indirect_object(offset)?;
        let Object::Dictionary(dictionary) = &object.object else {
            return Err("PDF startxref does not point at a cross-reference section".to_string());
        };
        if get(dictionary, b"Type") != Some(&Object::Name(b"XRef".to_vec())) {
            return Err("PDF startxref does not point at a cross-reference section".to_string());
        }
        let data = self.stream_data(&object, 0)?;
        let widths = match get(dictionary, b"W") {
            Some(Object::Array(items)) if items.len() == 3 => items
                .iter()
                .map(|item| match item {
                    Object::Integer(width @ 0..=8) => Ok(*width as usize),
                    _ => Err("PDF cross-reference stream width is invalid".to_string()),
                })
                .collect::<Result<Vec<_>, _>>()?,
            _ => return Err("PDF cross-reference stream has no /W array".to_string()),
        };
        let size = match get(dictionary, b"Size") {
            Some(Object::Integer(size)) if (0..=i64::from(u32::MAX)).contains(size) => *size,
            _ => return Err("PDF cross-reference stream has no /Size".to_string()),
        };
        let index = match get(dictionary, b"Index") {
            Some(Object::Array(items)) if items.len() % 2 == 0 => items
                .iter()
                .map(|item| match item {
                    Object::Integer(value) if (0..=i64::from(u32::MAX)).contains(value) => {
                        Ok(*value as u64)
                    }
                    _ => Err("PDF cross-reference stream index is invalid".to_string()),
                })
                .collect::<Result<Vec<_>, _>>()?,
            None => vec![0, size as u64],
            _ => return Err("PDF cross-reference stream index is invalid".to_string()),
        };
        let row = widths.iter().sum::<usize>();
        if row == 0 {
            return Err("PDF cross-reference stream rows are empty".to_string());
        }
        let field = |bytes: &[u8]| {
            bytes
                .iter()
                .fold(0u64, |value, byte| (value << 8) | u64::from(*byte))
        };
        let mut rows = data.chunks_exact(row);
        for pair in index.chunks(2) {
            for number in pair[0]..pair[0].saturating_add(pair[1]) {
                let Some(row) = rows.next() else {
                    return Err("PDF cross-reference stream is shorter than its index".to_string());
                };
                let kind = if widths[0] == 0 {
                    1
                } else {
                    field(&row[..widths[0]])
                };
                let second = field(&row[widths[0]..widths[0] + widths[1]]);
                let third = field(&row[widths[0] + widths[1]..]);
                let entry = match kind {
                    0 => XrefEntry::Free,
                    1 => XrefEntry::Offset {
                        offset: second,
                        generation: third.min(u64::from(u16::MAX)) as u16,
                    },
                    2 => XrefEntry::Compressed {
                        stream: u32::try_from(second)
                            .map_err(|_| "PDF object stream number is invalid".to_string())?,
                        index: u32::try_from(third)
                            .map_err(|_| "PDF object stream index is invalid".to_string())?,
                    },
                    // Unknown types are treated as null references (§7.5.8.3).
                    _ => XrefEntry::Free,
                };
                if let Ok(number) = u32::try_from(number) {
                    self.insert(number, entry);
                }
            }
        }
        Ok((dictionary.clone(), true))
    }

    /// Parse from `offset` with a window that grows until the construct fits.
    fn with_window<T>(
        &mut self,
        offset: u64,
        mut parse: impl FnMut(&mut Parser<'_>) -> Result<T, ParseError>,
    ) -> Result<T, String> {
        let mut window = INITIAL_WINDOW;
        loop {
            let available = self.len - offset;
            let length = window.min(available);
            let bytes = read_at(self.file, offset, length)?;
            let mut parser = Parser::new(&bytes, length == available);
            match parse(&mut parser) {
                Ok(value) => return Ok(value),
                Err(ParseError::Invalid(message)) => return Err(message),
                Err(ParseError::Truncated) if window < MAX_WINDOW && length < available => {
                    window *= 4;
                }
                Err(ParseError::Truncated) => {
                    return Err("PDF object exceeds the safe parsing window".to_string())
                }
            }
        }
    }

    fn indirect_object(&mut self, offset: u64) -> Result<IndirectObject, String> {
        if offset >= self.len {
            return Err("PDF object offset is outside the file".to_string());
        }
        self.with_window(offset, |parser| {
            let number = parser.unsigned()?;
            let generation = parser.unsigned()?;
            parser.keyword(b"obj")?;
            let object = parser.object(0)?;
            let save = parser.pos;
            parser.skip_whitespace();
            let rest = &parser.bytes[parser.pos..];
            let is_dictionary = matches!(object, Object::Dictionary(_));
            if is_dictionary && rest.len() < 8 && !parser.complete {
                return Err(ParseError::Truncated);
            }
            let stream_offset = if is_dictionary && rest.starts_with(b"stream") {
                let mut data = parser.pos + 6;
                if parser.bytes.get(data) == Some(&b'\r') {
                    data += 1;
                }
                if parser.bytes.get(data) == Some(&b'\n') {
                    data += 1;
                }
                Some(offset + data as u64)
            } else {
                parser.pos = save;
                None
            };
            if number > u64::from(u32::MAX) || generation > u64::from(u16::MAX) {
                return invalid("PDF object number is out of range");
            }
            Ok(IndirectObject {
                number: number as u32,
                generation: generation as u16,
                object,
                stream_offset,
            })
        })
    }

    fn stream_data(&mut self, object: &IndirectObject, depth: usize) -> Result<Vec<u8>, String> {
        let (Object::Dictionary(dictionary), Some(offset)) = (&object.object, object.stream_offset)
        else {
            return Err("PDF object is not a stream".to_string());
        };
        let length = match get(dictionary, b"Length") {
            Some(Object::Integer(length)) => *length,
            Some(Object::Reference(number, _)) if depth < 2 => {
                match self.resolve(*number, depth + 1)? {
                    Object::Integer(length) => length,
                    _ => return Err("PDF stream length is invalid".to_string()),
                }
            }
            _ => return Err("PDF stream has no usable /Length".to_string()),
        };
        let length =
            u64::try_from(length).map_err(|_| "PDF stream length is negative".to_string())?;
        if length > MAX_STREAM_BYTES || offset.saturating_add(length) > self.len {
            return Err("PDF stream exceeds the safe metadata limit".to_string());
        }
        let raw = read_at(self.file, offset, length)?;
        let filters = match get(dictionary, b"Filter") {
            None | Some(Object::Null) => Vec::new(),
            Some(Object::Name(name)) => vec![name.clone()],
            Some(Object::Array(items)) => items
                .iter()
                .map(|item| match item {
                    Object::Name(name) => Ok(name.clone()),
                    _ => Err("PDF stream filter is invalid".to_string()),
                })
                .collect::<Result<_, _>>()?,
            _ => return Err("PDF stream filter is invalid".to_string()),
        };
        let parameters = match get(dictionary, b"DecodeParms") {
            Some(Object::Array(items)) => items.clone(),
            Some(other) => vec![other.clone()],
            None => Vec::new(),
        };
        let mut data = raw;
        for (index, filter) in filters.iter().enumerate() {
            if !matches!(filter.as_slice(), b"FlateDecode" | b"Fl") {
                return Err(format!(
                    "PDF stream filter {} is not supported for metadata edits",
                    String::from_utf8_lossy(filter)
                ));
            }
            let mut decoded = Vec::new();
            ZlibDecoder::new(data.as_slice())
                .take(MAX_STREAM_BYTES + 1)
                .read_to_end(&mut decoded)
                .map_err(|error| format!("inflate PDF stream: {error}"))?;
            if decoded.len() as u64 > MAX_STREAM_BYTES {
                return Err("PDF stream exceeds the safe metadata limit".to_string());
            }
            data = match parameters.get(index) {
                Some(Object::Dictionary(parameters)) => unpredict(decoded, parameters)?,
                _ => decoded,
            };
        }
        Ok(data)
    }

    fn resolve(&mut self, number: u32, depth: usize) -> Result<Object, String> {
        Ok(self.resolve_indirect(number, depth)?.object)
    }

    fn resolve_indirect(&mut self, number: u32, depth: usize) -> Result<IndirectObject, String> {
        if depth > 4 {
            return Err("PDF object references nest too deeply".to_string());
        }
        match self.entries.get(&number).copied() {
            None | Some(XrefEntry::Free) => Ok(IndirectObject {
                number,
                generation: 0,
                object: Object::Null,
                stream_offset: None,
            }),
            Some(XrefEntry::Offset { offset, generation }) => {
                let object = self.indirect_object(offset)?;
                if object.number != number || object.generation != generation {
                    return Err(format!(
                        "PDF cross-reference entry for object {number} points at the wrong object"
                    ));
                }
                Ok(object)
            }
            Some(XrefEntry::Compressed { stream, index }) => {
                let Some(XrefEntry::Offset { offset, .. }) = self.entries.get(&stream).copied()
                else {
                    return Err("PDF object stream is missing".to_string());
                };
                let container = self.indirect_object(offset)?;
                let Object::Dictionary(dictionary) = &container.object else {
                    return Err("PDF object stream is invalid".to_string());
                };
                let (Some(Object::Integer(count)), Some(Object::Integer(first))) =
                    (get(dictionary, b"N"), get(dictionary, b"First"))
                else {
                    return Err("PDF object stream has no /N or /First".to_string());
                };
                let (count, first) = (*count, *first);
                let data = self.stream_data(&container, depth + 1)?;
                let mut parser = Parser::new(&data, true);
                let mut location = None;
                for position in 0..count.max(0) {
                    let candidate = parser.unsigned().map_err(parse_message)?;
                    let relative = parser.unsigned().map_err(parse_message)?;
                    if candidate == u64::from(number)
                        && (location.is_none() || position == i64::from(index))
                    {
                        location = Some(relative);
                    }
                }
                let relative = location
                    .ok_or_else(|| format!("PDF object {number} is not in its object stream"))?;
                let start = usize::try_from(first.max(0) as u64 + relative)
                    .ok()
                    .filter(|start| *start < data.len())
                    .ok_or_else(|| "PDF object stream offset is invalid".to_string())?;
                let mut parser = Parser::new(&data[start..], true);
                let object = parser.object(0).map_err(parse_message)?;
                Ok(IndirectObject {
                    number,
                    generation: 0,
                    object,
                    stream_offset: None,
                })
            }
        }
    }

    fn dereference(&mut self, object: &Object) -> Result<Object, String> {
        match object {
            Object::Reference(number, _) => self.resolve(*number, 0),
            other => Ok(other.clone()),
        }
    }

    fn catalog(&mut self) -> Result<(u32, u16, Dictionary), String> {
        let Some(Object::Reference(number, _)) = get(&self.trailer, b"Root").cloned() else {
            return Err("PDF trailer has no catalog reference".to_string());
        };
        let object = self.resolve_indirect(number, 0)?;
        let Object::Dictionary(catalog) = object.object else {
            return Err("PDF catalog is not a dictionary".to_string());
        };
        Ok((number, object.generation, catalog))
    }

    fn info(&mut self) -> Result<Dictionary, String> {
        match get(&self.trailer, b"Info").cloned() {
            Some(info) => match self.dereference(&info)? {
                Object::Dictionary(info) => Ok(info),
                _ => Ok(Dictionary::new()),
            },
            None => Ok(Dictionary::new()),
        }
    }

    fn xmp(&mut self) -> Result<Option<Vec<u8>>, String> {
        let (_, _, catalog) = self.catalog()?;
        let Some(Object::Reference(number, _)) = get(&catalog, b"Metadata").cloned() else {
            return Ok(None);
        };
        let object = self.resolve_indirect(number, 0)?;
        if object.stream_offset.is_none() {
            return Ok(None);
        }
        let data = self.stream_data(&object, 0)?;
        if data.len() > MAX_XMP_BYTES {
            return Err("PDF XMP packet exceeds the safe metadata limit".to_string());
        }
        Ok(Some(data))
    }

    /// Whether the document carries a digital signature field or a
    /// certification signature. Writing an incremental update would leave
    /// those signatures covering only the original revision, so viewers would
    /// report a modified or policy-violating document.
    fn has_signature(&mut self) -> Result<bool, String> {
        let (_, _, catalog) = self.catalog()?;
        if get(&catalog, b"Perms").is_some() {
            return Ok(true);
        }
        let Some(acro_form) = get(&catalog, b"AcroForm").cloned() else {
            return Ok(false);
        };
        let Object::Dictionary(acro_form) = self.dereference(&acro_form)? else {
            return Ok(false);
        };
        let Some(Object::Array(fields)) = get(&acro_form, b"Fields").cloned() else {
            return Ok(false);
        };
        let mut pending = fields;
        let mut visited = 0usize;
        while let Some(field) = pending.pop() {
            visited += 1;
            if visited > 4096 {
                return Err("PDF form field tree exceeds the safe limit".to_string());
            }
            let Object::Dictionary(field) = self.dereference(&field)? else {
                continue;
            };
            let kind_is_signature =
                get(&field, b"FT").is_some_and(|kind| kind == &Object::Name(b"Sig".to_vec()));
            let value_is_signature = match get(&field, b"V").cloned() {
                Some(value) => match self.dereference(&value)? {
                    Object::Dictionary(value) => {
                        get(&value, b"ByteRange").is_some()
                            || get(&value, b"Type")
                                .is_some_and(|kind| kind == &Object::Name(b"Sig".to_vec()))
                    }
                    _ => false,
                },
                None => false,
            };
            if kind_is_signature || value_is_signature {
                return Ok(true);
            }
            if let Some(Object::Array(kids)) = get(&field, b"Kids").cloned() {
                pending.extend(kids);
            }
        }
        Ok(false)
    }

    fn next_object_number(&self) -> Result<u32, String> {
        let size = match get(&self.trailer, b"Size") {
            Some(Object::Integer(size)) if *size >= 0 => *size as u64,
            _ => 0,
        };
        let highest = self
            .entries
            .keys()
            .next_back()
            .map_or(0, |number| u64::from(*number) + 1);
        u32::try_from(size.max(highest))
            .ok()
            .filter(|next| *next < u32::MAX - 8)
            .ok_or_else(|| "PDF object numbers are exhausted".to_string())
    }
}

fn parse_message(error: ParseError) -> String {
    match error {
        ParseError::Truncated => "unexpected end of PDF data".to_string(),
        ParseError::Invalid(message) => message,
    }
}

fn offset_value(value: i64, len: u64) -> Result<u64, String> {
    u64::try_from(value)
        .ok()
        .filter(|offset| *offset < len)
        .ok_or_else(|| "PDF cross-reference offset is outside the file".to_string())
}

fn read_at<F: Read + Seek>(file: &mut F, offset: u64, length: u64) -> Result<Vec<u8>, String> {
    file.seek(SeekFrom::Start(offset))
        .map_err(|error| format!("seek PDF: {error}"))?;
    let mut bytes = Vec::with_capacity(length as usize);
    file.by_ref()
        .take(length)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("read PDF: {error}"))?;
    if bytes.len() as u64 != length {
        return Err("PDF ended unexpectedly".to_string());
    }
    Ok(bytes)
}

/// Reverse a PNG (10–15) predictor, the only kind cross-reference and object
/// streams use in practice. TIFF predictors are refused.
fn unpredict(data: Vec<u8>, parameters: &Dictionary) -> Result<Vec<u8>, String> {
    let integer = |key: &[u8], default: i64| match get(parameters, key) {
        Some(Object::Integer(value)) => *value,
        _ => default,
    };
    let predictor = integer(b"Predictor", 1);
    if predictor == 1 {
        return Ok(data);
    }
    if !(10..=15).contains(&predictor) {
        return Err("PDF stream predictor is not supported".to_string());
    }
    let colors = integer(b"Colors", 1);
    let bits = integer(b"BitsPerComponent", 8);
    let columns = integer(b"Columns", 1);
    if !(1..=32).contains(&colors)
        || !matches!(bits, 1 | 2 | 4 | 8 | 16)
        || !(1..=1 << 20).contains(&columns)
    {
        return Err("PDF stream predictor parameters are invalid".to_string());
    }
    let bytes_per_pixel = ((colors * bits + 7) / 8) as usize;
    let row_length = ((columns * colors * bits + 7) / 8) as usize;
    let mut output = Vec::with_capacity(data.len());
    let mut previous = vec![0u8; row_length];
    for chunk in data.chunks(row_length + 1) {
        if chunk.len() != row_length + 1 {
            return Err("PDF predicted stream has a partial row".to_string());
        }
        let mut row = chunk[1..].to_vec();
        for index in 0..row_length {
            let left = if index >= bytes_per_pixel {
                row[index - bytes_per_pixel]
            } else {
                0
            };
            let up = previous[index];
            let up_left = if index >= bytes_per_pixel {
                previous[index - bytes_per_pixel]
            } else {
                0
            };
            let prediction = match chunk[0] {
                0 => 0,
                1 => left,
                2 => up,
                3 => ((u16::from(left) + u16::from(up)) / 2) as u8,
                4 => {
                    let estimate = i16::from(left) + i16::from(up) - i16::from(up_left);
                    let (a, b, c) = (
                        (estimate - i16::from(left)).abs(),
                        (estimate - i16::from(up)).abs(),
                        (estimate - i16::from(up_left)).abs(),
                    );
                    if a <= b && a <= c {
                        left
                    } else if b <= c {
                        up
                    } else {
                        up_left
                    }
                }
                _ => return Err("PDF predicted stream has an invalid row filter".to_string()),
            };
            row[index] = row[index].wrapping_add(prediction);
        }
        output.extend_from_slice(&row);
        previous = row;
    }
    Ok(output)
}

fn write_object(output: &mut Vec<u8>, object: &Object) {
    match object {
        Object::Null => output.extend_from_slice(b"null"),
        Object::Bool(value) => output.extend_from_slice(if *value { b"true" } else { b"false" }),
        Object::Integer(value) => output.extend_from_slice(value.to_string().as_bytes()),
        Object::Real(value) => output.extend_from_slice(value.as_bytes()),
        Object::String(bytes) => {
            output.push(b'<');
            for byte in bytes {
                output.extend_from_slice(format!("{byte:02X}").as_bytes());
            }
            output.push(b'>');
        }
        Object::Name(name) => {
            output.push(b'/');
            for byte in name {
                if (0x21..=0x7e).contains(byte) && is_regular(*byte) && *byte != b'#' {
                    output.push(*byte);
                } else {
                    output.extend_from_slice(format!("#{byte:02X}").as_bytes());
                }
            }
        }
        Object::Array(items) => {
            output.push(b'[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    output.push(b' ');
                }
                write_object(output, item);
            }
            output.push(b']');
        }
        Object::Dictionary(dictionary) => {
            output.extend_from_slice(b"<<");
            for (key, value) in dictionary {
                write_object(output, &Object::Name(key.clone()));
                output.push(b' ');
                write_object(output, value);
            }
            output.extend_from_slice(b">>");
        }
        Object::Reference(number, generation) => {
            output.extend_from_slice(format!("{number} {generation} R").as_bytes());
        }
    }
}

/// Encode a PDF text string: PDFDocEncoding-compatible ASCII when possible,
/// otherwise UTF-16BE with a byte-order mark.
fn text_string(value: &str) -> Object {
    if value.bytes().all(|byte| (0x20..0x7f).contains(&byte)) {
        return Object::String(value.as_bytes().to_vec());
    }
    let mut bytes = vec![0xfe, 0xff];
    for unit in value.encode_utf16() {
        bytes.extend_from_slice(&unit.to_be_bytes());
    }
    Object::String(bytes)
}

fn decode_text_string(bytes: &[u8]) -> String {
    if let Some(utf16) = bytes.strip_prefix(&[0xfe, 0xff]) {
        let units = utf16
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| u16::from_be_bytes(*pair))
            .collect::<Vec<_>>();
        return String::from_utf16_lossy(&units);
    }
    if let Some(utf8) = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]) {
        return String::from_utf8_lossy(utf8).into_owned();
    }
    // PDFDocEncoding matches Latin-1 for every printable character in use.
    bytes.iter().map(|byte| char::from(*byte)).collect()
}

/// Document-level metadata read from a PDF's catalog and trailer.
#[derive(Debug, Default)]
pub struct PdfDocumentMetadata {
    /// The catalog's XMP packet, when present.
    pub xmp: Option<Vec<u8>>,
    /// Info dictionary text entries (Title, Author, Subject, Keywords, ...).
    pub info: BTreeMap<String, String>,
    /// Whether the document carries a digital signature or certification.
    /// An incremental update leaves the signed byte range intact but adds a
    /// revision outside it, so the writer refuses these documents.
    pub signed: bool,
}

/// Read the document XMP packet and Info dictionary through the
/// cross-reference table, so page-level XMP packets are never mistaken for
/// document metadata.
pub fn read_document_metadata<F: Read + Seek>(file: &mut F) -> Result<PdfDocumentMetadata, String> {
    let mut document = PdfDocument::open(file)?;
    if get(&document.trailer, b"Encrypt").is_some() {
        return Err("PDF is encrypted".to_string());
    }
    let signed = document.has_signature()?;
    let xmp = document.xmp()?;
    let info = document
        .info()?
        .into_iter()
        .filter_map(|(key, value)| match value {
            Object::String(bytes) => Some((
                String::from_utf8_lossy(&key).into_owned(),
                decode_text_string(&bytes),
            )),
            _ => None,
        })
        .collect();
    Ok(PdfDocumentMetadata { xmp, info, signed })
}

/// Info dictionary keys that a metadata edit owns. A `None` value removes the
/// key so a cleared field cannot leave a stale value behind.
pub struct PdfInfoUpdate {
    pub title: Option<String>,
    pub author: Option<String>,
    pub subject: Option<String>,
    pub keywords: Option<String>,
}

/// Copy `input` to `output` unchanged and append an incremental update that
/// points the catalog at a new XMP packet and the trailer at a new Info
/// dictionary. Returns the number of bytes appended after validating that the
/// result resolves to exactly the new metadata.
pub fn append_metadata_update<I, O>(
    input: &mut I,
    output: &mut O,
    xmp: &str,
    info_update: &PdfInfoUpdate,
) -> Result<u64, String>
where
    I: Read + Seek,
    O: Read + Write + Seek,
{
    if xmp.len() > MAX_XMP_BYTES {
        return Err("generated XMP exceeds the safe metadata limit".to_string());
    }
    let mut document = PdfDocument::open(input)?;
    if get(&document.trailer, b"Encrypt").is_some() {
        return Err("encrypted PDFs cannot be edited safely".to_string());
    }
    if document.has_signature()? {
        return Err(
            "signed PDFs cannot be edited; the new revision would invalidate the signature"
                .to_string(),
        );
    }
    let (catalog_number, catalog_generation, mut catalog) = document.catalog()?;
    if get(&catalog, b"Type").is_some_and(|kind| kind != &Object::Name(b"Catalog".to_vec())) {
        return Err("PDF catalog has an unexpected type".to_string());
    }
    let mut info = document.info()?;
    let next = document.next_object_number()?;
    let previous = document.startxref;
    let newest_is_stream = document.newest_is_stream;
    let identifier = get(&document.trailer, b"ID").cloned();
    let original_len = document.len;
    drop(document);

    let xmp_number = next;
    let info_number = next + 1;
    set(&mut catalog, b"Metadata", Object::Reference(xmp_number, 0));
    for (key, value) in [
        (&b"Title"[..], &info_update.title),
        (b"Author", &info_update.author),
        (b"Subject", &info_update.subject),
        (b"Keywords", &info_update.keywords),
    ] {
        match value
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            Some(value) => set(&mut info, key, text_string(value)),
            None => info.retain(|(candidate, _)| candidate != key),
        }
    }

    input
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("rewind PDF: {error}"))?;
    output
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("rewind output: {error}"))?;
    let copied = std::io::copy(&mut input.by_ref().take(original_len), output)
        .map_err(|error| format!("copy PDF: {error}"))?;
    if copied != original_len {
        return Err("PDF changed while it was being copied".to_string());
    }
    let last = read_at(input, original_len - 1, 1)?;

    let mut update = Vec::new();
    if !matches!(last[0], b'\n' | b'\r') {
        update.push(b'\n');
    }
    let mut offsets = Vec::new();
    let mut record = |update: &mut Vec<u8>, number: u32, generation: u16| {
        offsets.push((number, generation, original_len + update.len() as u64));
    };

    record(&mut update, catalog_number, catalog_generation);
    update.extend_from_slice(format!("{catalog_number} {catalog_generation} obj\n").as_bytes());
    write_object(&mut update, &Object::Dictionary(catalog));
    update.extend_from_slice(b"\nendobj\n");

    // XMP stays uncompressed so tools without a PDF parser can still find it.
    record(&mut update, xmp_number, 0);
    update.extend_from_slice(
        format!(
            "{xmp_number} 0 obj\n<</Type /Metadata /Subtype /XML /Length {}>>\nstream\n",
            xmp.len()
        )
        .as_bytes(),
    );
    update.extend_from_slice(xmp.as_bytes());
    update.extend_from_slice(b"\nendstream\nendobj\n");

    record(&mut update, info_number, 0);
    update.extend_from_slice(format!("{info_number} 0 obj\n").as_bytes());
    write_object(&mut update, &Object::Dictionary(info));
    update.extend_from_slice(b"\nendobj\n");

    let mut trailer = Dictionary::new();
    set(
        &mut trailer,
        b"Root",
        Object::Reference(catalog_number, catalog_generation),
    );
    set(&mut trailer, b"Info", Object::Reference(info_number, 0));
    set(&mut trailer, b"Prev", Object::Integer(previous as i64));
    if let Some(identifier) = identifier {
        set(&mut trailer, b"ID", identifier);
    }
    let xref_offset = original_len + update.len() as u64;
    if newest_is_stream {
        // Match the existing revision's cross-reference form.
        let xref_number = info_number + 1;
        offsets.push((xref_number, 0, xref_offset));
        offsets.sort_by_key(|(number, _, _)| *number);
        let mut index = Vec::new();
        let mut rows = Vec::new();
        for (number, generation, offset) in &offsets {
            match index.last_mut() {
                Some((start, count)) if *start + *count == i64::from(*number) => *count += 1,
                _ => index.push((i64::from(*number), 1)),
            }
            rows.push(1u8);
            rows.extend_from_slice(&offset.to_be_bytes());
            rows.extend_from_slice(&generation.to_be_bytes());
        }
        set(&mut trailer, b"Type", Object::Name(b"XRef".to_vec()));
        set(
            &mut trailer,
            b"Size",
            Object::Integer(i64::from(xref_number) + 1),
        );
        set(
            &mut trailer,
            b"Index",
            Object::Array(
                index
                    .into_iter()
                    .flat_map(|(start, count)| [Object::Integer(start), Object::Integer(count)])
                    .collect(),
            ),
        );
        set(
            &mut trailer,
            b"W",
            Object::Array(vec![
                Object::Integer(1),
                Object::Integer(8),
                Object::Integer(2),
            ]),
        );
        set(&mut trailer, b"Length", Object::Integer(rows.len() as i64));
        update.extend_from_slice(format!("{xref_number} 0 obj\n").as_bytes());
        write_object(&mut update, &Object::Dictionary(trailer));
        update.extend_from_slice(b"\nstream\n");
        update.extend_from_slice(&rows);
        update.extend_from_slice(b"\nendstream\nendobj\n");
    } else {
        offsets.sort_by_key(|(number, _, _)| *number);
        update.extend_from_slice(b"xref\n");
        let mut position = 0;
        while position < offsets.len() {
            let mut end = position + 1;
            while end < offsets.len() && offsets[end].0 == offsets[end - 1].0 + 1 {
                end += 1;
            }
            update.extend_from_slice(
                format!("{} {}\n", offsets[position].0, end - position).as_bytes(),
            );
            for (_, generation, offset) in &offsets[position..end] {
                update.extend_from_slice(format!("{offset:010} {generation:05} n\r\n").as_bytes());
            }
            position = end;
        }
        set(
            &mut trailer,
            b"Size",
            Object::Integer(i64::from(info_number) + 1),
        );
        update.extend_from_slice(b"trailer\n");
        write_object(&mut update, &Object::Dictionary(trailer));
        update.push(b'\n');
    }
    update.extend_from_slice(format!("startxref\n{xref_offset}\n%%EOF\n").as_bytes());
    output
        .write_all(&update)
        .map_err(|error| format!("append PDF update: {error}"))?;
    output
        .flush()
        .map_err(|error| format!("flush PDF: {error}"))?;

    // Validate by resolving the result exactly as a reader would.
    let written = read_document_metadata(output)
        .map_err(|error| format!("updated PDF did not validate: {error}"))?;
    if written.xmp.as_deref() != Some(xmp.as_bytes()) {
        return Err("updated PDF did not resolve to the new XMP packet".to_string());
    }
    if written.info.get("Title").map(String::as_str)
        != info_update
            .title
            .as_deref()
            .map(str::trim)
            .filter(|title| !title.is_empty())
    {
        return Err("updated PDF did not resolve to the new Info dictionary".to_string());
    }
    Ok(update.len() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    const XMP: &str = "<?xpacket begin=\"\u{feff}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/><?xpacket end=\"w\"?>";

    /// A minimal classic-table PDF with an old XMP packet and Info title.
    fn classic_pdf() -> Vec<u8> {
        let mut pdf = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n".to_vec();
        let mut offsets = Vec::new();
        let old_xmp = b"<x:xmpmeta>old</x:xmpmeta>";
        let objects: Vec<Vec<u8>> = vec![
            b"<< /Type /Catalog /Pages 2 0 R /Metadata 4 0 R /PageMode /UseOutlines /Lang (en\\)) >>".to_vec(),
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_vec(),
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>".to_vec(),
            [
                format!("<< /Type /Metadata /Subtype /XML /Length {} >>\nstream\n", old_xmp.len()).into_bytes(),
                old_xmp.to_vec(),
                b"\nendstream".to_vec(),
            ]
            .concat(),
            b"<< /Title (Old title) /Producer (Scanner 1.0) >>".to_vec(),
        ];
        for (index, body) in objects.iter().enumerate() {
            offsets.push(pdf.len());
            pdf.extend_from_slice(format!("{} 0 obj\n", index + 1).as_bytes());
            pdf.extend_from_slice(body);
            pdf.extend_from_slice(b"\nendobj\n");
        }
        let xref = pdf.len();
        pdf.extend_from_slice(b"xref\n0 6\n0000000000 65535 f\r\n");
        for offset in offsets {
            pdf.extend_from_slice(format!("{offset:010} 00000 n\r\n").as_bytes());
        }
        pdf.extend_from_slice(
            format!("trailer\n<< /Size 6 /Root 1 0 R /Info 5 0 R /ID [<AB> <CD>] >>\nstartxref\n{xref}\n%%EOF").as_bytes(),
        );
        pdf
    }

    /// A PDF 1.5 file whose catalog lives in a compressed object stream and
    /// whose cross-reference is a predicted, compressed stream.
    fn stream_pdf() -> Vec<u8> {
        use flate2::{write::ZlibEncoder, Compression};
        let compress = |bytes: &[u8]| {
            let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
            encoder.write_all(bytes).unwrap();
            encoder.finish().unwrap()
        };
        let mut pdf = b"%PDF-1.5\n".to_vec();
        let catalog = b"<< /Type /Catalog /Pages 2 0 R >>";
        let pages = b"<< /Type /Pages /Kids [] /Count 0 >>";
        let header = format!("1 0 2 {} ", catalog.len() + 1);
        let body = [header.as_bytes(), catalog, b" ", pages].concat();
        let packed = compress(&body);
        let objstm_offset = pdf.len();
        pdf.extend_from_slice(
            format!(
                "3 0 obj\n<< /Type /ObjStm /N 2 /First {} /Filter /FlateDecode /Length 4 0 R >>\nstream\n",
                header.len()
            )
            .as_bytes(),
        );
        pdf.extend_from_slice(&packed);
        pdf.extend_from_slice(b"\nendstream\nendobj\n");
        let length_offset = pdf.len();
        pdf.extend_from_slice(format!("4 0 obj\n{}\nendobj\n", packed.len()).as_bytes());
        let xref_offset = pdf.len();
        // Rows for objects 0..=5 with W [1 2 1], PNG Up predicted.
        let rows: Vec<[u8; 4]> = vec![
            [0, 0, 0, 0],
            [2, 0, 3, 0],
            [2, 0, 3, 1],
            [1, (objstm_offset >> 8) as u8, objstm_offset as u8, 0],
            [1, (length_offset >> 8) as u8, length_offset as u8, 0],
            [1, (xref_offset >> 8) as u8, xref_offset as u8, 0],
        ];
        let mut predicted = Vec::new();
        let mut previous = [0u8; 4];
        for row in rows {
            predicted.push(2);
            for index in 0..4 {
                predicted.push(row[index].wrapping_sub(previous[index]));
            }
            previous = row;
        }
        let packed = compress(&predicted);
        pdf.extend_from_slice(
            format!(
                "5 0 obj\n<< /Type /XRef /Size 6 /W [1 2 1] /Root 1 0 R /Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 4 >> /Length {} >>\nstream\n",
                packed.len()
            )
            .as_bytes(),
        );
        pdf.extend_from_slice(&packed);
        pdf.extend_from_slice(
            format!("\nendstream\nendobj\nstartxref\n{xref_offset}\n%%EOF\n").as_bytes(),
        );
        pdf
    }

    fn update(original: &[u8], xmp: &str) -> Vec<u8> {
        let mut output = Cursor::new(Vec::new());
        append_metadata_update(
            &mut Cursor::new(original.to_vec()),
            &mut output,
            xmp,
            &PdfInfoUpdate {
                title: Some("How Do We Know the Bible is True?".to_string()),
                author: Some("Ken Ham".to_string()),
                subject: None,
                keywords: Some("Apologetics".to_string()),
            },
        )
        .expect("incremental update");
        output.into_inner()
    }

    #[test]
    fn classic_update_preserves_original_bytes_and_replaces_metadata() {
        let original = classic_pdf();
        let before = read_document_metadata(&mut Cursor::new(original.clone())).unwrap();
        assert_eq!(
            before.xmp.as_deref(),
            Some(&b"<x:xmpmeta>old</x:xmpmeta>"[..])
        );
        assert_eq!(before.info["Title"], "Old title");

        let updated = update(&original, XMP);
        assert!(
            updated.starts_with(&original),
            "original revision must stay byte-identical"
        );
        let after = read_document_metadata(&mut Cursor::new(updated.clone())).unwrap();
        assert_eq!(after.xmp.as_deref(), Some(XMP.as_bytes()));
        assert_eq!(after.info["Title"], "How Do We Know the Bible is True?");
        assert_eq!(after.info["Author"], "Ken Ham");
        assert_eq!(
            after.info["Producer"], "Scanner 1.0",
            "unowned Info keys are kept"
        );
        assert!(!after.info.contains_key("Subject"));

        // The catalog keeps every other entry, including escaped strings.
        let mut cursor = Cursor::new(updated.clone());
        let mut document = PdfDocument::open(&mut cursor).unwrap();
        let (number, _, catalog) = document.catalog().unwrap();
        assert_eq!(number, 1);
        assert_eq!(
            get(&catalog, b"PageMode"),
            Some(&Object::Name(b"UseOutlines".to_vec()))
        );
        assert_eq!(
            get(&catalog, b"Lang"),
            Some(&Object::String(b"en)".to_vec()))
        );
        assert_eq!(get(&catalog, b"Pages"), Some(&Object::Reference(2, 0)));
        assert_eq!(
            get(&document.trailer, b"ID"),
            Some(&Object::Array(vec![
                Object::String(vec![0xab]),
                Object::String(vec![0xcd])
            ]))
        );

        // A second edit chains onto the first update.
        let again = update(&updated, "<x:xmpmeta>second</x:xmpmeta>");
        assert!(again.starts_with(&updated));
        let latest = read_document_metadata(&mut Cursor::new(again)).unwrap();
        assert_eq!(
            latest.xmp.as_deref(),
            Some(&b"<x:xmpmeta>second</x:xmpmeta>"[..])
        );
    }

    #[test]
    fn stream_update_resolves_catalog_from_object_stream() {
        let original = stream_pdf();
        let before = read_document_metadata(&mut Cursor::new(original.clone())).unwrap();
        assert!(before.xmp.is_none());
        let updated = update(&original, XMP);
        assert!(updated.starts_with(&original));
        let tail = String::from_utf8_lossy(&updated[original.len()..]).into_owned();
        assert!(
            tail.contains("/Type /XRef"),
            "stream-based files keep stream xrefs: {tail}"
        );
        let after = read_document_metadata(&mut Cursor::new(updated)).unwrap();
        assert_eq!(after.xmp.as_deref(), Some(XMP.as_bytes()));
        assert_eq!(after.info["Title"], "How Do We Know the Bible is True?");
        assert_eq!(after.info["Keywords"], "Apologetics");
    }

    #[test]
    fn non_ascii_info_text_round_trips_as_utf16() {
        let original = classic_pdf();
        let mut output = Cursor::new(Vec::new());
        append_metadata_update(
            &mut Cursor::new(original),
            &mut output,
            XMP,
            &PdfInfoUpdate {
                title: Some("Café — Ελληνικά".to_string()),
                author: None,
                subject: None,
                keywords: None,
            },
        )
        .unwrap();
        let after = read_document_metadata(&mut Cursor::new(output.into_inner())).unwrap();
        assert_eq!(after.info["Title"], "Café — Ελληνικά");
        assert!(!after.info.contains_key("Author"));
    }

    #[test]
    fn refuses_encrypted_and_damaged_documents() {
        // The trailer follows the table, so lengthening it moves no offsets.
        let original = classic_pdf();
        let trailer = original
            .windows(7)
            .rposition(|window| window == b"trailer")
            .unwrap();
        let encrypted = [
            &original[..trailer],
            &b"trailer\n<< /Encrypt 5 0 R"[..],
            &original[trailer + 10..],
        ]
        .concat();
        let error = append_metadata_update(
            &mut Cursor::new(encrypted),
            &mut Cursor::new(Vec::new()),
            XMP,
            &PdfInfoUpdate {
                title: Some("T".into()),
                author: None,
                subject: None,
                keywords: None,
            },
        )
        .unwrap_err();
        assert!(error.contains("encrypted"), "{error}");

        let mut damaged = classic_pdf();
        let position = damaged
            .windows(9)
            .rposition(|window| window == b"startxref")
            .unwrap();
        damaged.truncate(position);
        damaged.extend_from_slice(b"startxref\n3\n%%EOF");
        assert!(read_document_metadata(&mut Cursor::new(damaged)).is_err());
    }

    /// A minimal signed file: either a signature field or a certification
    /// signature in the catalog's `/Perms`.
    fn signed_pdf(certified: bool) -> Vec<u8> {
        let mut pdf = b"%PDF-1.4\n".to_vec();
        let catalog = if certified {
            b"<< /Type /Catalog /Pages 2 0 R /Perms << /DocMDP 5 0 R >> >>".to_vec()
        } else {
            b"<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] >> >>".to_vec()
        };
        let objects: Vec<Vec<u8>> = vec![
            catalog,
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_vec(),
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>".to_vec(),
            b"<< /Title (Signed book) >>".to_vec(),
            b"<< /Type /Sig /Filter /Adobe.PPKLite /ByteRange [0 0 0 0] /Contents <00> >>".to_vec(),
            b"<< /FT /Sig /T (Signature1) /V 5 0 R >>".to_vec(),
        ];
        let mut offsets = Vec::new();
        for (index, body) in objects.iter().enumerate() {
            offsets.push(pdf.len());
            pdf.extend_from_slice(format!("{} 0 obj\n", index + 1).as_bytes());
            pdf.extend_from_slice(body);
            pdf.extend_from_slice(b"\nendobj\n");
        }
        let xref = pdf.len();
        pdf.extend_from_slice(b"xref\n0 7\n0000000000 65535 f\r\n");
        for offset in offsets {
            pdf.extend_from_slice(format!("{offset:010} 00000 n\r\n").as_bytes());
        }
        pdf.extend_from_slice(
            format!("trailer\n<< /Size 7 /Root 1 0 R /Info 4 0 R >>\nstartxref\n{xref}\n%%EOF")
                .as_bytes(),
        );
        pdf
    }

    #[test]
    fn refuses_signed_and_certified_documents() {
        for certified in [false, true] {
            let mut file = Cursor::new(signed_pdf(certified));
            let metadata = read_document_metadata(&mut file).expect("read signed PDF");
            assert!(metadata.signed, "certified={certified}");
            let error = append_metadata_update(
                &mut Cursor::new(signed_pdf(certified)),
                &mut Cursor::new(Vec::new()),
                XMP,
                &PdfInfoUpdate {
                    title: Some("T".into()),
                    author: None,
                    subject: None,
                    keywords: None,
                },
            )
            .unwrap_err();
            assert!(error.contains("signed"), "{error}");
        }
        let unsigned = read_document_metadata(&mut Cursor::new(classic_pdf())).unwrap();
        assert!(!unsigned.signed);
    }
}
