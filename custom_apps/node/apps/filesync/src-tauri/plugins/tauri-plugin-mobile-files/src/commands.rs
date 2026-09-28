use tauri::{command, AppHandle, Runtime};

use crate::{MobileFilesExt, PickedFolder, Result};

#[command]
pub(crate) async fn pick_local_folder<R: Runtime>(
    app: AppHandle<R>,
) -> Result<Option<PickedFolder>> {
    app.mobile_files().pick_local_folder()
}

#[command]
pub(crate) fn ensure_all_files_access<R: Runtime>(app: AppHandle<R>) -> Result<bool> {
    app.mobile_files().ensure_all_files_access()
}

#[command]
pub(crate) fn request_all_files_access<R: Runtime>(app: AppHandle<R>) -> Result<bool> {
    app.mobile_files().request_all_files_access()
}

#[command]
pub(crate) fn create_local_folder<R: Runtime>(
    app: AppHandle<R>,
    subpath: String,
) -> Result<PickedFolder> {
    app.mobile_files().create_local_folder(subpath)
}
