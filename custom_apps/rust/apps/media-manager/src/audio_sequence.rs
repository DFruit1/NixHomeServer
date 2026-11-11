//! Authoritative folder order: lossless tag edits, matching filenames and portable playlists.
//! Rewrites are staged, never performed on originals. The broker archives originals before
//! installing them. Tests cover preservation because corrupting a rewrite could lose audio.
use lofty::{
    config::{ParseOptions, WriteOptions},
    file::{AudioFile, FileType, TaggedFileExt},
    probe::Probe,
    tag::{Accessor, Tag},
};
use std::{
    fs::File,
    io::{Seek, SeekFrom, Write},
};

pub const AUDIO_EXTENSIONS: &[&str] = &["mp3", "flac", "m4a", "m4b", "ogg", "opus"];

/// Edit every existing writable tag so a secondary ID3/APE tag cannot retain stale order.
/// Add the native primary tag when absent. Copying and tag rewriting never re-encode audio.
pub fn rewrite_audio_order(
    mut source: File,
    mut output: File,
    extension: &str,
    track: u32,
    total: u32,
) -> Result<(), String> {
    if !AUDIO_EXTENSIONS.contains(&extension) || track == 0 || track > total || total > 500 {
        return Err("Unsupported audio format or track sequence".into());
    }
    let file_type = FileType::from_ext(extension).ok_or("Unknown audio format")?;
    std::io::copy(&mut source, &mut output).map_err(|e| e.to_string())?;
    output.rewind().map_err(|e| e.to_string())?;
    let mut tagged = Probe::with_file_type(&mut output, file_type)
        .options(ParseOptions::new().read_properties(false))
        .read()
        .map_err(|e| e.to_string())?;
    let primary = tagged.primary_tag_type();
    if tagged.primary_tag().is_none() {
        tagged.insert_tag(Tag::new(primary));
    }
    let tag_types: Vec<_> = tagged.tags().iter().map(|tag| tag.tag_type()).collect();
    for tag_type in tag_types {
        let tag = tagged.tag_mut(tag_type).ok_or("Tag disappeared")?;
        tag.set_track(track);
        tag.set_track_total(total);
        // One continuous sequence across the folder must not be re-sorted by old disc tags.
        tag.set_disk(1);
        tag.set_disk_total(1);
    }
    output.rewind().map_err(|e| e.to_string())?;
    tagged
        .save_to(&mut output, WriteOptions::new().use_id3v23(true))
        .map_err(|e| e.to_string())?;
    output
        .flush()
        .and_then(|_| output.sync_all())
        .map_err(|e| e.to_string())?;
    output.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    let verified = Probe::with_file_type(&mut output, file_type)
        .options(ParseOptions::new().read_properties(false))
        .read()
        .map_err(|e| e.to_string())?;
    if verified.tags().is_empty()
        || verified.tags().iter().any(|tag| {
            tag.track() != Some(track)
                || (tag.track_total() != Some(total)
                    && tag.tag_type() != lofty::tag::TagType::Id3v1)
                || (tag.tag_type() != lofty::tag::TagType::Id3v1
                    && (tag.disk() != Some(1) || tag.disk_total() != Some(1)))
        })
    {
        return Err("Written track/disc tags could not be verified".into());
    }
    Ok(())
}

pub fn sequence_filename(name: &str, position: usize, total: usize) -> Result<String, String> {
    let (stem, extension) = name
        .rsplit_once('.')
        .ok_or("Audio filename has no extension")?;
    let extension = extension.to_ascii_lowercase();
    if !AUDIO_EXTENSIONS.contains(&extension.as_str())
        || name.contains(['\n', '\r', '\\', '\0'])
        || name.starts_with('#')
    {
        return Err(format!("Unsupported filename or format: {name}"));
    }
    let mut title = stem;
    if crate::track_order::filename_sequence_number(name).is_some() {
        let lower = title.to_ascii_lowercase();
        let marker = ["disc", "disk", "cd", "d"]
            .into_iter()
            .find(|marker| lower.starts_with(marker));
        if let Some(marker) = marker {
            title = title[marker.len()..].trim_start_matches([' ', '-', '_', '.']);
            title = title
                .trim_start_matches(|c: char| c.is_ascii_digit())
                .trim_start_matches([' ', '-', '_', '.']);
        }
        let lower = title.to_ascii_lowercase();
        if let Some(marker) = ["part", "track", "trk"]
            .into_iter()
            .find(|marker| lower.starts_with(marker))
        {
            title = title[marker.len()..].trim_start_matches([' ', '-', '_', '.', '#']);
        }
        title = title
            .trim_start_matches(|c: char| c.is_ascii_digit())
            .trim_start_matches([' ', '-', '_', '.']);
    }
    let width = total.to_string().len().max(2);
    let title = crate::naming::clean_component(title);
    let filename = if title.is_empty() {
        format!("{position:0width$}.{extension}")
    } else {
        format!("{position:0width$} - {title}.{extension}")
    };
    if filename.len() > 255 {
        return Err("A numbered filename exceeds the filesystem name limit".into());
    }
    Ok(filename)
}

#[cfg(test)]
mod tests {
    use super::*;
    use lofty::tag::{ItemKey, ItemValue, TagItem, TagType};
    use std::{fs, io::Read};

    // Metadata rewrites can otherwise destroy irreplaceable media: assert the
    // original bytes, unrelated fields/artwork and encoded payload survive.
    #[test]
    fn audio_order_preserves_original_payload_and_other_tags() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source.flac");
        let mut bytes = b"fLaC\x80\0\0\x22".to_vec();
        bytes.extend([0u8; 34]);
        bytes.extend(b"encoded-audio-payload-must-survive");
        fs::write(&source, bytes).unwrap();
        let mut tag = Tag::new(TagType::VorbisComments);
        tag.set_title("Keep title".into());
        tag.set_artist("Keep artist".into());
        tag.insert(TagItem::new(
            ItemKey::Lyrics,
            ItemValue::Text("keep".into()),
        ));
        let mut picture = Vec::new();
        use image::ImageEncoder;
        image::codecs::png::PngEncoder::new(&mut picture)
            .write_image(&[1, 2, 3, 255], 1, 1, image::ExtendedColorType::Rgba8)
            .unwrap();
        tag.push_picture(
            lofty::picture::Picture::unchecked(picture.clone())
                .pic_type(lofty::picture::PictureType::CoverFront)
                .mime_type(lofty::picture::MimeType::Png)
                .build(),
        );
        use lofty::tag::TagExt;
        tag.save_to_path(&source, WriteOptions::default()).unwrap();
        let original = fs::read(&source).unwrap();
        let output = temp.path().join("output.flac");
        rewrite_audio_order(
            File::open(&source).unwrap(),
            File::options()
                .create_new(true)
                .read(true)
                .write(true)
                .open(&output)
                .unwrap(),
            "flac",
            2,
            3,
        )
        .unwrap();
        assert_eq!(fs::read(&source).unwrap(), original);
        assert!(fs::read(&output)
            .unwrap()
            .ends_with(b"encoded-audio-payload-must-survive"));
        let tagged = Probe::open(&output)
            .unwrap()
            .options(ParseOptions::new().read_properties(false))
            .read()
            .unwrap();
        let tag = tagged.primary_tag().unwrap();
        assert_eq!(tag.title().as_deref(), Some("Keep title"));
        assert_eq!(tag.artist().as_deref(), Some("Keep artist"));
        assert_eq!(tag.track(), Some(2));
        assert_eq!(tag.track_total(), Some(3));
        assert_eq!(tag.disk(), Some(1));
        assert_eq!(tag.pictures()[0].data(), picture);
        assert_eq!(tag.get_string(ItemKey::Lyrics), Some("keep"));
        let mut audio = File::open(output).unwrap();
        let mut readback = Vec::new();
        audio.read_to_end(&mut readback).unwrap();
        assert!(readback.len() > 34);
    }
}
