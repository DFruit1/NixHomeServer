import type {
  MetadataHealthIssue,
  MetadataHealthResult,
} from "./api-contract.generated";

/**
 * Libraries are commonly organised as `Author/Title/…` (audiobooks) or
 * `Author/Title.epub` (books). When an item has no author, the folder that
 * holds the title names one, so it is offered as a proposal and narrows
 * provider searches (a title-only search for "Confessions" otherwise ranks
 * unrelated authors). The proposal still goes through Use proposed.
 */
export const FOLDER_AUTHOR_SOURCE = "Folder name";

// Folder names that organise a library rather than name a person.
const NOT_A_PERSON = new Set([
  "anthologies",
  "anthology",
  "audio books",
  "audiobooks",
  "biography",
  "books",
  "children",
  "classics",
  "collection",
  "collections",
  "comics",
  "downloads",
  "ebooks",
  "english",
  "fantasy",
  "favorites",
  "favourites",
  "fiction",
  "history",
  "inbox",
  "kids",
  "library",
  "manga",
  "misc",
  "miscellaneous",
  "music",
  "new",
  "non fiction",
  "nonfiction",
  "other",
  "philosophy",
  "podcasts",
  "poetry",
  "religion",
  "science",
  "series",
  "standalone",
  "unknown",
  "unknown author",
  "unsorted",
  "various",
  "various artists",
]);
// Lower-case particles that belong inside names ("Augustine of Hippo").
const PARTICLES = new Set([
  "al",
  "bin",
  "da",
  "de",
  "del",
  "der",
  "di",
  "du",
  "ibn",
  "la",
  "le",
  "of",
  "van",
  "von",
  "y",
]);

function comparable(value: unknown): string {
  return String(value ?? "")
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

/** A person-like folder name, reordered from "Last, First"; otherwise "". */
export function personName(folder: string): string {
  let name = folder.trim().replace(/\s+/g, " ");
  if (!name || /^[_.]/.test(name) || /\d/.test(name) || name.length > 60)
    return "";
  const parts = name.split(",").map((part) => part.trim());
  if (parts.length > 2 || parts.some((part) => !part)) return "";
  if (parts.length === 2) name = `${parts[1]} ${parts[0]}`;
  if (NOT_A_PERSON.has(comparable(name))) return "";
  const words = name.split(" ");
  if (words.length > 5 || /^(the|a|an)$/i.test(words[0])) return "";
  const valid = words.every(
    (word, index) =>
      (index > 0 && PARTICLES.has(word)) || /^\p{Lu}[\p{L}'’.-]*$/u.test(word),
  );
  return valid ? name : "";
}

/**
 * The author named by an item's folders, or "".
 * Audio is grouped by its folder, so that folder is the title folder; other
 * items use their own parent unless it repeats the title. Above the title,
 * the topmost person-like folder is the author: in
 * `Brandon Sanderson/Mistborn/The Final Empire/` the middle folder is a series.
 */
export function folderAuthorHint(
  result: Pick<
    MetadataHealthResult,
    "relativePath" | "title" | "albumGroup" | "mediaKind"
  >,
): string {
  // Only books and audiobooks are filed by author; podcast creators come
  // from their feed and music uses artists.
  if (result.mediaKind !== "audiobook" && result.mediaKind !== "book")
    return "";
  const folders = result.relativePath.split("/").filter(Boolean).slice(0, -1);
  if (folders.length === 0) return "";
  const fileTitle = (result.relativePath.split("/").at(-1) ?? "").replace(
    /\.[^.]+$/,
    "",
  );
  const titles = [result.title, fileTitle]
    .map(comparable)
    .filter((title) => title);
  const last = comparable(folders.at(-1));
  const titleFolder =
    Boolean(result.albumGroup) ||
    titles.some(
      (title) =>
        title === last ||
        title.startsWith(`${last} `) ||
        last.startsWith(`${title} `),
    );
  const above = titleFolder ? folders.slice(0, -1) : folders;
  const excluded = new Set([...titles, titleFolder ? last : ""]);
  for (const folder of above) {
    if (folder.startsWith("_")) continue;
    const name = personName(folder);
    // A folder that repeats the title (or its folder) names the work.
    if (name && !excluded.has(comparable(name))) return name;
  }
  return "";
}

function unset(value: unknown): boolean {
  if (Array.isArray(value)) return value.every(unset);
  return value == null || String(value).trim() === "";
}

/** Offer the folder's author on an unset author issue that has no proposal. */
export function withFolderAuthorProposal(
  result: MetadataHealthResult,
): MetadataHealthResult {
  const index = result.health.findIndex(
    (issue) =>
      issue.field === "authors" &&
      "currentValue" in issue &&
      unset(issue.currentValue) &&
      !issue.proposedValues?.some((candidate) => !unset(candidate.value)),
  );
  if (index < 0) return result;
  const author = folderAuthorHint(result);
  if (!author) return result;
  const health: MetadataHealthIssue[] = result.health.slice();
  health[index] = {
    ...health[index],
    proposedValues: [{ value: [author], sources: [FOLDER_AUTHOR_SOURCE] }],
  };
  return { ...result, health };
}
