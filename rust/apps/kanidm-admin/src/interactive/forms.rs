use console::{Key, Term};
use dialoguer::{theme::ColorfulTheme, Confirm, Input, MultiSelect, Select};

use crate::{
    inventory::groups::{resolve_group_help, GroupSummary},
    AppError,
};

const MEMBERSHIP_GUIDANCE: &str = "Start most normal people with `users`. Add app-specific `*-users` groups only for the apps they should access. Add `user-files` for personal files access. Add `shared-files-ro` or `shared-files-rw` only when shared storage access is needed. Reserve `*-admin` groups for trusted operators of that app.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextualItem {
    pub label: String,
    pub summary: String,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FilteredView {
    indices: Vec<usize>,
}

#[derive(Clone, Copy)]
struct MembershipPickerView<'a> {
    term: &'a Term,
    prompt: &'a str,
    groups: &'a [GroupSummary],
    labels: &'a [String],
    checked: &'a [bool],
    cursor: usize,
    current_groups: &'a [String],
    visible: &'a FilteredView,
    filter: Option<&'a str>,
}

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
    current_groups: &[String],
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

    let result = membership_picker_loop(
        &term,
        prompt,
        groups,
        &labels,
        &mut checked,
        &mut cursor,
        current_groups,
    );

    let _ = term.clear_screen();
    let _ = term.show_cursor();
    result
}

pub fn group_picker(
    prompt: &str,
    intro: Option<&str>,
    manual_label: &str,
    manual_detail: &str,
    groups: &[GroupSummary],
) -> Result<Option<usize>, AppError> {
    let mut items = vec![ContextualItem {
        label: manual_label.to_string(),
        summary: "Enter a group name manually.".to_string(),
        detail: manual_detail.to_string(),
    }];
    items.extend(groups.iter().map(|group| {
        let help = resolve_group_help(&group.name, group.description.as_deref());
        ContextualItem {
            label: group.name.clone(),
            summary: help.summary,
            detail: help.detail,
        }
    }));
    contextual_select(prompt, intro, &items, 0)
}

pub fn contextual_select(
    prompt: &str,
    intro: Option<&str>,
    items: &[ContextualItem],
    default: usize,
) -> Result<Option<usize>, AppError> {
    if items.is_empty() {
        return Ok(None);
    }

    let term = Term::stderr();
    if !term.is_term() {
        let labels = items
            .iter()
            .map(|item| item.label.clone())
            .collect::<Vec<_>>();
        return select(prompt, &labels, default);
    }

    let mut cursor = default.min(items.len().saturating_sub(1));
    term.hide_cursor().map_err(|error| AppError::Io {
        message: format!("interactive selection failed: {error}"),
    })?;

    let result = contextual_select_loop(&term, prompt, intro, items, &mut cursor);

    let _ = term.clear_screen();
    let _ = term.show_cursor();
    result
}

fn contextual_select_loop(
    term: &Term,
    prompt: &str,
    intro: Option<&str>,
    items: &[ContextualItem],
    cursor: &mut usize,
) -> Result<Option<usize>, AppError> {
    let mut filter = None;

    loop {
        let visible = contextual_filtered_view(items, filter.as_deref());
        clamp_cursor(cursor, visible.indices.len());
        render_contextual_select(
            term,
            prompt,
            intro,
            items,
            *cursor,
            &visible,
            filter.as_deref(),
        )?;

        match term.read_key().map_err(|error| AppError::Io {
            message: format!("interactive selection failed: {error}"),
        })? {
            Key::ArrowDown | Key::Char('j') if !visible.indices.is_empty() => {
                *cursor = (*cursor + 1) % visible.indices.len();
            }
            Key::ArrowUp | Key::Char('k') if !visible.indices.is_empty() => {
                *cursor = if *cursor == 0 {
                    visible.indices.len() - 1
                } else {
                    *cursor - 1
                };
            }
            Key::PageDown if !visible.indices.is_empty() => {
                let page_size = contextual_page_size(term, visible.indices.len());
                *cursor = (*cursor + page_size).min(visible.indices.len() - 1);
            }
            Key::PageUp if !visible.indices.is_empty() => {
                let page_size = contextual_page_size(term, visible.indices.len());
                *cursor = (*cursor).saturating_sub(page_size);
            }
            Key::Home => *cursor = 0,
            Key::End if !visible.indices.is_empty() => *cursor = visible.indices.len() - 1,
            Key::Char('/') => {
                filter = prompt_filter(term, filter.as_deref())?;
                *cursor = 0;
            }
            Key::Enter => {
                if let Some(selection) = selected_original_index(&visible, *cursor) {
                    return Ok(Some(selection));
                }
            }
            Key::Escape | Key::Char('q') => return Ok(None),
            _ => {}
        }
    }
}

fn membership_picker_loop(
    term: &Term,
    prompt: &str,
    groups: &[GroupSummary],
    labels: &[String],
    checked: &mut [bool],
    cursor: &mut usize,
    current_groups: &[String],
) -> Result<Option<Vec<usize>>, AppError> {
    let mut filter = None;

    loop {
        let visible = membership_filtered_view(groups, filter.as_deref());
        clamp_cursor(cursor, visible.indices.len());
        render_membership_picker(MembershipPickerView {
            term,
            prompt,
            groups,
            labels,
            checked,
            cursor: *cursor,
            current_groups,
            visible: &visible,
            filter: filter.as_deref(),
        })?;

        match term.read_key().map_err(|error| AppError::Io {
            message: format!("interactive membership selection failed: {error}"),
        })? {
            Key::ArrowDown | Key::Char('j') if !visible.indices.is_empty() => {
                *cursor = (*cursor + 1) % visible.indices.len();
            }
            Key::ArrowUp | Key::Char('k') if !visible.indices.is_empty() => {
                *cursor = if *cursor == 0 {
                    visible.indices.len() - 1
                } else {
                    *cursor - 1
                };
            }
            Key::PageDown if !visible.indices.is_empty() => {
                let page_size = membership_page_size(term, visible.indices.len());
                *cursor = (*cursor + page_size).min(visible.indices.len() - 1);
            }
            Key::PageUp if !visible.indices.is_empty() => {
                let page_size = membership_page_size(term, visible.indices.len());
                *cursor = (*cursor).saturating_sub(page_size);
            }
            Key::Home => *cursor = 0,
            Key::End if !visible.indices.is_empty() => *cursor = visible.indices.len() - 1,
            Key::Char(' ') => {
                if let Some(selection) = selected_original_index(&visible, *cursor) {
                    checked[selection] = !checked[selection];
                }
            }
            Key::Char('/') => {
                filter = prompt_filter(term, filter.as_deref())?;
                *cursor = 0;
            }
            Key::Enter if !visible.indices.is_empty() => {
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

fn render_membership_picker(view: MembershipPickerView<'_>) -> Result<(), AppError> {
    let body = build_membership_picker_body(view);
    render_screen(view.term, &body, "interactive membership selection failed")
}

fn render_contextual_select(
    term: &Term,
    prompt: &str,
    intro: Option<&str>,
    items: &[ContextualItem],
    cursor: usize,
    visible: &FilteredView,
    filter: Option<&str>,
) -> Result<(), AppError> {
    let body = build_contextual_select_body(term, prompt, intro, items, cursor, visible, filter);
    render_screen(term, &body, "interactive selection failed")
}

fn build_membership_picker_body(view: MembershipPickerView<'_>) -> String {
    let page_size = membership_page_size(view.term, view.visible.indices.len());
    let current_page = view.cursor / page_size;
    let total_pages = view.visible.indices.len().max(1).div_ceil(page_size);
    let start = current_page * page_size;
    let end = (start + page_size).min(view.visible.indices.len());

    let mut body = String::new();
    body.push_str(&format!(
        "{}  [Page {}/{}]\n",
        view.prompt,
        current_page + 1,
        total_pages
    ));
    body.push_str("Keys: Space toggle | Enter review | / filter | Esc back\n");
    if let Some(filter) = view.filter {
        body.push_str(&format!("Filter: {filter}\n"));
    }
    body.push('\n');
    body.push_str("Guidance:\n");
    body.push_str(MEMBERSHIP_GUIDANCE);
    body.push_str("\n\n");
    body.push_str("Current direct groups:\n");
    body.push_str(&render_selected_groups(view.current_groups));
    body.push_str("\n\n");

    if view.visible.indices.is_empty() {
        body.push_str("No matches for current filter.\n");
        return body;
    }

    for visible_index in start..end {
        let original_index = view.visible.indices[visible_index];
        let marker = if view.checked[original_index] {
            "[x]"
        } else {
            "[ ]"
        };
        let pointer = if visible_index == view.cursor {
            ">"
        } else {
            " "
        };
        body.push_str(&format!(
            "{pointer} {marker} {}\n",
            view.labels[original_index]
        ));
    }

    let selected = view.visible.indices[view.cursor];
    let help = resolve_group_help(
        &view.groups[selected].name,
        view.groups[selected].description.as_deref(),
    );
    body.push_str("\nSelected group help:\n");
    body.push_str(&help.summary);
    body.push('\n');
    body.push_str(&help.detail);
    body.push('\n');

    body
}

fn build_contextual_select_body(
    term: &Term,
    prompt: &str,
    intro: Option<&str>,
    items: &[ContextualItem],
    cursor: usize,
    visible: &FilteredView,
    filter: Option<&str>,
) -> String {
    let page_size = contextual_page_size(term, visible.indices.len());
    let current_page = cursor / page_size;
    let total_pages = visible.indices.len().max(1).div_ceil(page_size);
    let start = current_page * page_size;
    let end = (start + page_size).min(visible.indices.len());

    let mut body = String::new();
    body.push_str(&format!(
        "{prompt}  [Page {}/{}]\n",
        current_page + 1,
        total_pages
    ));
    body.push_str("Keys: Enter select | / filter | Esc back\n");
    if let Some(filter) = filter {
        body.push_str(&format!("Filter: {filter}\n"));
    }
    body.push('\n');
    if let Some(intro) = intro {
        body.push_str(intro);
        body.push_str("\n\n");
    }

    if visible.indices.is_empty() {
        body.push_str("No matches for current filter.\n");
        return body;
    }

    for visible_index in start..end {
        let original_index = visible.indices[visible_index];
        let pointer = if visible_index == cursor { ">" } else { " " };
        body.push_str(&format!("{pointer} {}\n", items[original_index].label));
    }

    let selected = visible.indices[cursor];
    body.push_str("\nSelected help:\n");
    body.push_str(&items[selected].summary);
    body.push('\n');
    body.push_str(&items[selected].detail);
    body.push('\n');

    body
}

fn membership_page_size(term: &Term, total_groups: usize) -> usize {
    let (rows, _) = term.size();
    let available = usize::from(rows).saturating_sub(14).max(5);
    available.min(total_groups.max(1))
}

fn contextual_page_size(term: &Term, total_items: usize) -> usize {
    let (rows, _) = term.size();
    let available = usize::from(rows).saturating_sub(7).max(5);
    available.min(total_items.max(1))
}

fn membership_picker_labels(groups: &[GroupSummary]) -> Vec<String> {
    groups.iter().map(|group| group.name.clone()).collect()
}

fn render_selected_groups(groups: &[String]) -> String {
    if groups.is_empty() {
        "(none)".to_string()
    } else {
        groups
            .iter()
            .map(|group| format!("- {group}"))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn prompt_filter(term: &Term, current: Option<&str>) -> Result<Option<String>, AppError> {
    let _ = term.show_cursor();
    let result = input_optional("Filter", current);
    let _ = term.hide_cursor();
    result
}

fn contextual_filtered_view(items: &[ContextualItem], filter: Option<&str>) -> FilteredView {
    FilteredView {
        indices: match filter {
            Some(query) => items
                .iter()
                .enumerate()
                .filter_map(|(index, item)| {
                    filter_matches(
                        query,
                        [
                            item.label.as_str(),
                            item.summary.as_str(),
                            item.detail.as_str(),
                        ],
                    )
                    .then_some(index)
                })
                .collect(),
            None => (0..items.len()).collect(),
        },
    }
}

fn membership_filtered_view(groups: &[GroupSummary], filter: Option<&str>) -> FilteredView {
    FilteredView {
        indices: match filter {
            Some(query) => groups
                .iter()
                .enumerate()
                .filter_map(|(index, group)| {
                    let help = resolve_group_help(&group.name, group.description.as_deref());
                    let description = group.description.as_deref().unwrap_or("");
                    filter_matches(
                        query,
                        [
                            group.name.as_str(),
                            description,
                            help.summary.as_str(),
                            help.detail.as_str(),
                        ],
                    )
                    .then_some(index)
                })
                .collect(),
            None => (0..groups.len()).collect(),
        },
    }
}

fn filter_matches<'a>(query: &str, fields: impl IntoIterator<Item = &'a str>) -> bool {
    let normalized_query = query.to_lowercase();
    fields
        .into_iter()
        .any(|field| field.to_lowercase().contains(&normalized_query))
}

fn clamp_cursor(cursor: &mut usize, visible_len: usize) {
    if visible_len == 0 {
        *cursor = 0;
    } else {
        *cursor = (*cursor).min(visible_len - 1);
    }
}

fn selected_original_index(visible: &FilteredView, cursor: usize) -> Option<usize> {
    visible.indices.get(cursor).copied()
}

fn render_screen(term: &Term, body: &str, context: &str) -> Result<(), AppError> {
    term.clear_screen().map_err(|error| AppError::Io {
        message: format!("{context}: {error}"),
    })?;
    term.write_str(body).map_err(|error| AppError::Io {
        message: format!("{context}: {error}"),
    })?;
    term.flush().map_err(|error| AppError::Io {
        message: format!("{context}: {error}"),
    })?;
    Ok(())
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

pub fn input_required_validated<F>(
    prompt: &str,
    initial: Option<&str>,
    validator: F,
) -> Result<String, AppError>
where
    F: Fn(&str) -> Result<String, AppError>,
{
    let theme = theme();
    let mut input = Input::<String>::with_theme(&theme).with_prompt(prompt);
    if let Some(initial) = initial {
        input = input.with_initial_text(initial.to_string());
    }
    let validator_ref = &validator;
    input
        .validate_with(|value: &String| {
            validator_ref(value)
                .map(|_| ())
                .map_err(|error| error.human_message())
        })
        .interact_text()
        .map_err(|error| AppError::Io {
            message: format!("interactive input failed: {error}"),
        })
        .and_then(|value| validator(&value))
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

pub fn input_optional_validated<F>(
    prompt: &str,
    initial: Option<&str>,
    validator: F,
) -> Result<Option<String>, AppError>
where
    F: Fn(&str) -> Result<String, AppError>,
{
    let theme = theme();
    let mut input = Input::<String>::with_theme(&theme)
        .with_prompt(prompt)
        .allow_empty(true);
    if let Some(initial) = initial {
        input = input.with_initial_text(initial.to_string());
    }
    let validator_ref = &validator;
    input
        .validate_with(|value: &String| {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                Ok(())
            } else {
                validator_ref(value)
                    .map(|_| ())
                    .map_err(|error| error.human_message())
            }
        })
        .interact_text()
        .map_err(|error| AppError::Io {
            message: format!("interactive input failed: {error}"),
        })
        .and_then(|value| {
            if value.trim().is_empty() {
                Ok(None)
            } else {
                validator(&value).map(Some)
            }
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
    term.write_str(&format!("{prompt}\n"))
        .map_err(|error| AppError::Io {
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

    fn test_term() -> Term {
        Term::buffered_stderr()
    }

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

        assert_eq!(
            labels,
            vec!["users".to_string(), "immich-users".to_string()]
        );
        assert!(labels
            .iter()
            .all(|label| !label.chars().all(|ch| ch.is_ascii_digit())));
    }

    #[test]
    fn group_picker_manual_entry_is_first_item() {
        let groups = vec![GroupSummary {
            name: "users".to_string(),
            description: None,
        }];

        let labels = membership_picker_labels(&groups);

        assert_eq!(labels[0], "users");
    }

    #[test]
    fn filter_matches_case_insensitively() {
        assert!(filter_matches("StoRage", ["Personal storage access"]));
        assert!(!filter_matches("admin", ["Personal storage access"]));
    }

    #[test]
    fn contextual_filter_matches_label() {
        let items = vec![
            ContextualItem {
                label: "Create User".to_string(),
                summary: "Create".to_string(),
                detail: "Create a user".to_string(),
            },
            ContextualItem {
                label: "Delete User".to_string(),
                summary: "Delete".to_string(),
                detail: "Delete a user".to_string(),
            },
        ];

        let visible = contextual_filtered_view(&items, Some("delete"));
        assert_eq!(visible.indices, vec![1]);
    }

    #[test]
    fn contextual_filter_matches_summary_and_detail() {
        let items = vec![
            ContextualItem {
                label: "One".to_string(),
                summary: "Paperless access".to_string(),
                detail: "Grants document access".to_string(),
            },
            ContextualItem {
                label: "Two".to_string(),
                summary: "Immich access".to_string(),
                detail: "Grants photo access".to_string(),
            },
        ];

        assert_eq!(
            contextual_filtered_view(&items, Some("document")).indices,
            vec![0]
        );
        assert_eq!(
            contextual_filtered_view(&items, Some("PHOTO")).indices,
            vec![1]
        );
    }

    #[test]
    fn membership_filter_matches_name_description_and_help() {
        let groups = vec![
            GroupSummary {
                name: "users".to_string(),
                description: Some("Standard access".to_string()),
            },
            GroupSummary {
                name: "paperless-users".to_string(),
                description: Some("Document archive access".to_string()),
            },
        ];

        assert_eq!(
            membership_filtered_view(&groups, Some("paperless")).indices,
            vec![1]
        );
        assert_eq!(
            membership_filtered_view(&groups, Some("document")).indices,
            vec![1]
        );
        assert_eq!(
            membership_filtered_view(&groups, Some("baseline")).indices,
            vec![0]
        );
    }

    #[test]
    fn filtered_selection_returns_original_index() {
        let items = vec![
            ContextualItem {
                label: "One".to_string(),
                summary: "Alpha".to_string(),
                detail: "First".to_string(),
            },
            ContextualItem {
                label: "Two".to_string(),
                summary: "Beta".to_string(),
                detail: "Second".to_string(),
            },
        ];

        let visible = contextual_filtered_view(&items, Some("second"));
        assert_eq!(selected_original_index(&visible, 0), Some(1));
    }

    #[test]
    fn zero_match_contextual_state_renders_safely() {
        let term = test_term();
        let items = vec![ContextualItem {
            label: "One".to_string(),
            summary: "Alpha".to_string(),
            detail: "First".to_string(),
        }];
        let visible = contextual_filtered_view(&items, Some("missing"));
        let body = build_contextual_select_body(
            &term,
            "Prompt",
            Some("Intro"),
            &items,
            0,
            &visible,
            Some("missing"),
        );

        assert!(body.contains("No matches for current filter."));
        assert!(body.contains("Filter: missing"));
    }

    #[test]
    fn zero_match_membership_state_renders_safely() {
        let term = test_term();
        let groups = vec![GroupSummary {
            name: "users".to_string(),
            description: None,
        }];
        let labels = membership_picker_labels(&groups);
        let visible = membership_filtered_view(&groups, Some("missing"));
        let body = build_membership_picker_body(MembershipPickerView {
            term: &term,
            prompt: "Prompt",
            groups: &groups,
            labels: &labels,
            checked: &[false],
            cursor: 0,
            current_groups: &[],
            visible: &visible,
            filter: Some("missing"),
        });

        assert!(body.contains("No matches for current filter."));
        assert!(body.contains("Filter: missing"));
    }
}
