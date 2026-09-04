import { component$ } from "@builder.io/qwik";
import { metadataDuration, metadataFieldLabel } from "./item-editor-helpers";

export const ObservationStructuredDetails = component$<{
  fields: Record<string, unknown>;
}>((props) => {
  const audioFiles = Array.isArray(props.fields.audioFiles)
    ? (props.fields.audioFiles as Array<Record<string, unknown>>)
    : [];
  const chapters = Array.isArray(props.fields.chapters)
    ? (props.fields.chapters as Array<Record<string, unknown>>)
    : [];
  const fieldLocks =
    props.fields.fieldLocks && typeof props.fields.fieldLocks === "object"
      ? Object.entries(props.fields.fieldLocks as Record<string, unknown>)
          .filter(([, locked]) => locked === true)
          .map(([field]) => metadataFieldLabel(field))
      : [];
  const ebook =
    props.fields.ebookFile && typeof props.fields.ebookFile === "object"
      ? (props.fields.ebookFile as Record<string, unknown>)
      : undefined;
  if (
    audioFiles.length === 0 &&
    chapters.length === 0 &&
    fieldLocks.length === 0 &&
    !ebook
  ) {
    return null;
  }
  return (
    <div class="metadata-structured-details">
      {audioFiles.length > 0 && (
        <details>
          <summary>Audio files ({audioFiles.length})</summary>
          <div
            class="metadata-mini-table"
            role="table"
            aria-label="Audio files"
          >
            {audioFiles.slice(0, 50).map((file, index) => (
              <div role="row" key={`${String(file.filename)}-${index}`}>
                <strong>{String(file.filename ?? `File ${index + 1}`)}</strong>
                <span>
                  {[
                    file.discNumber ? `D${String(file.discNumber)}` : "",
                    file.trackNumber ? `T${String(file.trackNumber)}` : "",
                    file.codec ? String(file.codec).toUpperCase() : "",
                    metadataDuration(file.duration),
                  ]
                    .filter(Boolean)
                    .join(" · ")}
                </span>
                {Boolean(file.error) && <em>{String(file.error)}</em>}
              </div>
            ))}
          </div>
        </details>
      )}
      {chapters.length > 0 && (
        <details>
          <summary>Chapters ({chapters.length})</summary>
          <div class="metadata-mini-table" role="table" aria-label="Chapters">
            {chapters.slice(0, 50).map((chapter, index) => (
              <div role="row" key={`${String(chapter.title)}-${index}`}>
                <strong>
                  {String(chapter.title ?? `Chapter ${index + 1}`)}
                </strong>
                <span>
                  {metadataDuration(chapter.start)}–
                  {metadataDuration(chapter.end)}
                </span>
              </div>
            ))}
          </div>
        </details>
      )}
      {ebook && (
        <p class="metadata-embedded-ebook">
          <strong>Companion ebook</strong> {String(ebook.filename ?? "Present")}
        </p>
      )}
      {fieldLocks.length > 0 && (
        <p class="metadata-field-locks">
          <strong>Locked fields</strong> {fieldLocks.join(", ")}
        </p>
      )}
    </div>
  );
});
