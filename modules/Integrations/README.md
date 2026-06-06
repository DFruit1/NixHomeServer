Place optional cross-service integration modules in this directory.

Integration modules describe relationships between otherwise independent app
modules. Keep each file narrowly scoped to one cross-service relationship, and
name it after the purpose of that relationship, even when the name is verbose.

App modules must not reference sibling app internals directly. If a feature
needs paths, units, groups, or options from two optional apps, put that binding
here and import it explicitly from `configuration.nix`.

Examples:

- `send_mail_archive_documents_to_paperless.nix`
- `grant_files_access_to_kiwix_library.nix`
- `wait_for_jellyfin_storage_before_youtube_downloader.nix`

Import integration modules by their explicit filename from `configuration.nix`.
Do not add an `Integrations/default.nix` aggregator.
