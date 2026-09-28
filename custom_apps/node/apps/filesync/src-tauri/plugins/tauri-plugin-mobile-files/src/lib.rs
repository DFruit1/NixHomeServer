use tauri::{
    plugin::{Builder, TauriPlugin},
    Manager, Runtime,
};

pub use models::*;

#[cfg(desktop)]
mod desktop;
#[cfg(mobile)]
mod mobile;

mod commands;
mod error;
mod models;

pub use error::{Error, Result};

#[cfg(desktop)]
use desktop::MobileFiles;
#[cfg(mobile)]
use mobile::MobileFiles;

/// Extensions to [`tauri::App`], [`tauri::AppHandle`] and [`tauri::Window`] to access the mobile-files APIs.
pub trait MobileFilesExt<R: Runtime> {
    fn mobile_files(&self) -> &MobileFiles<R>;
}

impl<R: Runtime, T: Manager<R>> crate::MobileFilesExt<R> for T {
    fn mobile_files(&self) -> &MobileFiles<R> {
        self.state::<MobileFiles<R>>().inner()
    }
}

/// Initializes the plugin.
pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("mobile-files")
        .invoke_handler(tauri::generate_handler![
            commands::pick_local_folder,
            commands::ensure_all_files_access,
            commands::request_all_files_access,
            commands::create_local_folder,
        ])
        .setup(|app, api| {
            #[cfg(mobile)]
            let mobile_files = mobile::init(app, api)?;
            #[cfg(desktop)]
            let mobile_files = desktop::init(app, api)?;
            app.manage(mobile_files);
            Ok(())
        })
        .build()
}
