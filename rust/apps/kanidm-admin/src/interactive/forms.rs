use console::{Key, Term};
use dialoguer::{theme::ColorfulTheme, Confirm, Input, MultiSelect, Select};

use crate::{
    inventory::{
        groups::{resolve_group_help, GroupSummary},
    },
    AppError,
};

const MEMBERSHIP_GUIDANCE: &str = "Start most normal people with `users`. Add app-specific `*-users` groups only for the apps they should access. Add `user-files` for personal files access. Add `shared-files-ro` or `shared-files-rw` only when shared storage access is needed. Reserve `*-admin` groups for trusted operators of that app.";

pub fn select(prompt: &str, items: &[String], default: usize) -> Result<Option<usize>, AppError> {
    map_interactive_result(
        Select::with_theme(&theme())
            .with_prompt(prompt)
            .items(items)
            .default(default)
            .interact_opt(),
        "interactive selection failed",
    )
}

pub fn multiselect(
    prompt: &str,
    items: &[String],
    defaults: &[bool],
) -> Result<Option<Vec<usize>>, AppError> {
    map_interactive_result(
        MultiSelect::with_theme(&theme())
            .with_prompt(prompt)
            .items(items)
            .defaults(defaults)
            .interact_opt(),
        "interactive multi-selection failed",
    )
}

pub fn membership_picker(
    prompt: &str,
    groups: &[GroupSummary],
    defaults: &[bool],
) -> Result<Option<Vec<usize>>, AppError> {
    if groups.is_empty() {
        return Ok(Some(Vec::new()));
    }

    let term = Term::stderr();
    if !term.is_term() {
        return Err(AppError::Io {
            message: "interactive membership selection requires a terminal".to_string(),
        });
    }

    let labels = membership_picker_labels(groups);
    let mut checked = defaults.to_vec();
    checked.resize(groups.len(), false);
    let mut cursor = 0usize;

    term.hide_cursor().map_err(|error| AppError::Io {
        message: format!("interactive membership selection failed: {error}"),
    })?;

    let result = membership_picker_loop(&term, prompt, groups, &labels, &mut checked, &mut cursor);

    let _ = term.clear_screen();
    let _ = term.show_cursor();
    result
}

fn membership_picker_loop(
    term: &Term,
    prompt: &str,
    groups: &[GroupSummary],
    labels: &[String],
    checked: &mut [bool],
    cursor: &mut usize,
) -> Result<Option<Vec<usize>>, AppError> {
    loop {
        render_membership_picker(term, prompt, groups, labels, checked, *cursor)?;

        match term.read_key().map_err(|error| AppError::Io {
            message: format!("interactive membership selection failed: {error}"),
        })? {
            Key::ArrowDown | Key::Char('j') => {
                *cursor = (*cursor + 1) % groups.len();
            }
            Key::ArrowUp | Key::Char('k') => {
                *cursor = if *cursor == 0 {
                    groups.len() - 1
                } else {
                    *cursor - 1
                };
            }
            Key::PageDown => {
                let page_size = membership_page_size(term, groups.len());
                *cursor = (*cursor + page_size).min(groups.len() - 1);
            }
            Key::PageUp => {
                let page_size = membership_page_size(term, groups.len());
                *cursor = (*cursor).saturating_sub(page_size);
            }
            Key::Home => *cursor = 0,
            Key::End => *cursor = groups.len() - 1,
            Key::Char(' ') => {
                checked[*cursor] = !checked[*cursor];
            }
            Key::Enter => {
                let selected = checked
                    .iter()
                    .enumerate()
                    .filter_map(|(index, selected)| selected.then_some(index))
                    .collect::<Vec<_>>();
                return Ok(Some(selected));
            }
            Key::Escape | Key::Char('q') => return Ok(None),
            _ => {}
        }
    }
}

fn render_membership_picker(
    term: &Term,
    prompt: &str,
    groups: &[GroupSummary],
    labels: &[String],
    checked: &[bool],
    cursor: usize,
) -> Result<(), AppError> {
    let page_size = membership_page_size(term, groups.len());
    let current_page = cursor / page_size;
    let total_pages = groups.len().div_ceil(page_size);
    let start = current_page * page_size;
    let end = (start + page_size).min(groups.len());
    let help = resolve_group_help(&groups[cursor].name, groups[cursor].description.as_deref());

    let mut body = String::new();
    body.push_str(&format!("{prompt}  [Page {}/{}]\n", current_page + 1, total_pages));
    body.push_str("Keys: Space toggle | Enter save | Esc back\n\n");
    body.push_str("Guidance:\n");
    body.push_str(MEMBERSHIP_GUIDANCE);
    body.push_str("\n\n");

    for index in start..end {
        let marker = if checked[index] { "[x]" } else { "[ ]" };
        let pointer = if index == cursor { ">" } else { " " };
        body.push_str(&format!("{pointer} {marker} {}\n", labels[index]));
    }

    body.push_str("\nSelected group help:\n");
    body.push_str(&help.summary);
    body.push('\n');
    body.push_str(&help.detail);
    body.push('\n');

    term.clear_screen().map_err(|error| AppError::Io {
        message: format!("interactive membership selection failed: {error}"),
    })?;
    term.write_str(&body).map_err(|error| AppError::Io {
        message: format!("interactive membership selection failed: {error}"),
    })?;
    term.flush().map_err(|error| AppError::Io {
        message: format!("interactive membership selection failed: {error}"),
    })?;
    Ok(())
}

fn membership_page_size(term: &Term, total_groups: usize) -> usize {
    let (rows, _) = term.size();
    let available = usize::from(rows).saturating_sub(11).max(5);
    available.min(total_groups.max(1))
}

fn membership_picker_labels(groups: &[GroupSummary]) -> Vec<String> {
    groups.iter().map(|group| group.name.clone()).collect()
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

pub fn confirm(prompt: &str, default: bool) -> Result<Option<bool>, AppError> {
    map_interactive_result(
        Confirm::with_theme(&theme())
            .with_prompt(prompt)
            .default(default)
            .interact_opt(),
        "interactive confirmation failed",
    )
}

pub fn pause(prompt: &str) -> Result<(), AppError> {
    let term = Term::stderr();
    term.write_str(&format!("{prompt}\n")).map_err(|error| AppError::Io {
        message: format!("interactive pause failed: {error}"),
    })?;
    term.flush().map_err(|error| AppError::Io {
        message: format!("interactive pause failed: {error}"),
    })?;
    loop {
        match term.read_key().map_err(|error| AppError::Io {
            message: format!("interactive pause failed: {error}"),
        })? {
            Key::Enter | Key::Escape => break,
            _ => {}
        }
    }
    Ok(())
}

fn map_interactive_result<T>(
    result: Result<Option<T>, dialoguer::Error>,
    context: &str,
) -> Result<Option<T>, AppError> {
    result.map_err(|error| AppError::Io {
        message: format!("{context}: {error}"),
    })
}

fn theme() -> ColorfulTheme {
    ColorfulTheme::default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn map_interactive_result_preserves_cancel() {
        let result = map_interactive_result::<usize>(Ok(None), "selection failed").expect("ok");
        assert_eq!(result, None);
    }

    #[test]
    fn membership_picker_uses_group_names_as_labels() {
        let labels = membership_picker_labels(&[
            GroupSummary {
                name: "users".to_string(),
                description: None,
            },
            GroupSummary {
                name: "immich-users".to_string(),
                description: None,
            },
        ]);

        assert_eq!(labels, vec!["users".to_string(), "immich-users".to_string()]);
        assert!(labels.iter().all(|label| !label.chars().all(|ch| ch.is_ascii_digit())));
    }
}
