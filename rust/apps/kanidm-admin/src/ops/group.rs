use serde_json::{json, Value};

use crate::{
    inventory::groups::{parse_group_list, parse_group_members, parse_group_record, GroupRecord},
    kanidm_cli::KanidmCli,
    output::CommandOutput,
    AppError,
};

pub fn list_groups(cli: &KanidmCli) -> Result<CommandOutput, AppError> {
    let groups = parse_group_list(&cli.group_list::<Value>()?)?;
    let human = if groups.value.is_empty() {
        "No Kanidm groups found.".to_string()
    } else {
        let mut lines = vec![format!("{:<28} {}", "GROUP", "DESCRIPTION")];
        lines.extend(groups.value.iter().map(|group| {
            format!(
                "{:<28} {}",
                group.name,
                group.description.as_deref().unwrap_or("-")
            )
        }));
        lines.join("\n")
    };

    Ok(CommandOutput {
        message: format!("listed {} Kanidm group(s)", groups.value.len()),
        human,
        details: json!({ "groups": groups.value }),
        warnings: groups.warnings,
    })
}

pub fn search_groups(cli: &KanidmCli, query: &str) -> Result<CommandOutput, AppError> {
    let groups = parse_group_list(&cli.group_list::<Value>()?)?;
    let filtered = groups
        .value
        .iter()
        .filter(|group| group.name.contains(query))
        .cloned()
        .collect::<Vec<_>>();
    let human = if filtered.is_empty() {
        format!("No Kanidm groups matched '{query}'.")
    } else {
        filtered
            .iter()
            .map(|group| {
                format!(
                    "- {}{}",
                    group.name,
                    group
                        .description
                        .as_deref()
                        .map(|description| format!(": {description}"))
                        .unwrap_or_default()
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    };

    Ok(CommandOutput {
        message: format!("searched Kanidm groups for '{query}'"),
        human,
        details: json!({
            "query": query,
            "groups": filtered,
        }),
        warnings: groups.warnings,
    })
}

pub fn show_group(cli: &KanidmCli, group: &str) -> Result<CommandOutput, AppError> {
    let group = load_group(cli, group)?;
    Ok(CommandOutput {
        message: format!("loaded Kanidm group '{}'", group.value.name),
        human: human_group_summary(&group.value),
        details: json!({ "group": group.value }),
        warnings: group.warnings,
    })
}

pub fn group_members(cli: &KanidmCli, group: &str) -> Result<CommandOutput, AppError> {
    let members = parse_group_members(&cli.group_list_members::<Value>(group)?, group)?;
    let human = if members.value.is_empty() {
        format!("Kanidm group '{group}' has no listed members.")
    } else {
        format!(
            "Members of '{}':\n{}",
            group,
            members
                .value
                .iter()
                .map(|member| format!("- {member}"))
                .collect::<Vec<_>>()
                .join("\n")
        )
    };

    Ok(CommandOutput {
        message: format!("loaded members of Kanidm group '{group}'"),
        human,
        details: json!({
            "group": group,
            "members": members.value,
        }),
        warnings: members.warnings,
    })
}

pub fn load_group(
    cli: &KanidmCli,
    group: &str,
) -> Result<crate::inventory::Parsed<GroupRecord>, AppError> {
    parse_group_record(&cli.group_get::<Value>(group)?, group)
}

pub fn human_group_summary(group: &GroupRecord) -> String {
    format!(
        "Group: {}\nDescription: {}\nMember Count: {}\nAuth Expiry Seconds: {}\nPrivilege Expiry Seconds: {}\n\nMembers:\n{}",
        group.name,
        group.description.as_deref().unwrap_or("-"),
        group.members.len(),
        group
            .policy
            .auth_expiry_seconds
            .map(|value| value.to_string())
            .unwrap_or_else(|| "not set".to_string()),
        group
            .policy
            .privilege_expiry_seconds
            .map(|value| value.to_string())
            .unwrap_or_else(|| "not set".to_string()),
        if group.members.is_empty() {
            "(none)".to_string()
        } else {
            group
                .members
                .iter()
                .map(|member| format!("- {member}"))
                .collect::<Vec<_>>()
                .join("\n")
        }
    )
}
