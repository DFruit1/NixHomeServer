use serde_json::Value;

use crate::{
    inventory::{
        clients::{parse_client_list, ClientSummary},
        groups::{is_operator_visible_group, parse_group_list, GroupSummary},
        users::{parse_user_list, UserSummary},
        Parsed,
    },
    kanidm_cli::KanidmCli,
    output::CommandOutput,
    validation::{validate_account_id, validate_identifier_field},
    AppError,
};

use super::{
    forms, menu_item, perform_interactive_read, prompt_optional_submitted, render, render_bullets,
    run_command, run_privileged_command,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum GroupPickerScope {
    OperatorVisibleOnly,
    AllGroups,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct GroupPickerInventory {
    pub(super) intro: &'static str,
    pub(super) no_matching_groups_prompt: &'static str,
    pub(super) manual_prompt: &'static str,
    pub(super) manual_label: &'static str,
    pub(super) manual_detail: &'static str,
    pub(super) groups: Vec<GroupSummary>,
}

pub(super) fn user_target_flow<F>(
    kanidm: &KanidmCli,
    prompt: &str,
    mut action: F,
) -> Result<(), AppError>
where
    F: FnMut(&str) -> Result<CommandOutput, AppError>,
{
    let Some(account_id) = choose_account_id(kanidm, prompt)? else {
        return Ok(());
    };
    run_command("User", kanidm, || action(&account_id))
}

pub(super) fn group_target_flow_with_scope<F>(
    kanidm: &KanidmCli,
    prompt: &str,
    scope: GroupPickerScope,
    mut action: F,
) -> Result<(), AppError>
where
    F: FnMut(&str) -> Result<CommandOutput, AppError>,
{
    let Some(group) = choose_group_name_with_scope(kanidm, prompt, scope)? else {
        return Ok(());
    };
    run_command("Group", kanidm, || action(&group))
}

pub(super) fn client_target_flow<F>(
    kanidm: &KanidmCli,
    prompt: &str,
    mut action: F,
) -> Result<(), AppError>
where
    F: FnMut(&str) -> Result<CommandOutput, AppError>,
{
    let Some(client) = choose_client_name(kanidm, prompt)? else {
        return Ok(());
    };
    run_command("OAuth2 Client", kanidm, || action(&client))
}

pub(super) fn client_target_flow_privileged<F>(
    kanidm: &KanidmCli,
    prompt: &str,
    action: F,
) -> Result<(), AppError>
where
    F: Fn(&str) -> Result<CommandOutput, AppError>,
{
    let Some(client) = choose_client_name(kanidm, prompt)? else {
        return Ok(());
    };
    run_privileged_command("OAuth2 Client", kanidm, || action(&client))
}

pub(super) fn choose_account_id(
    kanidm: &KanidmCli,
    prompt: &str,
) -> Result<Option<String>, AppError> {
    let Some(people) =
        perform_interactive_read(kanidm, || parse_user_list(&kanidm.person_list::<Value>()?))?
    else {
        return Ok(None);
    };
    choose_from_users(prompt, &people)
}

pub(super) fn choose_group_name_with_scope(
    kanidm: &KanidmCli,
    prompt: &str,
    scope: GroupPickerScope,
) -> Result<Option<String>, AppError> {
    let Some(groups) =
        perform_interactive_read(kanidm, || parse_group_list(&kanidm.group_list::<Value>()?))?
    else {
        return Ok(None);
    };
    choose_from_groups(prompt, &groups, scope)
}

pub(super) fn choose_client_name(
    kanidm: &KanidmCli,
    prompt: &str,
) -> Result<Option<String>, AppError> {
    let Some(clients) = perform_interactive_read(kanidm, || {
        parse_client_list(&kanidm.oauth2_list::<Value>()?)
    })?
    else {
        return Ok(None);
    };
    choose_from_clients(prompt, &clients)
}

pub(super) fn choose_from_users(
    prompt: &str,
    people: &Parsed<Vec<UserSummary>>,
) -> Result<Option<String>, AppError> {
    if !people.warnings.is_empty() {
        render::print_note(
            "User Inventory Warning",
            &format!(
                "The listed users may be incomplete because the Kanidm user list contained parse warnings.\n\nWarnings:\n{}",
                render_bullets(&people.warnings)
            ),
        );
    }
    if people.value.is_empty() {
        return prompt_optional_submitted(forms::input_optional_validated(
            "No users were listed. Enter an account id manually",
            None,
            validate_account_id,
        )?);
    }
    let mut items = vec![menu_item(
        "Enter an account id manually",
        "Type an account id directly.",
        "Use manual entry when the user is missing from discovery or you already know the exact account id.",
    )];
    items.extend(people.value.iter().map(|person| {
        menu_item(
            &person.account_id,
            person
                .display_name
                .as_deref()
                .unwrap_or("No display name is set for this user."),
            &format!(
                "Primary email: {}",
                person.primary_email.as_deref().unwrap_or("not set")
            ),
        )
    }));
    let Some(selection) = forms::contextual_select(prompt, None, &items, 0)? else {
        return Ok(None);
    };
    if selection == 0 {
        return prompt_optional_submitted(forms::input_optional_validated(
            "Enter the Kanidm account id to manage",
            None,
            validate_account_id,
        )?);
    }
    Ok(Some(people.value[selection - 1].account_id.clone()))
}

pub(super) fn choose_from_groups(
    prompt: &str,
    groups: &Parsed<Vec<GroupSummary>>,
    scope: GroupPickerScope,
) -> Result<Option<String>, AppError> {
    if !groups.warnings.is_empty() {
        render::print_note(
            "Group Inventory Warning",
            &format!(
                "The listed groups may be incomplete because the Kanidm group list contained parse warnings.\n\nWarnings:\n{}",
                render_bullets(&groups.warnings)
            ),
        );
    }
    if groups.value.is_empty() {
        return prompt_optional_submitted(forms::input_optional_validated(
            "No groups were listed. Enter a group name manually",
            None,
            |value| validate_identifier_field("group name", value),
        )?);
    }
    let picker = build_group_picker_inventory(&groups.value, scope);
    if picker.groups.is_empty() {
        return prompt_optional_submitted(forms::input_optional_validated(
            picker.no_matching_groups_prompt,
            None,
            |value| validate_identifier_field("group name", value),
        )?);
    }
    let Some(selection) = forms::group_picker(
        prompt,
        Some(picker.intro),
        picker.manual_label,
        picker.manual_detail,
        &picker.groups,
    )?
    else {
        return Ok(None);
    };
    if selection == 0 {
        return prompt_optional_submitted(forms::input_optional_validated(
            picker.manual_prompt,
            None,
            |value| validate_identifier_field("group name", value),
        )?);
    }
    Ok(Some(picker.groups[selection - 1].name.clone()))
}

pub(super) fn choose_from_clients(
    prompt: &str,
    clients: &Parsed<Vec<ClientSummary>>,
) -> Result<Option<String>, AppError> {
    if !clients.warnings.is_empty() {
        render::print_note(
            "OAuth2 Client Inventory Warning",
            &format!(
                "The listed oauth2 clients may be incomplete because discovery contained parse warnings.\n\nWarnings:\n{}",
                render_bullets(&clients.warnings)
            ),
        );
    }
    if clients.value.is_empty() {
        return prompt_optional_submitted(forms::input_optional_validated(
            "No oauth2 clients were listed. Enter a client name manually",
            None,
            |value| validate_identifier_field("oauth2 client name", value),
        )?);
    }
    let mut items = vec![menu_item(
        "Enter an oauth2 client name manually",
        "Type a client name directly.",
        "Use manual entry when the client is missing from live discovery or you already know the exact name.",
    )];
    items.extend(clients.value.iter().map(|client| {
        menu_item(
            &client.name,
            client
                .display_name
                .as_deref()
                .unwrap_or("No display name is set for this client."),
            &format!(
                "Landing URL: {}",
                client.landing_url.as_deref().unwrap_or("not set")
            ),
        )
    }));
    let Some(selection) = forms::contextual_select(prompt, None, &items, 0)? else {
        return Ok(None);
    };
    if selection == 0 {
        return prompt_optional_submitted(forms::input_optional_validated(
            "Enter the oauth2 client name to manage",
            None,
            |value| validate_identifier_field("oauth2 client name", value),
        )?);
    }
    Ok(Some(clients.value[selection - 1].name.clone()))
}

pub(super) fn build_group_picker_inventory(
    groups: &[GroupSummary],
    scope: GroupPickerScope,
) -> GroupPickerInventory {
    match scope {
        GroupPickerScope::OperatorVisibleOnly => GroupPickerInventory {
            intro: "Choose from the guided access picker. Internal Kanidm groups are intentionally hidden here so the day-to-day access workflow stays focused on user-facing groups.",
            no_matching_groups_prompt:
                "No non-IDM groups were listed. Enter a group name manually",
            manual_prompt: "Enter the group name to manage",
            manual_label: "Enter a group name manually",
            manual_detail: "Use manual entry when the group is hidden from the guided access picker or you already know the exact group name.",
            groups: groups
                .iter()
                .filter(|group| is_operator_visible_group(&group.name))
                .cloned()
                .collect(),
        },
        GroupPickerScope::AllGroups => GroupPickerInventory {
            intro: "Choose from all live groups, including internal Kanidm groups. This advanced workflow is intended for deeper inspection and configuration work.",
            no_matching_groups_prompt: "No live groups were listed. Enter a group name manually",
            manual_prompt: "Enter the group name to manage",
            manual_label: "Enter a group name manually",
            manual_detail: "Use manual entry when the group is missing from live discovery or you already know the exact group name.",
            groups: groups.to_vec(),
        },
    }
}
