use super::forms;

pub(super) fn render_bullets(items: &[String]) -> String {
    items
        .iter()
        .map(|item| format!("- {item}"))
        .collect::<Vec<_>>()
        .join("\n")
}

pub(super) fn menu_item(label: &str, summary: &str, detail: &str) -> forms::ContextualItem {
    forms::ContextualItem {
        label: label.to_string(),
        summary: summary.to_string(),
        detail: detail.to_string(),
    }
}

pub(super) fn simple_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Create User",
            "Create a new Kanidm person and then assign their access groups.",
            "Use this for new staff or household members. The workflow creates the identity first and then immediately guides you through normal and admin access groups.",
        ),
        menu_item(
            "Manage User Access",
            "Set the user's normal app and file access groups.",
            "Use this as the normal safe path for day-to-day access changes. The workflow reviews and replaces the user's full direct-group access set with explicit before-and-after confirmation.",
        ),
        menu_item(
            "Find / View User",
            "Inspect a user and understand what access they currently have.",
            "Use this when you need to confirm identity details, status, direct groups, or app-access implications without changing anything.",
        ),
        menu_item(
            "Disable / Enable User",
            "Temporarily block or restore a user's ability to sign in.",
            "Use disable for temporary lockout or offboarding without deleting the identity. The workflow detects the current state and offers only the valid action.",
        ),
        menu_item(
            "Help User Reset Password",
            "Generate a temporary password reset link for a user.",
            "Use this when someone cannot sign in and needs to set a new password. The result should be shared through a secure channel because it grants temporary password reset access.",
        ),
        menu_item(
            "Set / Reset POSIX Password",
            "Set the separate POSIX/UNIX password used by Kanidm UnixD.",
            "Use this only when a workflow explicitly needs a POSIX/UNIX password. Direct SFTP uses SSH public keys. This does not change the user's web/OIDC password or passkeys.",
        ),
        menu_item(
            "Show Backend Logs",
            "Inspect recent raw Kanidm and Kanidm UnixD command output.",
            "Use this when a result needs debugging. The log includes recent backend commands, exit status, stdout, stderr, and execution errors from this TUI session.",
        ),
        menu_item(
            "Advanced",
            "Open session management, lower-level Kanidm, and local helper tools.",
            "Use this for session tools, raw membership tools, group inspection, OAuth2 clients, policy, diagnostics, or permanent deletion.",
        ),
        menu_item(
            "Exit",
            "Leave the interactive Kanidm admin tool.",
            "Use this when you are finished with user administration tasks.",
        ),
    ]
}

pub(super) fn client_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "List clients",
            "Show the live OAuth2 client inventory.",
            "Use this for a broad read-only list of discoverable OAuth2 clients before drilling into a specific one.",
        ),
        menu_item(
            "Show client",
            "Inspect one OAuth2 client in detail.",
            "Use this to review redirect URLs, scope maps, claim maps, and related client settings.",
        ),
        menu_item(
            "Show client secret",
            "Reveal the current client secret for one OAuth2 client.",
            "Use this only when an operator needs to inspect the currently active secret value for a client.",
        ),
        menu_item(
            "Reset client secret",
            "Generate and apply a new client secret.",
            "Use this when a client secret must be rotated. This is a privileged write operation and may require reauthentication.",
        ),
        menu_item(
            "Enable PKCE",
            "Require PKCE for the selected client.",
            "Use this to harden a client that should perform PKCE-based authorization flows.",
        ),
        menu_item(
            "Disable PKCE",
            "Stop requiring PKCE for the selected client.",
            "Use this only when the client cannot complete PKCE and the runtime configuration must be relaxed.",
        ),
        menu_item(
            "Enable consent prompt",
            "Require a consent prompt for the selected client.",
            "Use this when the client should explicitly prompt users before granting access.",
        ),
        menu_item(
            "Disable consent prompt",
            "Stop requiring a consent prompt for the selected client.",
            "Use this when the current runtime flow should proceed without a consent screen.",
        ),
        menu_item(
            "Add redirect URL",
            "Append one redirect URL to a live OAuth2 client.",
            "Use this when a client needs an additional callback URL. The review screen shows the current redirect set before applying a write.",
        ),
        menu_item(
            "Remove redirect URL",
            "Remove one redirect URL from a live OAuth2 client.",
            "Use this when an old callback URL should no longer be accepted. The review screen shows the current redirect set before applying a write.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without changing OAuth2 client settings.",
        ),
    ]
}

pub(super) fn advanced_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Session Tools",
            "Inspect or manage the current Kanidm CLI session.",
            "Use this for explicit login, reauthentication, logout, or session inspection when guided workflows are not enough.",
        ),
        menu_item(
            "Group Inspection",
            "Read group information without changing access.",
            "Use this to list groups, inspect a group, search by name, or review group members. All live groups are shown here, including internal Kanidm groups.",
        ),
        menu_item(
            "Membership Tools",
            "Open the lower-level direct-group access commands.",
            "Use this only when the guided access workflow is not enough. These tools expose targeted add/remove commands plus exact-set operations for experienced operators.",
        ),
        menu_item(
            "OAuth2 Clients",
            "Inspect and adjust live OAuth2 client behavior.",
            "Use this for client secrets, redirects, PKCE, and consent prompts. New system admins normally do not need this during user onboarding.",
        ),
        menu_item(
            "Group Policy",
            "Inspect or tune live Kanidm group account policy.",
            "Use this for auth-expiry or privilege-expiry changes. This is a specialized area and not part of routine user administration.",
        ),
        menu_item(
            "Context / Doctor",
            "Inspect tool context and run basic environment checks.",
            "Use this when troubleshooting Kanidm context, session health, or incomplete live discovery. Doctor is the first place to look when commands start behaving unexpectedly.",
        ),
        menu_item(
            "Local Helpers",
            "Run machine-local helper utilities that are not normal Kanidm operations.",
            "Use this for local helper tasks such as staging a Jellyfin password hash. This area is intentionally separate from normal identity administration.",
        ),
        menu_item(
            "Delete User",
            "Permanently remove a Kanidm identity.",
            "Use this only when the identity should no longer exist at all. Do not use it for temporary lockout or routine access removal.",
        ),
        menu_item(
            "Back",
            "Return to the main task menu.",
            "Go back to the default guided admin workflow.",
        ),
    ]
}

pub(super) fn session_tools_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Status",
            "Inspect the current Kanidm CLI session state.",
            "Use this to confirm whether the delegated operator session is active, expired, or needs privileged reauthentication.",
        ),
        menu_item(
            "Login",
            "Start a new Kanidm CLI session.",
            "Use this when no valid session exists yet. The login flow requires an interactive terminal.",
        ),
        menu_item(
            "Reauthenticate",
            "Refresh privileged session access.",
            "Use this when a session exists but privileged operations now require reauthentication.",
        ),
        menu_item(
            "Logout",
            "End the current Kanidm CLI session.",
            "Use this when the current delegated operator session should be cleared from the machine.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without changing the current Kanidm session.",
        ),
    ]
}

pub(super) fn group_inspection_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "List groups",
            "Show the live Kanidm groups.",
            "Use this for a broad read-only inventory of available groups.",
        ),
        menu_item(
            "Search groups",
            "Search live groups by name or description.",
            "Use this when you need to find a group quickly without scanning the full list.",
        ),
        menu_item(
            "Show group",
            "Inspect one group in detail.",
            "Use this to review a group's description and other live details. All live groups are shown here, including internal Kanidm groups.",
        ),
        menu_item(
            "List group members",
            "Show the people currently in a group.",
            "Use this to confirm who currently holds a specific access or admin role. All live groups are shown here, including internal Kanidm groups.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without inspecting more groups.",
        ),
    ]
}

pub(super) fn membership_tools_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item("View User Access", "Show a user's current direct groups.", "Use this for a raw read-only view of direct group membership when the guided user summary is not enough."),
        menu_item("Add memberships", "Add one or more direct groups without replacing the rest.", "Use this for intentional targeted access additions when the full guided exact-set workflow would be excessive. The guided picker remains the default path inside this tool."),
        menu_item("Remove memberships", "Remove one or more direct groups without changing the rest.", "Use this for intentional targeted access removal when the full guided exact-set workflow would be excessive. The guided picker remains the default path inside this tool."),
        menu_item("Set exact memberships", "Replace the user's full direct-group set.", "Use this to authoritatively define the final direct-group access list for a user. This is the same exact-set behavior used by the guided access workflow."),
        menu_item("Back", "Return to Advanced.", "Go back without making membership changes."),
    ]
}

pub(super) fn policy_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Show group policy",
            "Inspect the current live account-policy values for one group.",
            "Use this to read auth-expiry or privilege-expiry values before deciding whether a live policy write is needed.",
        ),
        menu_item(
            "Set auth expiry",
            "Set the live auth-expiry value for one group.",
            "Use this specialized policy control when the selected group's base authentication session lifetime needs a runtime change.",
        ),
        menu_item(
            "Reset auth expiry",
            "Clear the live auth-expiry value for one group.",
            "Use this when the explicit auth-expiry override should be removed from the selected group.",
        ),
        menu_item(
            "Set privilege expiry",
            "Set the live privileged-session expiry value for one group.",
            "Use this specialized policy control when the selected group's privileged-session lifetime needs a runtime change.",
        ),
        menu_item(
            "Reset privilege expiry",
            "Clear the live privileged-session expiry value for one group.",
            "Use this when the explicit privileged-session expiry override should be removed from the selected group.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without changing group policy.",
        ),
    ]
}

pub(super) fn context_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Show context",
            "Inspect the repo and Kanidm connection context used by this tool.",
            "Use this to confirm which repository root, server URL, admin account name, and Kanidm binary path the tool resolved.",
        ),
        menu_item(
            "Doctor",
            "Run basic environment and discovery health checks.",
            "Use this when session state or live inventory looks incomplete or commands are behaving unexpectedly.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without running more context or doctor checks.",
        ),
    ]
}

pub(super) fn local_helpers_menu_items() -> Vec<forms::ContextualItem> {
    vec![
        menu_item(
            "Invite user to Vaultwarden",
            "Invite a Kanidm user email into Vaultwarden.",
            "Use this onboarding helper to standardize password-vault access for less technical users before they store their Kanidm password, TOTP, and passkey details.",
        ),
        menu_item(
            "Stage Jellyfin password",
            "Write a local Jellyfin password hash file from an environment variable.",
            "Use this machine-local helper when the Jellyfin password hash needs to be staged outside normal Kanidm identity administration.",
        ),
        menu_item(
            "Back",
            "Return to Advanced.",
            "Go back without running a local helper.",
        ),
    ]
}
