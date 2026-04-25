use dialoguer::{theme::ColorfulTheme, Confirm, Input, MultiSelect, Select};

use crate::AppError;

pub fn select(prompt: &str, items: &[String], default: usize) -> Result<usize, AppError> {
    Select::with_theme(&theme())
        .with_prompt(prompt)
        .items(items)
        .default(default)
        .interact()
        .map_err(|error| AppError::Io {
            message: format!("interactive selection failed: {error}"),
        })
}

pub fn multiselect(
    prompt: &str,
    items: &[String],
    defaults: &[bool],
) -> Result<Vec<usize>, AppError> {
    let theme = theme();
    let mut selection = MultiSelect::with_theme(&theme);
    selection = selection.with_prompt(prompt).items(items);
    for (index, selected) in defaults.iter().copied().enumerate() {
        selection = selection.item_checked(index, selected);
    }
    selection.interact().map_err(|error| AppError::Io {
        message: format!("interactive multi-selection failed: {error}"),
    })
}

pub fn input_required(prompt: &str, initial: Option<&str>) -> Result<String, AppError> {
    let theme = theme();
    let mut input = Input::<String>::with_theme(&theme).with_prompt(prompt);
    if let Some(initial) = initial {
        input = input.with_initial_text(initial.to_string());
    }
    input
        .validate_with(|value: &String| {
            if value.trim().is_empty() {
                Err("value is required")
            } else {
                Ok(())
            }
        })
        .interact_text()
        .map(|value| value.trim().to_string())
        .map_err(|error| AppError::Io {
            message: format!("interactive input failed: {error}"),
        })
}

pub fn input_optional(prompt: &str, initial: Option<&str>) -> Result<Option<String>, AppError> {
    let theme = theme();
    let mut input = Input::<String>::with_theme(&theme)
        .with_prompt(prompt)
        .allow_empty(true);
    if let Some(initial) = initial {
        input = input.with_initial_text(initial.to_string());
    }
    input
        .interact_text()
        .map(|value| {
            let trimmed = value.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        })
        .map_err(|error| AppError::Io {
            message: format!("interactive input failed: {error}"),
        })
}

pub fn confirm(prompt: &str, default: bool) -> Result<bool, AppError> {
    Confirm::with_theme(&theme())
        .with_prompt(prompt)
        .default(default)
        .interact()
        .map_err(|error| AppError::Io {
            message: format!("interactive confirmation failed: {error}"),
        })
}

pub fn pause(prompt: &str) -> Result<(), AppError> {
    Input::<String>::with_theme(&theme())
        .with_prompt(prompt)
        .allow_empty(true)
        .interact_text()
        .map(|_| ())
        .map_err(|error| AppError::Io {
            message: format!("interactive pause failed: {error}"),
        })
}

fn theme() -> ColorfulTheme {
    ColorfulTheme::default()
}
