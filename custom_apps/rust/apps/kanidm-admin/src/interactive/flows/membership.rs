use super::super::*;

pub(in crate::interactive) fn edit_membership_flow(
    context: &ResolvedContext,
    kanidm: &KanidmCli,
) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(
        kanidm,
        "Select a user to authoritatively set direct memberships for",
    )?
    else {
        return Ok(());
    };
    edit_membership_for_account(context, kanidm, &account_id)
}

pub(in crate::interactive) fn edit_membership_for_account(
    context: &ResolvedContext,
    kanidm: &KanidmCli,
    account_id: &str,
) -> Result<(), AppError> {
    let Some(inventory) =
        perform_interactive_read(kanidm, || prepare_membership_picker_inventory(kanidm))?
    else {
        return Ok(());
    };
    if !inventory.warnings.is_empty() {
        render::print_note(
            "Membership Inventory Incomplete",
            &format!(
                "Authoritative membership editing is blocked because the live discovery set is incomplete.\n\nWarnings:\n{}",
                render_bullets(&inventory.warnings)
            ),
        );
        return forms::pause("Press Enter or Esc to continue");
    }
    if inventory.groups.is_empty() {
        render::print_note(
            "Membership Inventory Incomplete",
            "Authoritative membership editing is blocked because the live group picker returned no visible groups. Use read-only inspection or fix Kanidm group discovery first.",
        );
        return forms::pause("Press Enter or Esc to continue");
    }

    let Some(current) = require_complete_user_for_action(
        kanidm,
        account_id,
        "authoritatively set memberships for",
    )?
    else {
        return Ok(());
    };
    let current_groups = current.value.groups.clone();
    let missing_groups = missing_visible_membership_inventory(&current_groups, &inventory.groups);
    if !missing_groups.is_empty() {
        render::print_note(
            "Membership Inventory Incomplete",
            &format!(
                "Authoritative membership editing is blocked because the live group picker is missing the user's current visible access groups.\n\nMissing Groups:\n{}\n\nCurrent Direct Groups:\n{}",
                render_bullets(&missing_groups),
                render_group_block(&current_groups),
            ),
        );
        return forms::pause("Press Enter or Esc to continue");
    }

    let defaults = current_groups
        .iter()
        .map(|current_group| current_group.to_string())
        .collect::<Vec<_>>();
    let mut item_defaults = inventory
        .groups
        .iter()
        .map(|group| defaults.iter().any(|current| current == &group.name))
        .collect::<Vec<_>>();
    let preserve_groups = preserved_hidden_memberships(&current_groups).collect::<Vec<_>>();

    loop {
        let Some(selected) = forms::membership_picker(
            &format!("Set access groups for '{account_id}'"),
            &inventory.groups,
            &item_defaults,
            &current_groups,
        )?
        else {
            return Ok(());
        };
        let groups = selected
            .into_iter()
            .map(|index| inventory.groups[index].name.clone())
            .collect::<Vec<_>>();
        let review =
            build_membership_review(account_id, &current_groups, groups, preserve_groups.clone());

        if review.diff.is_empty() {
            render::print_note(
                "Review Membership Changes",
                "No membership changes would be applied.",
            );
            return forms::pause("Press Enter or Esc to continue");
        }

        render::print_note("Review Membership Changes", &review.render());
        match forms::confirm("Apply these membership changes now?", false)? {
            Some(true) => {
                return run_privileged_command("Memberships", kanidm, || {
                    set_membership_with_config(
                        kanidm,
                        &context.sftp_runtime,
                        SetMembershipOptions {
                            account_id: account_id.to_string(),
                            groups: review.selected_visible_groups.clone(),
                            preserve_groups: review.preserved_hidden_groups.clone(),
                            allow_empty: true,
                        },
                    )
                });
            }
            _ => {
                item_defaults = inventory
                    .groups
                    .iter()
                    .map(|group| {
                        review
                            .selected_visible_groups
                            .iter()
                            .any(|selected| selected == &group.name)
                    })
                    .collect::<Vec<_>>();
            }
        }
    }
}

pub(in crate::interactive) fn membership_change_flow(
    context: &ResolvedContext,
    kanidm: &KanidmCli,
    mode: MembershipChange,
) -> Result<(), AppError> {
    let Some(account_id) = choose_account_id(kanidm, "Select a user")? else {
        return Ok(());
    };
    let Some(current) = require_complete_user_for_action(
        kanidm,
        &account_id,
        if matches!(mode, MembershipChange::Add) {
            "add memberships for"
        } else {
            "remove memberships for"
        },
    )?
    else {
        return Ok(());
    };
    let Some(inventory) =
        perform_interactive_read(kanidm, || prepare_membership_picker_inventory(kanidm))?
    else {
        return Ok(());
    };
    if !inventory.warnings.is_empty() {
        return block_incomplete_inventory(
            "Membership Inventory Incomplete",
            "Incremental membership changes are blocked because the live discovery set is incomplete.",
            &inventory.warnings,
        );
    }
    if inventory.groups.is_empty() {
        render::print_note(
            "Membership Inventory Incomplete",
            "Incremental membership changes are blocked because the live group picker returned no visible groups. Use read-only inspection or fix Kanidm group discovery first.",
        );
        return forms::pause("Press Enter or Esc to continue");
    }

    let Some(groups) = choose_membership_change_groups(
        kanidm,
        &account_id,
        &current.value,
        &inventory.groups,
        mode,
    )?
    else {
        return Ok(());
    };
    let review = build_membership_change_review(&account_id, &current.value.groups, groups, mode);
    if review.is_noop() {
        render::print_note(
            "Review Membership Changes",
            "No membership changes would be applied.",
        );
        return forms::pause("Press Enter or Esc to continue");
    }
    render::print_note("Review Membership Changes", &review.render());
    let prompt = if matches!(mode, MembershipChange::Add) {
        "Add these groups now?"
    } else {
        "Remove these groups now?"
    };
    match forms::confirm(prompt, false)? {
        Some(true) => {}
        _ => return Ok(()),
    }
    match mode {
        MembershipChange::Add => run_privileged_command("Memberships", kanidm, || {
            add_membership_with_config(
                kanidm,
                &context.sftp_runtime,
                &account_id,
                &review.groups_to_add,
            )
        }),
        MembershipChange::Remove => run_privileged_command("Memberships", kanidm, || {
            remove_membership_with_config(
                kanidm,
                &context.sftp_runtime,
                &account_id,
                &review.groups_to_remove,
            )
        }),
    }
}

pub(in crate::interactive) fn choose_membership_change_groups(
    _kanidm: &KanidmCli,
    account_id: &str,
    user: &UserRecord,
    groups: &[GroupSummary],
    mode: MembershipChange,
) -> Result<Option<Vec<String>>, AppError> {
    let guided_picker = build_group_picker_inventory(groups, GroupPickerScope::OperatorVisibleOnly);
    let choice_items = vec![
        menu_item(
            "Guided Group Picker",
            "Choose visible groups from the curated picker.",
            guided_picker.intro,
        ),
        menu_item(
            "Manual Entry (Advanced)",
            "Type one or more group names directly.",
            guided_picker.manual_detail,
        ),
        menu_item(
            "Back",
            "Cancel this membership change.",
            "Return without changing memberships.",
        ),
    ];

    let Some(selection) = forms::contextual_select(
        "Choose membership change mode",
        Some(
            "Guided selection is the default safe path for user-facing access groups. Manual entry remains available for advanced cases.",
        ),
        &choice_items,
        0,
    )? else {
        return Ok(None);
    };

    match selection {
        0 => {
            let defaults = groups
                .iter()
                .map(|group| {
                    matches!(mode, MembershipChange::Remove)
                        && user.groups.iter().any(|current| current == &group.name)
                })
                .collect::<Vec<_>>();
            let prompt = if matches!(mode, MembershipChange::Add) {
                format!("Select groups to add to '{account_id}'")
            } else {
                format!("Select groups to remove from '{account_id}'")
            };
            let Some(selected) =
                forms::membership_picker(&prompt, groups, &defaults, &user.groups)?
            else {
                return Ok(None);
            };
            Ok(Some(
                selected
                    .into_iter()
                    .map(|index| groups[index].name.clone())
                    .collect::<Vec<_>>(),
            ))
        }
        1 => {
            let Some(group_text) = prompt_submitted(forms::input_required(
                "Enter one or more group names separated by spaces",
                None,
            )?) else {
                return Ok(None);
            };
            let groups = group_text
                .split_whitespace()
                .map(|group| validate_identifier_field("group name", group))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Some(groups))
        }
        _ => Ok(None),
    }
}
