use clap::{Args, Parser, Subcommand};
use dialoguer::{Confirm, Input};
use kanidm_admin::{
    context::{resolve_context, ContextOverrides, ResolvedContext},
    interactive,
    kanidm_cli::KanidmCli,
    ops::{
        client::{
            client_consent_disable, client_consent_enable, client_pkce_disable, client_pkce_enable,
            client_redirect_add, client_redirect_remove, client_secret_reset, client_secret_show,
            list_clients, show_client,
        },
        context::{doctor, show_context},
        executor::{
            execute_interactive_operation, OperationKind, OperationOutcome, OperationPreconditions,
            RecoveryTarget,
        },
        group::{group_members, list_groups, search_groups, show_group},
        history::{
            list_history, prune_history, record_operation_best_effort, redact_sensitive_history,
            resume_history, show_history,
        },
        local::{
            diagnose_jellyfin_password, diagnose_vaultwarden_user, invite_vaultwarden_user,
            reconcile_jellyfin_password, reconcile_vaultwarden_user, stage_jellyfin_password,
            test_jellyfin_password,
        },
        local_runtime::ConvergencePolicy,
        membership::{
            add_membership_with_config, remove_membership_with_config, set_membership_with_config,
            show_membership, SetMembershipOptions,
        },
        policy::{
            reset_group_auth_expiry, reset_group_privilege_expiry, set_group_auth_expiry,
            set_group_privilege_expiry, show_group_policy,
        },
        session::{
            ensure_interactive_session_allowed, session_diagnose, session_login, session_logout,
            session_reauth, session_status,
        },
        sftp::{
            diagnose_sftp_login_with_policy, reconcile_sftp_login_with_policy,
            test_sftp_login_with_policy,
        },
        user::{
            create_user, delete_user, disable_user, enable_user, list_users, reset_token,
            show_user, CreateUserOptions, DeleteUserOptions, ResetTokenOptions,
        },
    },
    output::{render_error, render_output, CommandOutput, OutputFormat, Sensitivity},
    session_state::SessionSnapshot,
    validation::{
        validate_account_id, validate_display_name, validate_email, validate_identifier_field,
        validate_redirect_url_for_server, validate_search_query, validate_seconds_field,
        AUTH_EXPIRY_MAX_SECONDS, AUTH_EXPIRY_MIN_SECONDS, PRIVILEGE_EXPIRY_MAX_SECONDS,
        PRIVILEGE_EXPIRY_MIN_SECONDS, RESET_TOKEN_TTL_MAX_SECONDS, RESET_TOKEN_TTL_MIN_SECONDS,
    },
};
use serde_json::json;
use std::time::Duration;

const ROOT_AFTER_HELP: &str =
    "Examples:\n  kanidm-admin\n  kanidm-admin context show\n  kanidm-admin doctor";
const SESSION_LOGIN_AFTER_HELP: &str =
    "Example:\n  kanidm-admin session login\n\nThis command requires a terminal on stdin and stdout and only supports --output human.";
const GROUP_SEARCH_AFTER_HELP: &str =
    "Example:\n  kanidm-admin group search storage\n\nMatches are case-insensitive and search both group names and descriptions.";
const USER_CREATE_AFTER_HELP: &str =
    "Examples:\n  kanidm-admin user create alice --display-name \"Alice\" --email alice@example.com\n  kanidm-admin user create service-user --display-name \"Service User\" --preserve-validity";
const USER_CREATE_NEW_AFTER_HELP: &str =
    "Example:\n  kanidm-admin user create-new\n\nPrompts for identity fields, initial direct groups, validity handling, and an optional password reset link. Alias: kanidm-admin user new";
const MEMBERSHIP_SET_AFTER_HELP: &str =
    "Examples:\n  kanidm-admin membership set alice users paperless-users\n  kanidm-admin membership set alice --allow-empty --confirm-empty alice";
const DELETE_USER_AFTER_HELP: &str = "Example:\n  kanidm-admin user delete alice --confirm alice";

#[derive(Debug, Parser)]
#[command(name = "kanidm-admin")]
#[command(
    about = "Live-discovery Kanidm operator CLI for sessions, users, groups, clients, and policy."
)]
#[command(after_help = ROOT_AFTER_HELP)]
struct Cli {
    #[arg(
        long,
        global = true,
        help = "Override repository root used for context discovery."
    )]
    repo_root: Option<std::path::PathBuf>,

    #[arg(long, global = true, help = "Override the Kanidm server URL.")]
    server_url: Option<String>,

    #[arg(long, global = true, help = "Override the Kanidm admin account name.")]
    admin_name: Option<String>,

    #[arg(
        long,
        global = true,
        value_enum,
        default_value_t = OutputFormat::Human,
        help = "Select human-readable or JSON output."
    )]
    output: OutputFormat,

    #[arg(long, global = true, help = "Alias for --output json.")]
    json: bool,

    #[arg(
        long,
        global = true,
        help = "Override captured backend command timeout in seconds."
    )]
    backend_timeout_seconds: Option<u64>,

    #[arg(
        long,
        global = true,
        help = "Validate and describe a supported mutating command without applying it."
    )]
    dry_run: bool,

    #[command(subcommand)]
    command: Option<Commands>,
}

impl Cli {
    fn output_format(&self) -> OutputFormat {
        if self.json {
            OutputFormat::Json
        } else {
            self.output
        }
    }

    fn command_needs(&self) -> CommandNeeds {
        match &self.command {
            None => CommandNeeds::KanidmAndLocalRuntime,
            Some(Commands::History(_)) => CommandNeeds::HistoryOnly,
            Some(Commands::Context(_)) => CommandNeeds::RepoDefaults,
            Some(Commands::Doctor(command)) if command.deep => CommandNeeds::KanidmAndLocalRuntime,
            Some(Commands::Doctor(_)) => CommandNeeds::Kanidm,
            Some(Commands::Local(command)) => match &command.command {
                LocalSubcommand::JellyfinPassword(command) => match &command.command {
                    LocalJellyfinPasswordSubcommand::Stage { .. } => CommandNeeds::None,
                    LocalJellyfinPasswordSubcommand::Diagnose { .. }
                    | LocalJellyfinPasswordSubcommand::Reconcile { .. }
                    | LocalJellyfinPasswordSubcommand::Test { .. } => {
                        CommandNeeds::KanidmAndLocalRuntime
                    }
                },
                LocalSubcommand::Sftp(_) | LocalSubcommand::Vaultwarden(_) => {
                    CommandNeeds::KanidmAndLocalRuntime
                }
            },
            Some(Commands::Session(_))
            | Some(Commands::User(_))
            | Some(Commands::Group(_))
            | Some(Commands::Membership(_))
            | Some(Commands::Client(_))
            | Some(Commands::Policy(_)) => CommandNeeds::Kanidm,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CommandNeeds {
    None,
    HistoryOnly,
    RepoDefaults,
    Kanidm,
    KanidmAndLocalRuntime,
}

#[derive(Debug, Subcommand)]
enum Commands {
    #[command(about = "Run basic environment and connectivity checks.")]
    Doctor(DoctorCommand),
    #[command(about = "Inspect the resolved repo and Kanidm connection context.")]
    Context(ContextCommand),
    #[command(about = "Inspect or manage the current Kanidm CLI session.")]
    Session(SessionCommand),
    #[command(about = "Manage Kanidm users and password reset flows.")]
    User(UserCommand),
    #[command(about = "Inspect live Kanidm groups.")]
    Group(GroupCommand),
    #[command(about = "Inspect or change direct group memberships.")]
    Membership(MembershipCommand),
    #[command(about = "Inspect or adjust live OAuth2 clients.")]
    Client(ClientCommand),
    #[command(about = "Inspect or tune live Kanidm group policy.")]
    Policy(PolicyCommand),
    #[command(about = "Run local helper utilities outside normal Kanidm operations.")]
    Local(LocalCommand),
    #[command(about = "Inspect persisted kanidm-admin operation history.")]
    History(HistoryCommand),
}

#[derive(Debug, Args)]
struct ContextCommand {
    #[command(subcommand)]
    command: ContextSubcommand,
}

#[derive(Debug, Args)]
struct DoctorCommand {
    #[arg(
        long,
        help = "Run non-mutating local runtime checks in addition to fast Kanidm probes."
    )]
    deep: bool,
}

#[derive(Debug, Subcommand)]
enum ContextSubcommand {
    Show,
}

#[derive(Debug, Args)]
struct SessionCommand {
    #[command(subcommand)]
    command: SessionSubcommand,
}

#[derive(Debug, Subcommand)]
enum SessionSubcommand {
    #[command(about = "Show whether the current Kanidm CLI session is active.")]
    Status,
    #[command(about = "Show parser confidence and recovery guidance for the current session.")]
    Diagnose,
    #[command(about = "Start a new delegated operator session.", after_help = SESSION_LOGIN_AFTER_HELP)]
    Login,
    #[command(about = "Refresh privileged write access for the current session.", after_help = SESSION_LOGIN_AFTER_HELP)]
    Reauth,
    #[command(about = "Log out of the current Kanidm CLI session.")]
    Logout,
}

#[derive(Debug, Args)]
struct UserCommand {
    #[command(subcommand)]
    command: UserSubcommand,
}

#[derive(Debug, Subcommand)]
enum UserSubcommand {
    #[command(about = "List Kanidm users discovered from the live runtime.")]
    List,
    #[command(about = "Show one Kanidm user and their current state.")]
    Show { account_id: String },
    #[command(
        about = "Create a Kanidm user, clearing validity restrictions by default.",
        after_help = USER_CREATE_AFTER_HELP
    )]
    Create {
        account_id: String,
        #[arg(long, help = "Set the display name shown for this user.")]
        display_name: String,
        #[arg(long, help = "Set the primary email address during creation.")]
        email: Option<String>,
        #[arg(
            long,
            default_value_t = false,
            help = "Preserve any backend validity restrictions instead of clearing them after creation."
        )]
        preserve_validity: bool,
    },
    #[command(
        name = "create-new",
        alias = "new",
        about = "Prompt for the normal new-user details and create the account.",
        after_help = USER_CREATE_NEW_AFTER_HELP
    )]
    CreateNew,
    #[command(about = "Disable a user without deleting their identity.")]
    Disable { account_id: String },
    #[command(about = "Re-enable a disabled or restricted user.")]
    Enable { account_id: String },
    #[command(
        about = "Permanently delete a Kanidm user.",
        after_help = DELETE_USER_AFTER_HELP
    )]
    Delete {
        account_id: String,
        #[arg(long, help = "Repeat the account id exactly to confirm deletion.")]
        confirm: String,
    },
    #[command(about = "Create a temporary password reset link or token.")]
    ResetToken {
        account_id: String,
        #[arg(
            long,
            default_value_t = 3600,
            help = "Password reset lifetime in seconds."
        )]
        ttl: u64,
    },
}

#[derive(Debug, Args)]
struct GroupCommand {
    #[command(subcommand)]
    command: GroupSubcommand,
}

#[derive(Debug, Subcommand)]
enum GroupSubcommand {
    #[command(about = "List live Kanidm groups.")]
    List,
    #[command(
        about = "Search groups by case-insensitive name or description.",
        after_help = GROUP_SEARCH_AFTER_HELP
    )]
    Search { query: String },
    #[command(about = "Show one Kanidm group in detail.")]
    Show { group: String },
    #[command(about = "List the current members of one group.")]
    Members { group: String },
}

#[derive(Debug, Args)]
struct MembershipCommand {
    #[command(subcommand)]
    command: MembershipSubcommand,
}

#[derive(Debug, Subcommand)]
enum MembershipSubcommand {
    #[command(about = "Show a user's current direct groups.")]
    Show { account_id: String },
    #[command(about = "Add one or more direct groups without replacing the rest.")]
    Add {
        account_id: String,
        #[arg(required = true, num_args = 1.., help = "One or more group names to add.")]
        groups: Vec<String>,
    },
    #[command(about = "Remove one or more direct groups without changing the rest.")]
    Remove {
        account_id: String,
        #[arg(required = true, num_args = 1.., help = "One or more group names to remove.")]
        groups: Vec<String>,
    },
    #[command(
        about = "Replace the user's full direct-group set.",
        after_help = MEMBERSHIP_SET_AFTER_HELP
    )]
    Set {
        account_id: String,
        #[arg(help = "The exact direct groups the user should keep after the change.")]
        groups: Vec<String>,
        #[arg(
            long,
            default_value_t = false,
            help = "Allow replacing memberships with an empty set."
        )]
        allow_empty: bool,
        #[arg(
            long = "confirm-empty",
            value_name = "ACCOUNT_ID",
            help = "Repeat the account id exactly when intentionally setting an empty membership set."
        )]
        confirm_empty: Option<String>,
    },
}

#[derive(Debug, Args)]
struct ClientCommand {
    #[command(subcommand)]
    command: ClientSubcommand,
}

#[derive(Debug, Subcommand)]
enum ClientSubcommand {
    #[command(about = "List live OAuth2 clients discovered from Kanidm.")]
    List,
    #[command(about = "Show one OAuth2 client in detail.")]
    Show { client: String },
    #[command(about = "Show or rotate an OAuth2 client basic secret.")]
    Secret(ClientSecretCommand),
    #[command(about = "Add or remove OAuth2 redirect URLs.")]
    Redirect(ClientRedirectCommand),
    #[command(about = "Enable or disable PKCE for an OAuth2 client.")]
    Pkce(ClientPkceCommand),
    #[command(about = "Enable or disable consent prompts for an OAuth2 client.")]
    Consent(ClientConsentCommand),
}

#[derive(Debug, Args)]
struct ClientSecretCommand {
    #[command(subcommand)]
    command: ClientSecretSubcommand,
}

#[derive(Debug, Subcommand)]
enum ClientSecretSubcommand {
    #[command(about = "Reveal the current basic secret for an OAuth2 client.")]
    Show {
        client: String,
        #[arg(
            long = "confirm-reveal-secret",
            value_name = "CLIENT",
            help = "Repeat the client name exactly to reveal the current secret."
        )]
        confirm_reveal_secret: Option<String>,
    },
    #[command(about = "Rotate the basic secret for an OAuth2 client.")]
    Reset {
        client: String,
        #[arg(
            long = "confirm-rotate-secret",
            value_name = "CLIENT",
            help = "Repeat the client name exactly to rotate the secret."
        )]
        confirm_rotate_secret: Option<String>,
    },
}

#[derive(Debug, Args)]
struct ClientRedirectCommand {
    #[command(subcommand)]
    command: ClientRedirectSubcommand,
}

#[derive(Debug, Subcommand)]
enum ClientRedirectSubcommand {
    #[command(about = "Add one redirect URL to an OAuth2 client.")]
    Add { client: String, url: String },
    #[command(about = "Remove one redirect URL from an OAuth2 client.")]
    Remove { client: String, url: String },
}

#[derive(Debug, Args)]
struct ClientPkceCommand {
    #[command(subcommand)]
    command: ClientPkceSubcommand,
}

#[derive(Debug, Subcommand)]
enum ClientPkceSubcommand {
    #[command(about = "Require PKCE for an OAuth2 client.")]
    Enable { client: String },
    #[command(about = "Disable PKCE for an OAuth2 client.")]
    Disable {
        client: String,
        #[arg(
            long = "confirm-insecure-pkce-disable",
            value_name = "CLIENT",
            help = "Repeat the client name exactly to disable PKCE."
        )]
        confirm_insecure_pkce_disable: Option<String>,
    },
}

#[derive(Debug, Args)]
struct ClientConsentCommand {
    #[command(subcommand)]
    command: ClientConsentSubcommand,
}

#[derive(Debug, Subcommand)]
enum ClientConsentSubcommand {
    #[command(about = "Require user consent prompts for an OAuth2 client.")]
    Enable { client: String },
    #[command(about = "Disable user consent prompts for an OAuth2 client.")]
    Disable {
        client: String,
        #[arg(
            long = "confirm-disable-consent",
            value_name = "CLIENT",
            help = "Repeat the client name exactly to disable consent prompts."
        )]
        confirm_disable_consent: Option<String>,
    },
}

#[derive(Debug, Args)]
struct PolicyCommand {
    #[command(subcommand)]
    command: PolicySubcommand,
}

#[derive(Debug, Subcommand)]
enum PolicySubcommand {
    #[command(about = "Inspect or tune group account-policy values.")]
    Group(PolicyGroupCommand),
}

#[derive(Debug, Args)]
struct PolicyGroupCommand {
    #[command(subcommand)]
    command: PolicyGroupSubcommand,
}

#[derive(Debug, Subcommand)]
enum PolicyGroupSubcommand {
    #[command(about = "Show account-policy values for a group.")]
    Show { group: String },
    #[command(about = "Set or reset group authentication expiry.")]
    AuthExpiry(PolicyValueCommand),
    #[command(about = "Set or reset group privilege expiry.")]
    PrivilegeExpiry(PolicyValueCommand),
}

#[derive(Debug, Args)]
struct PolicyValueCommand {
    #[command(subcommand)]
    command: PolicyValueSubcommand,
}

#[derive(Debug, Subcommand)]
enum PolicyValueSubcommand {
    #[command(about = "Set a policy value in seconds.")]
    Set { group: String, seconds: u64 },
    #[command(about = "Reset a policy value to the backend default.")]
    Reset { group: String },
}

#[derive(Debug, Args)]
struct LocalCommand {
    #[command(subcommand)]
    command: LocalSubcommand,
}

#[derive(Debug, Subcommand)]
enum LocalSubcommand {
    #[command(about = "Stage and inspect local Jellyfin password state.")]
    JellyfinPassword(LocalJellyfinPasswordCommand),
    #[command(about = "Inspect and reconcile local SFTP runtime state.")]
    Sftp(LocalSftpCommand),
    #[command(about = "Invite or inspect local-auth Vaultwarden users.")]
    Vaultwarden(LocalVaultwardenCommand),
}

#[derive(Debug, Args)]
struct LocalJellyfinPasswordCommand {
    #[command(subcommand)]
    command: LocalJellyfinPasswordSubcommand,
}

#[derive(Debug, Subcommand)]
enum LocalJellyfinPasswordSubcommand {
    #[command(about = "Write a staged Jellyfin password hash from an environment variable.")]
    Stage {
        account_id: String,
        #[arg(long, default_value = "JELLYFIN_PASSWORD")]
        password_env: String,
    },
    #[command(about = "Inspect staged Jellyfin password prerequisites for a user.")]
    Diagnose { account_id: String },
    #[command(about = "Start the Jellyfin password reconciler and verify convergence.")]
    Reconcile { account_id: String },
    #[command(about = "Run the Jellyfin password readiness checks without changing state.")]
    Test { account_id: String },
}

#[derive(Debug, Args)]
struct LocalSftpCommand {
    #[command(subcommand)]
    command: LocalSftpSubcommand,
}

#[derive(Debug, Clone, Args)]
struct RuntimeCliOptions {
    #[arg(long, help = "Override local runtime convergence timeout in seconds.")]
    timeout: Option<u64>,
    #[arg(
        long,
        help = "Override local runtime convergence retry interval in milliseconds."
    )]
    interval: Option<u64>,
}

#[derive(Debug, Subcommand)]
enum LocalSftpSubcommand {
    #[command(about = "Inspect the non-secret SFTP login prerequisites for a user.")]
    Diagnose {
        account_id: String,
        #[command(flatten)]
        runtime: RuntimeCliOptions,
    },
    #[command(about = "Run local SFTP sync services and verify the login path.")]
    Reconcile {
        account_id: String,
        #[command(flatten)]
        runtime: RuntimeCliOptions,
    },
    #[command(about = "Test the local SFTP runtime path without changing Kanidm state.")]
    Test {
        account_id: String,
        #[command(flatten)]
        runtime: RuntimeCliOptions,
    },
}

#[derive(Debug, Args)]
struct LocalVaultwardenCommand {
    #[command(subcommand)]
    command: LocalVaultwardenSubcommand,
}

#[derive(Debug, Args)]
struct HistoryCommand {
    #[command(subcommand)]
    command: HistorySubcommand,
}

#[derive(Debug, Subcommand)]
enum HistorySubcommand {
    #[command(about = "List recent persisted operation history entries.")]
    List,
    #[command(about = "Show one persisted operation history entry.")]
    Show { operation_id: String },
    #[command(about = "Prepare a safe retry command from a persisted history entry.")]
    Resume { operation_id: String },
    #[command(
        about = "Prune persisted operation history entries older than a duration such as 30d."
    )]
    Prune {
        #[arg(
            long,
            help = "Remove entries older than this duration, for example 30d, 12h, or 90m."
        )]
        older_than: String,
    },
    #[command(about = "Redact sensitive reset-token and client-secret data in persisted history.")]
    RedactSensitive,
}

#[derive(Debug, Subcommand)]
enum LocalVaultwardenSubcommand {
    #[command(
        about = "Create or refresh a pending Vaultwarden invite for a user's primary email."
    )]
    Invite { account_id: String },
    #[command(about = "Inspect Vaultwarden invite/account state for a Kanidm user.")]
    Diagnose { account_id: String },
    #[command(about = "Invite the user if needed, then verify Vaultwarden state.")]
    Reconcile { account_id: String },
}

pub fn main() {
    let invocation_args = std::env::args().collect::<Vec<_>>();
    let cli = Cli::parse_from(&invocation_args);
    let output = cli.output_format();

    match run(cli, &invocation_args) {
        Ok(Some(command_output)) => {
            println!("{}", render_output(output, &command_output));
        }
        Ok(None) => {}
        Err(error) => {
            eprintln!("{}", render_error(output, &error));
            std::process::exit(error.exit_code());
        }
    }
}

#[derive(Debug, Clone)]
struct PromptedCreateNewUserOptions {
    account_id: String,
    display_name: String,
    email: Option<String>,
    groups: Vec<String>,
    clear_validity: bool,
    create_reset_token: bool,
    reset_token_ttl_seconds: u64,
}

fn create_new_user_interactive(
    kanidm: &KanidmCli,
    sftp_runtime: &kanidm_admin::context::SftpRuntimeConfig,
    output: OutputFormat,
) -> Result<CommandOutput, kanidm_admin::AppError> {
    ensure_interactive_session_allowed(output)?;
    let options = prompt_create_new_user_options()?;
    if !confirm_create_new_user(&options)? {
        return Ok(CommandOutput {
            message: "new user creation cancelled".to_string(),
            human: "New user creation cancelled. No changes were applied.".to_string(),
            details: json!({ "executed": false }),
            warnings: Vec::new(),
        });
    }

    match execute_interactive_operation(
        kanidm,
        OperationKind::PrivilegedWrite,
        OperationPreconditions::PrivilegedWriteReady,
        || perform_create_new_user(kanidm, sftp_runtime, &options),
        |target, error, snapshot| {
            recover_cli_session_interactively(
                kanidm,
                output,
                target,
                error,
                snapshot,
                "new user creation",
            )
        },
    )? {
        OperationOutcome::Success(output) => Ok(output),
        OperationOutcome::Cancelled => Err(kanidm_admin::AppError::Config {
            message: "new user creation cancelled before authentication completed".to_string(),
        }),
        OperationOutcome::RecoverableFailure(error) | OperationOutcome::Fatal(error) => Err(error),
    }
}

fn prompt_create_new_user_options() -> Result<PromptedCreateNewUserOptions, kanidm_admin::AppError>
{
    let account_id = prompt_required_validated("Account id / username", None, validate_account_id)?;
    let display_name = prompt_required_validated(
        "Display name",
        Some(account_id.as_str()),
        validate_display_name,
    )?;
    let email = prompt_optional_validated("Primary email", None, validate_email)?;
    let groups = prompt_group_list()?;
    let clear_validity = prompt_confirm("Clear validity restrictions after creation?", true)?;
    let create_reset_token = prompt_confirm("Create a temporary password reset link?", true)?;
    let reset_token_ttl_seconds = if create_reset_token {
        prompt_ttl_seconds()?
    } else {
        0
    };

    Ok(PromptedCreateNewUserOptions {
        account_id,
        display_name,
        email,
        groups,
        clear_validity,
        create_reset_token,
        reset_token_ttl_seconds,
    })
}

fn perform_create_new_user(
    kanidm: &KanidmCli,
    sftp_runtime: &kanidm_admin::context::SftpRuntimeConfig,
    options: &PromptedCreateNewUserOptions,
) -> Result<CommandOutput, kanidm_admin::AppError> {
    let mut completed_steps = Vec::new();
    let mut warnings = Vec::new();

    let create_output = create_user(
        kanidm,
        CreateUserOptions {
            account_id: options.account_id.clone(),
            display_name: options.display_name.clone(),
            email: options.email.clone(),
            clear_validity: options.clear_validity,
        },
    )?;
    completed_steps.push("create_user".to_string());
    warnings.extend(create_output.warnings.clone());

    let membership_output = match set_membership_with_config(
        kanidm,
        sftp_runtime,
        SetMembershipOptions {
            account_id: options.account_id.clone(),
            groups: options.groups.clone(),
            preserve_groups: Vec::new(),
            allow_empty: true,
        },
    ) {
        Ok(output) => {
            completed_steps.push("set_membership".to_string());
            warnings.extend(output.warnings.clone());
            output
        }
        Err(error) => {
            return Err(create_new_user_partial_error(
                options,
                &completed_steps,
                "set_membership",
                error,
            ));
        }
    };

    let reset_output = if options.create_reset_token {
        match reset_token(
            kanidm,
            ResetTokenOptions {
                account_id: options.account_id.clone(),
                ttl_seconds: options.reset_token_ttl_seconds,
            },
        ) {
            Ok(output) => {
                completed_steps.push("reset_token".to_string());
                warnings.extend(output.warnings.clone());
                Some(output)
            }
            Err(error) => {
                return Err(create_new_user_partial_error(
                    options,
                    &completed_steps,
                    "reset_token",
                    error,
                ));
            }
        }
    } else {
        None
    };

    let mut human = format!(
        "Created new Kanidm user '{}'.\n\n{}\n\n{}",
        options.account_id, create_output.human, membership_output.human
    );
    if let Some(reset_output) = &reset_output {
        human.push_str("\n\n");
        human.push_str(&reset_output.human);
    } else {
        human.push_str("\n\nPassword Reset:\nNo password reset link was created.");
    }
    human.push_str("\n\nNext Steps:");
    if reset_output.is_some() {
        human.push_str("\n- Have the user open the reset link and set their web/OIDC credentials.");
    } else {
        human.push_str(&format!(
            "\n- Create a reset link when needed with `kanidm-admin user reset-token {} --ttl 3600`.",
            options.account_id
        ));
    }
    human.push_str(&format!(
        "\n- For direct SFTP access, install their SSH public key at `/persist/appdata/files-sftp-authorized-keys/{}`.\n- For Vaultwarden, run `kanidm-admin local vaultwarden invite {}` if they should use the shared password manager.",
        options.account_id, options.account_id
    ));

    let mut output = CommandOutput {
        message: format!("created new Kanidm user '{}'", options.account_id),
        human,
        details: json!({
            "account_id": options.account_id,
            "requested_state": {
                "display_name": options.display_name,
                "email": options.email,
                "groups": options.groups,
                "clear_validity": options.clear_validity,
                "create_reset_token": options.create_reset_token,
                "reset_token_ttl_seconds": if options.create_reset_token {
                    json!(options.reset_token_ttl_seconds)
                } else {
                    json!(null)
                },
            },
            "completed_steps": completed_steps,
            "create_user": create_output.details,
            "membership": membership_output.details,
            "reset_token": reset_output.as_ref().map(|output| output.details.clone()),
        }),
        warnings,
    };
    if reset_output.is_some() {
        output = output.with_sensitivity(Sensitivity::Sensitive);
    }
    Ok(output)
}

fn create_new_user_partial_error(
    options: &PromptedCreateNewUserOptions,
    completed_steps: &[String],
    failed_step: &str,
    error: kanidm_admin::AppError,
) -> kanidm_admin::AppError {
    kanidm_admin::AppError::PartialSuccess {
        message: format!(
            "new user '{}' was partially created, but '{failed_step}' did not finish cleanly",
            options.account_id
        ),
        details: json!({
            "resource": "user",
            "name": options.account_id,
            "requested_state": {
                "display_name": options.display_name,
                "email": options.email,
                "groups": options.groups,
                "clear_validity": options.clear_validity,
                "create_reset_token": options.create_reset_token,
                "reset_token_ttl_seconds": if options.create_reset_token {
                    json!(options.reset_token_ttl_seconds)
                } else {
                    json!(null)
                },
            },
            "completed_steps": completed_steps,
            "failed_step": failed_step,
            "next_actions": create_new_user_next_actions(options, failed_step),
            "backend": error.json_payload(),
        }),
    }
}

fn create_new_user_next_actions(
    options: &PromptedCreateNewUserOptions,
    failed_step: &str,
) -> Vec<String> {
    let mut actions = vec![format!(
        "Inspect the user with `kanidm-admin user show {}`.",
        options.account_id
    )];
    if failed_step == "set_membership" {
        if options.groups.is_empty() {
            actions.push(format!(
                "If the empty direct-group set is intended, run `kanidm-admin membership set {} --allow-empty --confirm-empty {}`.",
                options.account_id, options.account_id
            ));
        } else {
            actions.push(format!(
                "Retry access assignment with `kanidm-admin membership set {} {} --allow-empty`.",
                options.account_id,
                options.groups.join(" ")
            ));
        }
    }
    if options.create_reset_token {
        actions.push(format!(
            "Create a reset link with `kanidm-admin user reset-token {} --ttl {}`.",
            options.account_id, options.reset_token_ttl_seconds
        ));
    }
    actions
}

fn prompt_required_validated<F>(
    prompt: &str,
    default: Option<&str>,
    validator: F,
) -> Result<String, kanidm_admin::AppError>
where
    F: Fn(&str) -> Result<String, kanidm_admin::AppError>,
{
    loop {
        let value = prompt_input(prompt, default, false)?;
        match validator(&value) {
            Ok(value) => return Ok(value),
            Err(error) => eprintln!("{}", error.human_message()),
        }
    }
}

fn prompt_optional_validated<F>(
    prompt: &str,
    default: Option<&str>,
    validator: F,
) -> Result<Option<String>, kanidm_admin::AppError>
where
    F: Fn(&str) -> Result<String, kanidm_admin::AppError>,
{
    loop {
        let value = prompt_input(prompt, default, true)?;
        if value.trim().is_empty() {
            return Ok(None);
        }
        match validator(&value) {
            Ok(value) => return Ok(Some(value)),
            Err(error) => eprintln!("{}", error.human_message()),
        }
    }
}

fn prompt_group_list() -> Result<Vec<String>, kanidm_admin::AppError> {
    loop {
        let value = prompt_input(
            "Initial direct groups (space or comma separated)",
            Some("users"),
            true,
        )?;
        let groups = match parse_prompted_group_list(&value) {
            Ok(groups) => groups,
            Err(error) => {
                eprintln!("{}", error.human_message());
                continue;
            }
        };
        if !groups.is_empty() || prompt_confirm("Create with no direct groups?", false)? {
            return Ok(groups);
        }
    }
}

fn prompt_ttl_seconds() -> Result<u64, kanidm_admin::AppError> {
    loop {
        let value = prompt_input(
            "Password reset link lifetime in seconds",
            Some("3600"),
            false,
        )?;
        let parsed = match value.parse::<u64>() {
            Ok(parsed) => parsed,
            Err(error) => {
                eprintln!("invalid reset token TTL '{value}': {error}");
                continue;
            }
        };
        match validate_seconds_field(
            "reset token TTL",
            parsed,
            RESET_TOKEN_TTL_MIN_SECONDS,
            RESET_TOKEN_TTL_MAX_SECONDS,
        ) {
            Ok(value) => return Ok(value),
            Err(error) => eprintln!("{}", error.human_message()),
        }
    }
}

fn prompt_input(
    prompt: &str,
    default: Option<&str>,
    allow_empty: bool,
) -> Result<String, kanidm_admin::AppError> {
    let mut input = Input::<String>::new().with_prompt(prompt.to_string());
    if let Some(default) = default {
        input = input.with_initial_text(default.to_string());
    }
    input
        .allow_empty(allow_empty)
        .interact_text()
        .map(|value| value.trim().to_string())
        .map_err(|error| kanidm_admin::AppError::Config {
            message: format!("interactive input failed: {error}"),
        })
}

fn prompt_confirm(prompt: &str, default: bool) -> Result<bool, kanidm_admin::AppError> {
    Confirm::new()
        .with_prompt(prompt)
        .default(default)
        .interact()
        .map_err(|error| kanidm_admin::AppError::Config {
            message: format!("interactive confirmation failed: {error}"),
        })
}

fn confirm_create_new_user(
    options: &PromptedCreateNewUserOptions,
) -> Result<bool, kanidm_admin::AppError> {
    eprintln!(
        "New user review:\n  account id: {}\n  display name: {}\n  primary email: {}\n  direct groups: {}\n  clear validity restrictions: {}\n  create reset link: {}",
        options.account_id,
        options.display_name,
        options.email.as_deref().unwrap_or("-"),
        if options.groups.is_empty() {
            "-".to_string()
        } else {
            options.groups.join(", ")
        },
        yes_no(options.clear_validity),
        if options.create_reset_token {
            format!("yes, TTL {} seconds", options.reset_token_ttl_seconds)
        } else {
            "no".to_string()
        }
    );
    prompt_confirm("Create this user now?", false)
}

fn parse_prompted_group_list(value: &str) -> Result<Vec<String>, kanidm_admin::AppError> {
    let groups = value
        .split(|ch: char| ch == ',' || ch.is_whitespace())
        .filter_map(|group| {
            let trimmed = group.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_string())
        })
        .collect::<Vec<_>>();
    validate_identifier_list("group name", groups)
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}

fn recover_cli_session_interactively(
    kanidm: &KanidmCli,
    output: OutputFormat,
    target: RecoveryTarget,
    error: Option<&kanidm_admin::AppError>,
    snapshot: Option<&SessionSnapshot>,
    operation: &str,
) -> Result<bool, kanidm_admin::AppError> {
    if let Some(error) = error {
        eprintln!("{}", render_error(output, error));
    }

    match target {
        RecoveryTarget::BaseSession => {
            if let Some(snapshot) = snapshot {
                eprintln!(
                    "The delegated Kanidm session for '{}' is not ready for this action.\n\n{}",
                    kanidm.admin_name(),
                    snapshot.diagnostic_raw.trim()
                );
            }
            eprintln!("Starting Kanidm login before continuing {operation}.");
            let recovery = session_login(kanidm)?;
            eprintln!("{}", render_output(output, &recovery));
        }
        RecoveryTarget::PrivilegedWrites => {
            if let Some(snapshot) = snapshot {
                eprintln!(
                    "Privileged write access for '{}' is not ready.\n\n{}",
                    kanidm.admin_name(),
                    snapshot.diagnostic_raw.trim()
                );
            }
            eprintln!("Starting Kanidm reauthentication before continuing {operation}.");
            let recovery = session_reauth(kanidm)?;
            eprintln!("{}", render_output(output, &recovery));
        }
    }

    Ok(true)
}

fn run(
    cli: Cli,
    invocation_args: &[String],
) -> Result<Option<kanidm_admin::output::CommandOutput>, kanidm_admin::AppError> {
    let output = cli.output_format();
    let needs = cli.command_needs();
    let records_history = !matches!(&cli.command, Some(Commands::History(_)));
    if matches!(needs, CommandNeeds::None | CommandNeeds::HistoryOnly) {
        if cli.dry_run {
            let result = dry_run_context_free(&cli).map(Some);
            if records_history {
                record_operation_best_effort(invocation_args, &result);
            }
            return result;
        }
        let result = run_context_free(cli);
        if records_history {
            record_operation_best_effort(invocation_args, &result);
        }
        return result;
    }

    let context = resolve_context(ContextOverrides {
        repo_root: cli.repo_root.clone(),
        server_url: cli.server_url.clone(),
        admin_name: cli.admin_name.clone(),
        kanidm_bin: None,
        nix_bin: None,
        vaultwarden_url: None,
        vaultwarden_admin_token_file: None,
        backend_timeout_seconds: cli.backend_timeout_seconds,
    })?;
    if cli.dry_run {
        let result = dry_run_command(&cli, &context).map(Some);
        if records_history {
            record_operation_best_effort(invocation_args, &result);
        }
        return result;
    }
    let kanidm = KanidmCli::new(&context);
    kanidm.begin_backend_operation();

    let mut result = match cli.command {
        None => {
            if output != OutputFormat::Human {
                return Err(kanidm_admin::AppError::Config {
                    message: "interactive mode only supports --output human".to_string(),
                });
            }
            interactive::run(&context, &kanidm)?;
            Ok(None)
        }
        Some(Commands::Doctor(command)) => doctor(&context, &kanidm, command.deep).map(Some),
        Some(Commands::Context(command)) => match command.command {
            ContextSubcommand::Show => Ok(Some(show_context(&context))),
        },
        Some(Commands::Session(command)) => match command.command {
            SessionSubcommand::Status => session_status(&kanidm).map(Some),
            SessionSubcommand::Diagnose => session_diagnose(&kanidm).map(Some),
            SessionSubcommand::Login => {
                ensure_interactive_session_allowed(output)?;
                session_login(&kanidm).map(Some)
            }
            SessionSubcommand::Reauth => {
                ensure_interactive_session_allowed(output)?;
                session_reauth(&kanidm).map(Some)
            }
            SessionSubcommand::Logout => session_logout(&kanidm).map(Some),
        },
        Some(Commands::User(command)) => match command.command {
            UserSubcommand::List => list_users(&kanidm).map(Some),
            UserSubcommand::Show { account_id } => {
                let account_id = validate_account_id(&account_id)?;
                show_user(&kanidm, &account_id).map(Some)
            }
            UserSubcommand::Create {
                account_id,
                display_name,
                email,
                preserve_validity,
            } => {
                let account_id = validate_account_id(&account_id)?;
                let display_name = validate_display_name(&display_name)?;
                let email = email.as_deref().map(validate_email).transpose()?;
                create_user(
                    &kanidm,
                    CreateUserOptions {
                        account_id,
                        display_name,
                        email,
                        clear_validity: !preserve_validity,
                    },
                )
                .map(Some)
            }
            UserSubcommand::CreateNew => {
                create_new_user_interactive(&kanidm, &context.sftp_runtime, output).map(Some)
            }
            UserSubcommand::Disable { account_id } => {
                let account_id = validate_account_id(&account_id)?;
                disable_user(&kanidm, &account_id).map(Some)
            }
            UserSubcommand::Enable { account_id } => {
                let account_id = validate_account_id(&account_id)?;
                enable_user(&kanidm, &account_id).map(Some)
            }
            UserSubcommand::Delete {
                account_id,
                confirm,
            } => {
                let account_id = validate_account_id(&account_id)?;
                delete_user(
                    &kanidm,
                    DeleteUserOptions {
                        account_id,
                        confirm,
                    },
                )
                .map(Some)
            }
            UserSubcommand::ResetToken { account_id, ttl } => {
                let account_id = validate_account_id(&account_id)?;
                let ttl = validate_seconds_field(
                    "reset token TTL",
                    ttl,
                    RESET_TOKEN_TTL_MIN_SECONDS,
                    RESET_TOKEN_TTL_MAX_SECONDS,
                )?;
                reset_token(
                    &kanidm,
                    ResetTokenOptions {
                        account_id,
                        ttl_seconds: ttl,
                    },
                )
                .map(Some)
            }
        },
        Some(Commands::Group(command)) => match command.command {
            GroupSubcommand::List => list_groups(&kanidm).map(Some),
            GroupSubcommand::Search { query } => {
                let query = validate_search_query(&query)?;
                search_groups(&kanidm, &query).map(Some)
            }
            GroupSubcommand::Show { group } => {
                let group = validate_identifier_field("group name", &group)?;
                show_group(&kanidm, &group).map(Some)
            }
            GroupSubcommand::Members { group } => {
                let group = validate_identifier_field("group name", &group)?;
                group_members(&kanidm, &group).map(Some)
            }
        },
        Some(Commands::Membership(command)) => match command.command {
            MembershipSubcommand::Show { account_id } => {
                let account_id = validate_account_id(&account_id)?;
                show_membership(&kanidm, &account_id).map(Some)
            }
            MembershipSubcommand::Add { account_id, groups } => {
                let account_id = validate_account_id(&account_id)?;
                let groups = validate_identifier_list("group name", groups)?;
                add_membership_with_config(&kanidm, &context.sftp_runtime, &account_id, &groups)
                    .map(Some)
            }
            MembershipSubcommand::Remove { account_id, groups } => {
                let account_id = validate_account_id(&account_id)?;
                let groups = validate_identifier_list("group name", groups)?;
                remove_membership_with_config(&kanidm, &context.sftp_runtime, &account_id, &groups)
                    .map(Some)
            }
            MembershipSubcommand::Set {
                account_id,
                groups,
                allow_empty,
                confirm_empty,
            } => {
                let account_id = validate_account_id(&account_id)?;
                let groups = validate_identifier_list("group name", groups)?;
                if groups.is_empty() && allow_empty {
                    require_exact_confirmation(
                        "setting direct memberships to an empty set",
                        &account_id,
                        "--confirm-empty",
                        confirm_empty.as_deref(),
                    )?;
                }
                set_membership_with_config(
                    &kanidm,
                    &context.sftp_runtime,
                    SetMembershipOptions {
                        account_id,
                        groups,
                        preserve_groups: Vec::new(),
                        allow_empty,
                    },
                )
                .map(Some)
            }
        },
        Some(Commands::Client(command)) => match command.command {
            ClientSubcommand::List => list_clients(&kanidm).map(Some),
            ClientSubcommand::Show { client } => {
                let client = validate_identifier_field("oauth2 client name", &client)?;
                show_client(&kanidm, &client).map(Some)
            }
            ClientSubcommand::Secret(secret) => match secret.command {
                ClientSecretSubcommand::Show {
                    client,
                    confirm_reveal_secret,
                } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    require_exact_confirmation(
                        "revealing an OAuth2 client secret",
                        &client,
                        "--confirm-reveal-secret",
                        confirm_reveal_secret.as_deref(),
                    )?;
                    client_secret_show(&kanidm, &client).map(Some)
                }
                ClientSecretSubcommand::Reset {
                    client,
                    confirm_rotate_secret,
                } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    require_exact_confirmation(
                        "rotating an OAuth2 client secret",
                        &client,
                        "--confirm-rotate-secret",
                        confirm_rotate_secret.as_deref(),
                    )?;
                    client_secret_reset(&kanidm, &client).map(Some)
                }
            },
            ClientSubcommand::Redirect(redirect) => match redirect.command {
                ClientRedirectSubcommand::Add { client, url } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    let url = validate_redirect_url_for_server(&url, kanidm.server_url())?;
                    client_redirect_add(&kanidm, &client, &url).map(Some)
                }
                ClientRedirectSubcommand::Remove { client, url } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    let url = validate_redirect_url_for_server(&url, kanidm.server_url())?;
                    client_redirect_remove(&kanidm, &client, &url).map(Some)
                }
            },
            ClientSubcommand::Pkce(pkce) => match pkce.command {
                ClientPkceSubcommand::Enable { client } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    client_pkce_enable(&kanidm, &client).map(Some)
                }
                ClientPkceSubcommand::Disable {
                    client,
                    confirm_insecure_pkce_disable,
                } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    require_exact_confirmation(
                        "disabling PKCE",
                        &client,
                        "--confirm-insecure-pkce-disable",
                        confirm_insecure_pkce_disable.as_deref(),
                    )?;
                    client_pkce_disable(&kanidm, &client).map(Some)
                }
            },
            ClientSubcommand::Consent(consent) => match consent.command {
                ClientConsentSubcommand::Enable { client } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    client_consent_enable(&kanidm, &client).map(Some)
                }
                ClientConsentSubcommand::Disable {
                    client,
                    confirm_disable_consent,
                } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    require_exact_confirmation(
                        "disabling consent prompts",
                        &client,
                        "--confirm-disable-consent",
                        confirm_disable_consent.as_deref(),
                    )?;
                    client_consent_disable(&kanidm, &client).map(Some)
                }
            },
        },
        Some(Commands::Policy(command)) => match command.command {
            PolicySubcommand::Group(group) => match group.command {
                PolicyGroupSubcommand::Show { group } => {
                    let group = validate_identifier_field("group name", &group)?;
                    show_group_policy(&kanidm, &group).map(Some)
                }
                PolicyGroupSubcommand::AuthExpiry(policy) => match policy.command {
                    PolicyValueSubcommand::Set { group, seconds } => {
                        let group = validate_identifier_field("group name", &group)?;
                        let seconds = validate_seconds_field(
                            "auth expiry",
                            seconds,
                            AUTH_EXPIRY_MIN_SECONDS,
                            AUTH_EXPIRY_MAX_SECONDS,
                        )?;
                        set_group_auth_expiry(&kanidm, &group, seconds).map(Some)
                    }
                    PolicyValueSubcommand::Reset { group } => {
                        let group = validate_identifier_field("group name", &group)?;
                        reset_group_auth_expiry(&kanidm, &group).map(Some)
                    }
                },
                PolicyGroupSubcommand::PrivilegeExpiry(policy) => match policy.command {
                    PolicyValueSubcommand::Set { group, seconds } => {
                        let group = validate_identifier_field("group name", &group)?;
                        let seconds = validate_seconds_field(
                            "privilege expiry",
                            seconds,
                            PRIVILEGE_EXPIRY_MIN_SECONDS,
                            PRIVILEGE_EXPIRY_MAX_SECONDS,
                        )?;
                        set_group_privilege_expiry(&kanidm, &group, seconds).map(Some)
                    }
                    PolicyValueSubcommand::Reset { group } => {
                        let group = validate_identifier_field("group name", &group)?;
                        reset_group_privilege_expiry(&kanidm, &group).map(Some)
                    }
                },
            },
        },
        Some(Commands::Local(command)) => match command.command {
            LocalSubcommand::JellyfinPassword(command) => match command.command {
                LocalJellyfinPasswordSubcommand::Stage {
                    account_id,
                    password_env,
                } => {
                    let account_id = validate_account_id(&account_id)?;
                    stage_jellyfin_password(&account_id, &password_env).map(Some)
                }
                LocalJellyfinPasswordSubcommand::Diagnose { account_id } => {
                    let account_id = validate_account_id(&account_id)?;
                    diagnose_jellyfin_password(&kanidm, &account_id).map(Some)
                }
                LocalJellyfinPasswordSubcommand::Reconcile { account_id } => {
                    let account_id = validate_account_id(&account_id)?;
                    reconcile_jellyfin_password(&kanidm, &account_id).map(Some)
                }
                LocalJellyfinPasswordSubcommand::Test { account_id } => {
                    let account_id = validate_account_id(&account_id)?;
                    test_jellyfin_password(&kanidm, &account_id).map(Some)
                }
            },
            LocalSubcommand::Sftp(command) => match command.command {
                LocalSftpSubcommand::Diagnose {
                    account_id,
                    runtime,
                } => {
                    let account_id = validate_account_id(&account_id)?;
                    diagnose_sftp_login_with_policy(
                        &kanidm,
                        &context.sftp_runtime,
                        &account_id,
                        convergence_policy_from_cli(&runtime)?,
                    )
                    .map(Some)
                }
                LocalSftpSubcommand::Reconcile {
                    account_id,
                    runtime,
                } => {
                    let account_id = validate_account_id(&account_id)?;
                    reconcile_sftp_login_with_policy(
                        &kanidm,
                        &context.sftp_runtime,
                        &account_id,
                        convergence_policy_from_cli(&runtime)?,
                    )
                    .map(Some)
                }
                LocalSftpSubcommand::Test {
                    account_id,
                    runtime,
                } => {
                    let account_id = validate_account_id(&account_id)?;
                    test_sftp_login_with_policy(
                        &kanidm,
                        &context.sftp_runtime,
                        &account_id,
                        convergence_policy_from_cli(&runtime)?,
                    )
                    .map(Some)
                }
            },
            LocalSubcommand::Vaultwarden(command) => match command.command {
                LocalVaultwardenSubcommand::Invite { account_id } => {
                    let account_id = validate_account_id(&account_id)?;
                    invite_vaultwarden_user(&context, &kanidm, &account_id).map(Some)
                }
                LocalVaultwardenSubcommand::Diagnose { account_id } => {
                    let account_id = validate_account_id(&account_id)?;
                    diagnose_vaultwarden_user(&context, &kanidm, &account_id).map(Some)
                }
                LocalVaultwardenSubcommand::Reconcile { account_id } => {
                    let account_id = validate_account_id(&account_id)?;
                    reconcile_vaultwarden_user(&context, &kanidm, &account_id).map(Some)
                }
            },
        },
        Some(Commands::History(command)) => match command.command {
            HistorySubcommand::List => list_history().map(Some),
            HistorySubcommand::Show { operation_id } => show_history(&operation_id).map(Some),
            HistorySubcommand::Resume { operation_id } => resume_history(&operation_id).map(Some),
            HistorySubcommand::Prune { older_than } => prune_history(&older_than).map(Some),
            HistorySubcommand::RedactSensitive => redact_sensitive_history().map(Some),
        },
    };
    match &mut result {
        Ok(Some(output)) => attach_backend_steps(&kanidm, output),
        Ok(None) => {
            let _ = kanidm.take_backend_steps();
        }
        Err(error) => attach_backend_steps_to_error(&kanidm, error),
    }
    if records_history {
        record_operation_best_effort(invocation_args, &result);
    }
    result
}

fn run_context_free(
    cli: Cli,
) -> Result<Option<kanidm_admin::output::CommandOutput>, kanidm_admin::AppError> {
    match cli.command {
        Some(Commands::History(command)) => match command.command {
            HistorySubcommand::List => list_history().map(Some),
            HistorySubcommand::Show { operation_id } => show_history(&operation_id).map(Some),
            HistorySubcommand::Resume { operation_id } => resume_history(&operation_id).map(Some),
            HistorySubcommand::Prune { older_than } => prune_history(&older_than).map(Some),
            HistorySubcommand::RedactSensitive => redact_sensitive_history().map(Some),
        },
        Some(Commands::Local(LocalCommand {
            command:
                LocalSubcommand::JellyfinPassword(LocalJellyfinPasswordCommand {
                    command:
                        LocalJellyfinPasswordSubcommand::Stage {
                            account_id,
                            password_env,
                        },
                }),
        })) => {
            let account_id = validate_account_id(&account_id)?;
            stage_jellyfin_password(&account_id, &password_env).map(Some)
        }
        _ => Err(kanidm_admin::AppError::Config {
            message: "command cannot run without resolved Kanidm context".to_string(),
        }),
    }
}

fn dry_run_context_free(cli: &Cli) -> Result<CommandOutput, kanidm_admin::AppError> {
    match &cli.command {
        Some(Commands::Local(LocalCommand {
            command:
                LocalSubcommand::JellyfinPassword(LocalJellyfinPasswordCommand {
                    command:
                        LocalJellyfinPasswordSubcommand::Stage {
                            account_id,
                            password_env,
                        },
                }),
        })) => {
            let account_id = validate_account_id(account_id)?;
            Ok(dry_run_output(
                "local.jellyfin_password.stage",
                &account_id,
                format!(
                    "Would stage a Jellyfin password hash for '{account_id}' from environment variable '{password_env}'."
                ),
                json!({
                    "account_id": account_id,
                    "password_env": password_env,
                    "would_read_secret_env": true,
                    "would_write_hash_file": true,
                }),
                Vec::new(),
            ))
        }
        _ => dry_run_not_supported(),
    }
}

fn dry_run_command(
    cli: &Cli,
    context: &ResolvedContext,
) -> Result<CommandOutput, kanidm_admin::AppError> {
    let Some(command) = &cli.command else {
        return Err(kanidm_admin::AppError::Config {
            message: "interactive mode does not support --dry-run".to_string(),
        });
    };

    match command {
        Commands::Session(SessionCommand {
            command: SessionSubcommand::Logout,
        }) => Ok(dry_run_output(
            "session.logout",
            &context.admin_name,
            format!(
                "Would log out the Kanidm CLI session for '{}'.",
                context.admin_name
            ),
            json!({ "admin_name": context.admin_name, "server_url": context.server_url }),
            Vec::new(),
        )),
        Commands::User(command) => match &command.command {
            UserSubcommand::Create {
                account_id,
                display_name,
                email,
                preserve_validity,
            } => {
                let account_id = validate_account_id(account_id)?;
                let display_name = validate_display_name(display_name)?;
                let email = email.as_deref().map(validate_email).transpose()?;
                Ok(dry_run_output(
                    "user.create",
                    &account_id,
                    format!("Would create Kanidm user '{account_id}'."),
                    json!({
                        "account_id": account_id,
                        "display_name": display_name,
                        "email": email,
                        "clear_validity": !preserve_validity,
                    }),
                    Vec::new(),
                ))
            }
            UserSubcommand::CreateNew => Err(kanidm_admin::AppError::Config {
                message: "user create-new is interactive and does not support --dry-run"
                    .to_string(),
            }),
            UserSubcommand::Disable { account_id } => {
                let account_id = validate_account_id(account_id)?;
                Ok(dry_run_output(
                    "user.disable",
                    &account_id,
                    format!("Would disable Kanidm user '{account_id}'."),
                    json!({ "account_id": account_id, "expiry": "set" }),
                    Vec::new(),
                ))
            }
            UserSubcommand::Enable { account_id } => {
                let account_id = validate_account_id(account_id)?;
                Ok(dry_run_output(
                    "user.enable",
                    &account_id,
                    format!("Would re-enable Kanidm user '{account_id}'."),
                    json!({ "account_id": account_id, "valid_from": null, "expiry": null }),
                    Vec::new(),
                ))
            }
            UserSubcommand::Delete {
                account_id,
                confirm: _,
            } => {
                let account_id = validate_account_id(account_id)?;
                Ok(dry_run_output(
                    "user.delete",
                    &account_id,
                    format!("Would permanently delete Kanidm user '{account_id}'."),
                    json!({ "account_id": account_id, "deleted": true }),
                    vec![format!("--confirm {account_id}")],
                ))
            }
            UserSubcommand::ResetToken { account_id, ttl } => {
                let account_id = validate_account_id(account_id)?;
                let ttl = validate_seconds_field(
                    "reset token TTL",
                    *ttl,
                    RESET_TOKEN_TTL_MIN_SECONDS,
                    RESET_TOKEN_TTL_MAX_SECONDS,
                )?;
                Ok(dry_run_output(
                    "user.reset_token",
                    &account_id,
                    format!("Would create a temporary password reset link for '{account_id}'."),
                    json!({ "account_id": account_id, "ttl_seconds": ttl, "would_emit_secret": true }),
                    Vec::new(),
                ))
            }
            _ => dry_run_not_supported(),
        },
        Commands::Membership(command) => match &command.command {
            MembershipSubcommand::Add { account_id, groups } => {
                let account_id = validate_account_id(account_id)?;
                let groups = validate_identifier_list("group name", groups.clone())?;
                if groups.is_empty() {
                    return Err(kanidm_admin::AppError::Config {
                        message: format!(
                            "adding memberships for '{account_id}' requires at least one group name"
                        ),
                    });
                }
                Ok(dry_run_output(
                    "membership.add",
                    &account_id,
                    format!("Would add direct memberships to '{account_id}'."),
                    json!({ "account_id": account_id, "groups": groups }),
                    Vec::new(),
                ))
            }
            MembershipSubcommand::Remove { account_id, groups } => {
                let account_id = validate_account_id(account_id)?;
                let groups = validate_identifier_list("group name", groups.clone())?;
                if groups.is_empty() {
                    return Err(kanidm_admin::AppError::Config {
                        message: format!(
                            "removing memberships for '{account_id}' requires at least one group name"
                        ),
                    });
                }
                Ok(dry_run_output(
                    "membership.remove",
                    &account_id,
                    format!("Would remove direct memberships from '{account_id}'."),
                    json!({ "account_id": account_id, "groups": groups }),
                    Vec::new(),
                ))
            }
            MembershipSubcommand::Set {
                account_id,
                groups,
                allow_empty,
                confirm_empty: _,
            } => {
                let account_id = validate_account_id(account_id)?;
                let groups = validate_identifier_list("group name", groups.clone())?;
                if groups.is_empty() && !allow_empty {
                    return Err(kanidm_admin::AppError::Config {
                        message: format!(
                            "setting direct memberships for '{account_id}' to an empty set requires --allow-empty"
                        ),
                    });
                }
                let confirmations = if groups.is_empty() {
                    vec![format!("--confirm-empty {account_id}")]
                } else {
                    Vec::new()
                };
                Ok(dry_run_output(
                    "membership.set",
                    &account_id,
                    format!("Would replace direct memberships for '{account_id}'."),
                    json!({ "account_id": account_id, "groups": groups, "allow_empty": allow_empty }),
                    confirmations,
                ))
            }
            MembershipSubcommand::Show { .. } => dry_run_not_supported(),
        },
        Commands::Client(command) => match &command.command {
            ClientSubcommand::Secret(ClientSecretCommand {
                command:
                    ClientSecretSubcommand::Reset {
                        client,
                        confirm_rotate_secret: _,
                    },
            }) => {
                let client = validate_identifier_field("oauth2 client name", client)?;
                Ok(dry_run_output(
                    "client.secret.reset",
                    &client,
                    format!("Would rotate the OAuth2 client secret for '{client}'."),
                    json!({ "client": client, "would_emit_secret": true }),
                    vec![format!("--confirm-rotate-secret {client}")],
                ))
            }
            ClientSubcommand::Redirect(ClientRedirectCommand {
                command: ClientRedirectSubcommand::Add { client, url },
            }) => {
                let client = validate_identifier_field("oauth2 client name", client)?;
                let url = validate_redirect_url_for_server(url, &context.server_url)?;
                Ok(dry_run_output(
                    "client.redirect.add",
                    &client,
                    format!("Would add an OAuth2 redirect URL to '{client}'."),
                    json!({ "client": client, "redirect_url": url }),
                    Vec::new(),
                ))
            }
            ClientSubcommand::Redirect(ClientRedirectCommand {
                command: ClientRedirectSubcommand::Remove { client, url },
            }) => {
                let client = validate_identifier_field("oauth2 client name", client)?;
                let url = validate_redirect_url_for_server(url, &context.server_url)?;
                Ok(dry_run_output(
                    "client.redirect.remove",
                    &client,
                    format!("Would remove an OAuth2 redirect URL from '{client}'."),
                    json!({ "client": client, "redirect_url": url }),
                    Vec::new(),
                ))
            }
            ClientSubcommand::Pkce(ClientPkceCommand {
                command: ClientPkceSubcommand::Enable { client },
            }) => {
                let client = validate_identifier_field("oauth2 client name", client)?;
                Ok(dry_run_output(
                    "client.pkce.enable",
                    &client,
                    format!("Would require PKCE for OAuth2 client '{client}'."),
                    json!({ "client": client, "pkce_enabled": true }),
                    Vec::new(),
                ))
            }
            ClientSubcommand::Pkce(ClientPkceCommand {
                command:
                    ClientPkceSubcommand::Disable {
                        client,
                        confirm_insecure_pkce_disable: _,
                    },
            }) => {
                let client = validate_identifier_field("oauth2 client name", client)?;
                Ok(dry_run_output(
                    "client.pkce.disable",
                    &client,
                    format!("Would disable PKCE for OAuth2 client '{client}'."),
                    json!({ "client": client, "pkce_enabled": false }),
                    vec![format!("--confirm-insecure-pkce-disable {client}")],
                ))
            }
            ClientSubcommand::Consent(ClientConsentCommand {
                command: ClientConsentSubcommand::Enable { client },
            }) => {
                let client = validate_identifier_field("oauth2 client name", client)?;
                Ok(dry_run_output(
                    "client.consent.enable",
                    &client,
                    format!("Would require consent prompts for OAuth2 client '{client}'."),
                    json!({ "client": client, "consent_prompt_enabled": true }),
                    Vec::new(),
                ))
            }
            ClientSubcommand::Consent(ClientConsentCommand {
                command:
                    ClientConsentSubcommand::Disable {
                        client,
                        confirm_disable_consent: _,
                    },
            }) => {
                let client = validate_identifier_field("oauth2 client name", client)?;
                Ok(dry_run_output(
                    "client.consent.disable",
                    &client,
                    format!("Would disable consent prompts for OAuth2 client '{client}'."),
                    json!({ "client": client, "consent_prompt_enabled": false }),
                    vec![format!("--confirm-disable-consent {client}")],
                ))
            }
            _ => dry_run_not_supported(),
        },
        Commands::Policy(command) => match &command.command {
            PolicySubcommand::Group(group) => match &group.command {
                PolicyGroupSubcommand::AuthExpiry(PolicyValueCommand {
                    command: PolicyValueSubcommand::Set { group, seconds },
                }) => {
                    let group = validate_identifier_field("group name", group)?;
                    let seconds = validate_seconds_field(
                        "auth expiry",
                        *seconds,
                        AUTH_EXPIRY_MIN_SECONDS,
                        AUTH_EXPIRY_MAX_SECONDS,
                    )?;
                    Ok(dry_run_output(
                        "policy.group.auth_expiry.set",
                        &group,
                        format!("Would set auth-expiry for group '{group}'."),
                        json!({ "group": group, "auth_expiry_seconds": seconds }),
                        Vec::new(),
                    ))
                }
                PolicyGroupSubcommand::AuthExpiry(PolicyValueCommand {
                    command: PolicyValueSubcommand::Reset { group },
                }) => {
                    let group = validate_identifier_field("group name", group)?;
                    Ok(dry_run_output(
                        "policy.group.auth_expiry.reset",
                        &group,
                        format!("Would reset auth-expiry for group '{group}'."),
                        json!({ "group": group, "auth_expiry_seconds": null }),
                        Vec::new(),
                    ))
                }
                PolicyGroupSubcommand::PrivilegeExpiry(PolicyValueCommand {
                    command: PolicyValueSubcommand::Set { group, seconds },
                }) => {
                    let group = validate_identifier_field("group name", group)?;
                    let seconds = validate_seconds_field(
                        "privilege expiry",
                        *seconds,
                        PRIVILEGE_EXPIRY_MIN_SECONDS,
                        PRIVILEGE_EXPIRY_MAX_SECONDS,
                    )?;
                    Ok(dry_run_output(
                        "policy.group.privilege_expiry.set",
                        &group,
                        format!("Would set privilege-expiry for group '{group}'."),
                        json!({ "group": group, "privilege_expiry_seconds": seconds }),
                        Vec::new(),
                    ))
                }
                PolicyGroupSubcommand::PrivilegeExpiry(PolicyValueCommand {
                    command: PolicyValueSubcommand::Reset { group },
                }) => {
                    let group = validate_identifier_field("group name", group)?;
                    Ok(dry_run_output(
                        "policy.group.privilege_expiry.reset",
                        &group,
                        format!("Would reset privilege-expiry for group '{group}'."),
                        json!({ "group": group, "privilege_expiry_seconds": null }),
                        Vec::new(),
                    ))
                }
                PolicyGroupSubcommand::Show { .. } => dry_run_not_supported(),
            },
        },
        Commands::Local(command) => match &command.command {
            LocalSubcommand::JellyfinPassword(LocalJellyfinPasswordCommand {
                command: LocalJellyfinPasswordSubcommand::Reconcile { account_id },
            }) => {
                let account_id = validate_account_id(account_id)?;
                Ok(dry_run_output(
                    "local.jellyfin_password.reconcile",
                    &account_id,
                    format!("Would start Jellyfin password reconciliation for '{account_id}'."),
                    json!({ "account_id": account_id, "would_start_systemd_unit": "jellyfin-password-reconcile.service" }),
                    Vec::new(),
                ))
            }
            LocalSubcommand::Sftp(LocalSftpCommand {
                command:
                    LocalSftpSubcommand::Reconcile {
                        account_id,
                        runtime,
                    },
            }) => {
                let account_id = validate_account_id(account_id)?;
                let policy = convergence_policy_from_cli(runtime)?;
                Ok(dry_run_output(
                    "local.sftp.reconcile",
                    &account_id,
                    format!("Would start local SFTP sync services for '{account_id}'."),
                    json!({
                        "account_id": account_id,
                        "would_start_units": [
                            context.sftp_runtime.posix_groups_service,
                            context.sftp_runtime.user_root_sync_service,
                        ],
                        "runtime_timeout_seconds": policy.timeout.as_secs(),
                        "runtime_interval_milliseconds": policy.interval.as_millis(),
                    }),
                    Vec::new(),
                ))
            }
            LocalSubcommand::Vaultwarden(LocalVaultwardenCommand {
                command: LocalVaultwardenSubcommand::Invite { account_id },
            })
            | LocalSubcommand::Vaultwarden(LocalVaultwardenCommand {
                command: LocalVaultwardenSubcommand::Reconcile { account_id },
            }) => {
                let account_id = validate_account_id(account_id)?;
                Ok(dry_run_output(
                    "local.vaultwarden.invite_or_reconcile",
                    &account_id,
                    format!("Would inspect and possibly invite Vaultwarden user '{account_id}'."),
                    json!({
                        "account_id": account_id,
                        "vaultwarden_url": context.vaultwarden_url,
                        "vaultwarden_admin_token_file": context.vaultwarden_admin_token_file,
                        "would_read_admin_token": true,
                        "would_call_vaultwarden_admin": true,
                    }),
                    Vec::new(),
                ))
            }
            _ => dry_run_not_supported(),
        },
        Commands::Doctor(_)
        | Commands::Context(_)
        | Commands::Group(_)
        | Commands::History(_)
        | Commands::Session(_) => dry_run_not_supported(),
    }
}

fn dry_run_output(
    action: &str,
    target: &str,
    human: String,
    planned_state: serde_json::Value,
    confirmations_required_to_execute: Vec<String>,
) -> CommandOutput {
    let mut rendered = format!("Dry run: {human}\nNo changes were applied.");
    if !confirmations_required_to_execute.is_empty() {
        rendered.push_str("\n\nRequired confirmation flag(s) when executing:\n");
        rendered.push_str(
            &confirmations_required_to_execute
                .iter()
                .map(|flag| format!("- {flag}"))
                .collect::<Vec<_>>()
                .join("\n"),
        );
    }

    CommandOutput {
        message: format!("dry run for {action}"),
        human: rendered,
        details: json!({
            "dry_run": true,
            "action": action,
            "target": target,
            "planned_state": planned_state,
            "confirmations_required_to_execute": confirmations_required_to_execute,
        }),
        warnings: Vec::new(),
    }
}

fn dry_run_not_supported<T>() -> Result<T, kanidm_admin::AppError> {
    Err(kanidm_admin::AppError::Unsupported {
        message: "--dry-run is only supported for commands that would change Kanidm or local application state".to_string(),
        details: json!({ "dry_run": true }),
    })
}

fn convergence_policy_from_cli(
    options: &RuntimeCliOptions,
) -> Result<ConvergencePolicy, kanidm_admin::AppError> {
    let timeout = options.timeout.unwrap_or(30);
    let interval = options.interval.unwrap_or(500);
    if timeout > 300 {
        return Err(kanidm_admin::AppError::Config {
            message: "runtime convergence timeout must be 300 seconds or less".to_string(),
        });
    }
    if interval == 0 || interval > 60_000 {
        return Err(kanidm_admin::AppError::Config {
            message: "runtime convergence interval must be between 1 and 60000 milliseconds"
                .to_string(),
        });
    }

    Ok(ConvergencePolicy {
        timeout: Duration::from_secs(timeout),
        interval: Duration::from_millis(interval),
        stable_successes_required: 1,
    })
}

fn attach_backend_steps(kanidm: &KanidmCli, output: &mut kanidm_admin::output::CommandOutput) {
    let steps = kanidm.take_backend_steps();
    if steps.is_empty() {
        return;
    }
    if let Some(details) = output.details.as_object_mut() {
        details
            .entry("backend_steps")
            .or_insert_with(|| serde_json::Value::Array(steps));
    }
}

fn attach_backend_steps_to_error(kanidm: &KanidmCli, error: &mut kanidm_admin::AppError) {
    let steps = kanidm.take_backend_steps();
    if steps.is_empty() {
        return;
    }
    let steps = serde_json::Value::Array(steps);
    match error {
        kanidm_admin::AppError::NotFound { details, .. }
        | kanidm_admin::AppError::AlreadyExists { details, .. }
        | kanidm_admin::AppError::Verification { details, .. }
        | kanidm_admin::AppError::PartialSuccess { details, .. }
        | kanidm_admin::AppError::SessionRequired { details, .. }
        | kanidm_admin::AppError::ReauthRequired { details, .. }
        | kanidm_admin::AppError::Json { details, .. }
        | kanidm_admin::AppError::BackendTimeout { details, .. }
        | kanidm_admin::AppError::InventoryIncomplete { details, .. }
        | kanidm_admin::AppError::Unsupported { details, .. } => {
            if let Some(object) = details.as_object_mut() {
                object.entry("backend_steps").or_insert_with(|| steps);
            }
        }
        _ => {}
    }
}

fn validate_identifier_list(
    field_name: &str,
    values: Vec<String>,
) -> Result<Vec<String>, kanidm_admin::AppError> {
    values
        .into_iter()
        .map(|value| validate_identifier_field(field_name, &value))
        .collect()
}

fn require_exact_confirmation(
    action: &str,
    target: &str,
    flag: &str,
    provided: Option<&str>,
) -> Result<(), kanidm_admin::AppError> {
    if provided == Some(target) {
        Ok(())
    } else {
        Err(kanidm_admin::AppError::Config {
            message: format!(
                "{action} for '{target}' requires {flag} {target}; confirmation was not provided.\n\nWhat to enter:\n- Re-run with `{flag} {target}`.\n\nWhy this is required:\n- This action can reveal, rotate, remove, or weaken access controls, so the target name must be repeated exactly."
            ),
        })
    }
}

#[cfg(test)]
mod tests {
    use clap::{CommandFactory, Parser};

    use super::*;

    fn render_help(mut command: clap::Command) -> String {
        let mut buffer = Vec::new();
        command.write_long_help(&mut buffer).expect("write help");
        String::from_utf8(buffer).expect("utf8 help")
    }

    #[test]
    fn parses_default_tui_without_subcommand() {
        let cli = Cli::try_parse_from(["kanidm-admin"]).expect("parse");
        assert!(cli.command.is_none());
    }

    #[test]
    fn parses_doctor_deep() {
        let cli = Cli::try_parse_from(["kanidm-admin", "doctor", "--deep"]).expect("parse");
        assert!(matches!(
            cli.command,
            Some(Commands::Doctor(DoctorCommand { deep: true }))
        ));
    }

    #[test]
    fn parses_session_login() {
        let cli = Cli::try_parse_from(["kanidm-admin", "session", "login"]).expect("parse");
        assert!(matches!(
            cli.command,
            Some(Commands::Session(SessionCommand {
                command: SessionSubcommand::Login
            }))
        ));
    }

    #[test]
    fn parses_session_diagnose() {
        let cli = Cli::try_parse_from(["kanidm-admin", "session", "diagnose"]).expect("parse");
        assert!(matches!(
            cli.command,
            Some(Commands::Session(SessionCommand {
                command: SessionSubcommand::Diagnose
            }))
        ));
    }

    #[test]
    fn parses_membership_set() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "membership",
            "set",
            "dsaw",
            "users",
            "paperless-users",
            "--allow-empty",
        ])
        .expect("parse");

        assert!(matches!(
            cli.command,
            Some(Commands::Membership(MembershipCommand {
                command: MembershipSubcommand::Set {
                    account_id,
                    groups,
                    allow_empty: true,
                    confirm_empty: None
                }
            })) if account_id == "dsaw" && groups == vec!["users".to_string(), "paperless-users".to_string()]
        ));
    }

    #[test]
    fn parses_user_create_with_preserve_validity() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "user",
            "create",
            "alice",
            "--display-name",
            "Alice",
            "--preserve-validity",
        ])
        .expect("parse");

        assert!(matches!(
            cli.command,
            Some(Commands::User(UserCommand {
                command: UserSubcommand::Create {
                    account_id,
                    display_name,
                    email: None,
                    preserve_validity: true,
                }
            })) if account_id == "alice" && display_name == "Alice"
        ));
    }

    #[test]
    fn parses_user_create_new_alias() {
        let cli = Cli::try_parse_from(["kanidm-admin", "user", "new"]).expect("parse");

        assert!(matches!(
            cli.command,
            Some(Commands::User(UserCommand {
                command: UserSubcommand::CreateNew
            }))
        ));
    }

    #[test]
    fn parse_prompted_group_list_accepts_commas_and_spaces() {
        let groups = parse_prompted_group_list("users, user-files files-sftp-users")
            .expect("groups should parse");

        assert_eq!(
            groups,
            vec![
                "users".to_string(),
                "user-files".to_string(),
                "files-sftp-users".to_string()
            ]
        );
    }

    #[test]
    fn parses_client_pkce_disable() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "client",
            "pkce",
            "disable",
            "files",
            "--confirm-insecure-pkce-disable",
            "files",
        ])
        .expect("parse");

        assert!(matches!(
            cli.command,
            Some(Commands::Client(ClientCommand {
                command: ClientSubcommand::Pkce(ClientPkceCommand {
                    command: ClientPkceSubcommand::Disable {
                        client,
                        confirm_insecure_pkce_disable: Some(confirm)
                    }
                })
            })) if client == "files" && confirm == "files"
        ));
    }

    #[test]
    fn parses_policy_privilege_expiry_reset() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "policy",
            "group",
            "privilege-expiry",
            "reset",
            "idm_all_persons",
        ])
        .expect("parse");

        assert!(matches!(
            cli.command,
            Some(Commands::Policy(PolicyCommand {
                command: PolicySubcommand::Group(PolicyGroupCommand {
                    command: PolicyGroupSubcommand::PrivilegeExpiry(PolicyValueCommand {
                        command: PolicyValueSubcommand::Reset { group }
                    })
                })
            })) if group == "idm_all_persons"
        ));
    }

    #[test]
    fn parses_local_jellyfin_stage() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "local",
            "jellyfin-password",
            "stage",
            "dsaw",
            "--password-env",
            "CUSTOM_PASSWORD",
        ])
        .expect("parse");

        assert!(matches!(
            cli.command,
            Some(Commands::Local(LocalCommand {
                command: LocalSubcommand::JellyfinPassword(LocalJellyfinPasswordCommand {
                    command: LocalJellyfinPasswordSubcommand::Stage {
                        account_id,
                        password_env
                    }
                })
            })) if account_id == "dsaw" && password_env == "CUSTOM_PASSWORD"
        ));
    }

    #[test]
    fn parses_local_vaultwarden_invite() {
        let cli = Cli::try_parse_from(["kanidm-admin", "local", "vaultwarden", "invite", "dsaw"])
            .expect("parse");

        assert!(matches!(
            cli.command,
            Some(Commands::Local(LocalCommand {
                command: LocalSubcommand::Vaultwarden(LocalVaultwardenCommand {
                    command: LocalVaultwardenSubcommand::Invite { account_id }
                })
            })) if account_id == "dsaw"
        ));
    }

    #[test]
    fn parses_local_sftp_commands() {
        let diagnose = Cli::try_parse_from(["kanidm-admin", "local", "sftp", "diagnose", "alice"])
            .expect("parse diagnose");
        assert!(matches!(
            diagnose.command,
            Some(Commands::Local(LocalCommand {
                command: LocalSubcommand::Sftp(LocalSftpCommand {
                    command: LocalSftpSubcommand::Diagnose { account_id, .. }
                })
            })) if account_id == "alice"
        ));

        let test = Cli::try_parse_from(["kanidm-admin", "local", "sftp", "test", "alice"])
            .expect("parse test");
        assert!(matches!(
            test.command,
            Some(Commands::Local(LocalCommand {
                command: LocalSubcommand::Sftp(LocalSftpCommand {
                    command: LocalSftpSubcommand::Test { account_id, .. }
                })
            })) if account_id == "alice"
        ));
    }

    #[test]
    fn parses_history_prune() {
        let cli = Cli::try_parse_from(["kanidm-admin", "history", "prune", "--older-than", "30d"])
            .expect("parse");
        assert!(matches!(
            cli.command,
            Some(Commands::History(HistoryCommand {
                command: HistorySubcommand::Prune { older_than }
            })) if older_than == "30d"
        ));
    }

    #[test]
    fn parses_history_resume() {
        let cli =
            Cli::try_parse_from(["kanidm-admin", "history", "resume", "op-123"]).expect("parse");
        assert!(matches!(
            cli.command,
            Some(Commands::History(HistoryCommand {
                command: HistorySubcommand::Resume { operation_id }
            })) if operation_id == "op-123"
        ));
    }

    #[test]
    fn parses_history_redact_sensitive() {
        let cli =
            Cli::try_parse_from(["kanidm-admin", "history", "redact-sensitive"]).expect("parse");
        assert!(matches!(
            cli.command,
            Some(Commands::History(HistoryCommand {
                command: HistorySubcommand::RedactSensitive
            }))
        ));
    }

    #[test]
    fn help_mentions_new_examples() {
        let help = render_help(Cli::command());
        assert!(help.contains("kanidm-admin"));
        assert!(help.contains("kanidm-admin doctor"));
    }

    #[test]
    fn user_create_help_mentions_preserve_validity() {
        let mut root = Cli::command();
        let user = root.find_subcommand_mut("user").expect("user command");
        let create = user.find_subcommand_mut("create").expect("create command");
        let help = render_help(create.clone());

        assert!(help.contains("--preserve-validity"));
        assert!(help.contains("Service User"));
    }
}
