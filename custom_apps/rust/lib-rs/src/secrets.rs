use std::path::Path;

pub fn read_secret_file(path: &Path) -> Result<String, String> {
    let contents = std::fs::read_to_string(path)
        .map_err(|error| format!("failed to read secret file {}: {error}", path.display()))?;
    let trimmed = contents.trim();
    if trimmed.is_empty() {
        return Err(format!("secret file {} must not be empty", path.display()));
    }
    Ok(trimmed.to_string())
}
