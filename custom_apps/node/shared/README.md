# node-shared

Framework-free Node server plumbing shared by the Qwik apps under
`custom_apps/node/apps/*` (homepage, groundwater-logger, youtube-downloader).

Each app copies this directory into its own tree at
`src/shared/node-common/` before typecheck, tests, and builds:

- Nix derivations do the copy in `postPatch` (see each app's `default.nix`).
- Local dev/CI does it through the `sync-shared` npm script, wired into the
  `pre*` hooks in each app's `package.json`.

`src/shared/node-common/` is git-ignored in the apps; edit the files here.
Import from server code as `../shared/node-common/<module>.js`.
