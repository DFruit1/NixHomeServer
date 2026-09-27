const COMMANDS: &[&str] = &["pick_local_folder"];

fn main() {
    tauri_plugin::Builder::new(COMMANDS)
        .android_path("android")
        .build();
}
