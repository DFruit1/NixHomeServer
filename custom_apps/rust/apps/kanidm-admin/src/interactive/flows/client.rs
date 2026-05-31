use super::super::*;

pub(in crate::interactive) fn redirect_flow(kanidm: &KanidmCli, add: bool) -> Result<(), AppError> {
    let Some(client) = choose_client_name(kanidm, "Select an oauth2 client")? else {
        return Ok(());
    };
    let Some(url) = prompt_submitted(forms::input_required_validated(
        "Redirect URL",
        None,
        |value| validate_redirect_url_for_server(value, kanidm.server_url()),
    )?) else {
        return Ok(());
    };
    let Some(client_record) =
        require_complete_client_for_action(kanidm, &client, "change oauth2 redirect URLs for")?
    else {
        return Ok(());
    };
    let already_present = client_record
        .value
        .redirect_urls
        .iter()
        .any(|candidate| candidate == &url);
    if add && already_present {
        render::print_note(
            "OAuth2 Redirect",
            "No redirect URL changes would be applied.",
        );
        return forms::pause("Press Enter or Esc to continue");
    }
    if !add && !already_present {
        render::print_note(
            "OAuth2 Redirect",
            "No redirect URL changes would be applied.",
        );
        return forms::pause("Press Enter or Esc to continue");
    }
    render::print_note(
        "Review OAuth2 Redirect Change",
        &build_redirect_review(&client_record.value, &url, add, already_present),
    );
    match forms::confirm("Apply this redirect change now?", false)? {
        Some(true) => {}
        _ => return Ok(()),
    }
    if add {
        run_privileged_command("OAuth2 Redirect", kanidm, || {
            client_redirect_add(kanidm, &client, &url)
        })
    } else {
        run_privileged_command("OAuth2 Redirect", kanidm, || {
            client_redirect_remove(kanidm, &client, &url)
        })
    }
}
