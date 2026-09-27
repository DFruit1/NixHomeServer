# Tauri resolves this native plugin and its commands by their original names.
# R8 cannot see the Rust -> Java calls in the Android dependency graph.
-keep class org.nixhomeserver.filesync.mobilefiles.MobileFilesPlugin { *; }

# WorkManager constructs workers by class name from its persisted database.
-keep class org.nixhomeserver.filesync.mobilefiles.BackgroundSyncWorker { *; }
