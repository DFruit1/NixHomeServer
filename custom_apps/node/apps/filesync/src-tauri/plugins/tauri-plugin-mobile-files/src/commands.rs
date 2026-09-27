use tauri::{command, AppHandle, Runtime};

use crate::{MobileFilesExt, PickedFolder, Result};

#[command]
pub(crate) async fn pick_local_folder<R: Runtime>(
    app: AppHandle<R>,
) -> Result<Option<PickedFolder>> {
    app.mobile_files().pick_local_folder()
}
