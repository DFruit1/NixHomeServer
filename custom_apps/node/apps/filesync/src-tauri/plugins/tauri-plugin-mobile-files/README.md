# Tauri platform file adapter

This plugin keeps file access and secret storage behind a native Rust/Kotlin
boundary. Android folder access uses a persistable Storage Access Framework
tree grant. File copies are streamed through one private cache file at a time;
the plugin never exposes SAF file contents to the webview. Linux uses the
native folder dialog, filesystem paths, and the desktop keyring.

The Rust application records the selected root in secure storage and checks it
before sync commands use a path from the webview. Android releases the SAF
grant when the last pair for that folder is removed.

Secrets are available only to the Rust side of the Tauri app. Android encrypts
them with an AES-GCM key held by Android Keystore; Linux delegates storage to
the system keyring.
