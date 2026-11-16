/**
 * Top-level folders whose name starts with `_` are provisioned and owned by
 * the server or a producer app (for example `_YouTube`, `_Movies`,
 * `_Transcribe`). Their names and metadata are not the user's to edit, and
 * their artwork should not be borrowed from whichever item happens to sort
 * first inside them.
 */
export function serverFolderSymbol(
  relativePath: string,
): "youtube" | "server" | undefined {
  const segments = relativePath.split("/").filter(Boolean);
  // Only the producer's own folder is static; folders beneath it hold media
  // the user may still edit.
  if (segments.length !== 1) return undefined;
  const name = segments[0];
  if (!name.startsWith("_") || name === "_") return undefined;
  return name.toLowerCase() === "_youtube" ? "youtube" : "server";
}
