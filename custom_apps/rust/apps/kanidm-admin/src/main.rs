use clap::{Args, Parser, Subcommand};
use dialoguer::Password;
use kanidm_admin::{
    context::{resolve_context, ContextOverrides},
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
            show_history,
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
            create_user, delete_user, diagnose_posix_password_with_config, disable_user,
            enable_user, list_users, reset_token, set_posix_password_with_config, show_user,
            test_posix_password_with_config, CreateUserOptions, DeleteUserOptions,
            PosixPasswordOptions, ResetTokenOptions,
        },
    },
    output::{render_error, render_output, CommandOutput, OutputFormat},
    session_state::SessionSnapshot,
    validation::{
        validate_account_id, validate_display_name, validate_email, validate_identifier_field,
        validate_redirect_url, validate_search_query, validate_seconds_field,
        AUTH_EXPIRY_MAX_SECONDS, AUTH_EXPIRY_MIN_SECONDS, PRIVILEGE_EXPIRY_MAX_SECONDS,
        PRIVILEGE_EXPIRY_MIN_SECONDS, RESET_TOKEN_TTL_MAX_SECONDS, RESET_TOKEN_TTL_MIN_SECONDS,
    },
};
use std::time::Duration;

const ROOT_AFTER_HELP: &str =
    "Examples:\n  kanidm-admin\n  kanidm-admin context show\n  kanidm-admin doctor";
const SESSION_LOGIN_AFTER_HELP: &str =
    "Example:\n  kanidm-admin session login\n\nThis command requires a terminal on stdin and stdout and only supports --output human.";
const GROUP_SEARCH_AFTER_HELP: &str =
    "Example:\n  kanidm-admin group search storage\n\nMatches are case-insensitive and search both group names and descriptions.";
const USER_CREATE_AFTER_HELP: &str =
    "Examples:\n  kanidm-admin user create alice --display-name \"Alice\" --email alice@example.com\n  kanidm-admin user create service-user --display-name \"Service User\" --preserve-validity";
const MEMBERSHIP_SET_AFTER_HELP: &str =
    "Examples:\n  kanidm-admin membership set alice users paperless-users\n  kanidm-admin membership set alice --allow-empty";
const DELETE_USER_AFTER_HELP: &str = "Example:\n  kanidm-admin user delete alice --confirm alice";
const POSIX_PASSWORD_AFTER_HELP: &str =
    "Example:\n  kanidm-admin user posix-password set alice\n\nThis refreshes privileged write access before prompting for the new POSIX/UNIX password. The value is separate from the user's web/OIDC password and passkeys.";

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
    #[command(about = "Set or reset the separate POSIX/UNIX password used by SFTP.")]
    PosixPassword(UserPosixPasswordCommand),
}

#[derive(Debug, Args)]
struct UserPosixPasswordCommand {
    #[command(subcommand)]
    command: UserPosixPasswordSubcommand,
}

#[derive(Debug, Subcommand)]
enum UserPosixPasswordSubcommand {
    #[command(
        about = "Open an interactive prompt to set or reset a user's POSIX/UNIX password.",
        after_help = POSIX_PASSWORD_AFTER_HELP
    )]
    Set { account_id: String },
    #[command(
        about = "Interactively test a user's POSIX/UNIX password through Kanidm UnixD.",
        after_help = "Example:\n  kanidm-admin user posix-password test alice\n\nThis prompts for the current POSIX/UNIX password and validates the same UnixD channel used by pam_kanidm."
    )]
    Test { account_id: String },
    #[command(about = "Inspect the non-secret SFTP/POSIX login prerequisites for a user.")]
    Diagnose { account_id: String },
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
    },
}

#[derive(Debug, Args)]
struct ClientCommand {
    #[command(subcommand)]
    command: ClientSubcommand,
}

#[derive(Debug, Subcommand)]
enum ClientSubcommand {
    List,
    Show { client: String },
    Secret(ClientSecretCommand),
    Redirect(ClientRedirectCommand),
    Pkce(ClientPkceCommand),
    Consent(ClientConsentCommand),
}

#[derive(Debug, Args)]
struct ClientSecretCommand {
    #[command(subcommand)]
    command: ClientSecretSubcommand,
}

#[derive(Debug, Subcommand)]
enum ClientSecretSubcommand {
    Show { client: String },
    Reset { client: String },
}

#[derive(Debug, Args)]
struct ClientRedirectCommand {
    #[command(subcommand)]
    command: ClientRedirectSubcommand,
}

#[derive(Debug, Subcommand)]
enum ClientRedirectSubcommand {
    Add { client: String, url: String },
    Remove { client: String, url: String },
}

#[derive(Debug, Args)]
struct ClientPkceCommand {
    #[command(subcommand)]
    command: ClientPkceSubcommand,
}

#[derive(Debug, Subcommand)]
enum ClientPkceSubcommand {
    Enable { client: String },
    Disable { client: String },
}

#[derive(Debug, Args)]
struct ClientConsentCommand {
    #[command(subcommand)]
    command: ClientConsentSubcommand,
}

#[derive(Debug, Subcommand)]
enum ClientConsentSubcommand {
    Enable { client: String },
    Disable { client: String },
}

#[derive(Debug, Args)]
struct PolicyCommand {
    #[command(subcommand)]
    command: PolicySubcommand,
}

#[derive(Debug, Subcommand)]
enum PolicySubcommand {
    Group(PolicyGroupCommand),
}

#[derive(Debug, Args)]
struct PolicyGroupCommand {
    #[command(subcommand)]
    command: PolicyGroupSubcommand,
}

#[derive(Debug, Subcommand)]
enum PolicyGroupSubcommand {
    Show { group: String },
    AuthExpiry(PolicyValueCommand),
    PrivilegeExpiry(PolicyValueCommand),
}

#[derive(Debug, Args)]
struct PolicyValueCommand {
    #[command(subcommand)]
    command: PolicyValueSubcommand,
}

#[derive(Debug, Subcommand)]
enum PolicyValueSubcommand {
    Set { group: String, seconds: u64 },
    Reset { group: String },
}

#[derive(Debug, Args)]
struct LocalCommand {
    #[command(subcommand)]
    command: LocalSubcommand,
}

#[derive(Debug, Subcommand)]
enum LocalSubcommand {
    JellyfinPassword(LocalJellyfinPasswordCommand),
    Sftp(LocalSftpCommand),
    Vaultwarden(LocalVaultwardenCommand),
}

#[derive(Debug, Args)]
struct LocalJellyfinPasswordCommand {
    #[command(subcommand)]
    command: LocalJellyfinPasswordSubcommand,
}

#[derive(Debug, Subcommand)]
enum LocalJellyfinPasswordSubcommand {
    Stage {
        account_id: String,
        #[arg(long, default_value = "JELLYFIN_PASSWORD")]
        password_env: String,
    },
    Diagnose {
        account_id: String,
    },
    Reconcile {
        account_id: String,
    },
    Test {
        account_id: String,
    },
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
        #[arg(
            long,
            default_value_t = false,
            help = "Also run interactive kanidm-unix auth-test for the current POSIX/SFTP password."
        )]
        auth_test: bool,
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
    Invite { account_id: String },
    Diagnose { account_id: String },
    Reconcile { account_id: String },
}

fn main() {
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

fn prompt_confirmed_password(prompt: &str) -> Result<String, kanidm_admin::AppError> {
    Password::new()
        .with_prompt(prompt)
        .with_confirmation("Confirm POSIX/SFTP password", "passwords did not match")
        .allow_empty_password(false)
        .interact()
        .map_err(|error| kanidm_admin::AppError::Config {
            message: format!("interactive password input failed: {error}"),
        })
}

fn set_posix_password_interactive(
    kanidm: &KanidmCli,
    sftp_runtime: &kanidm_admin::context::SftpRuntimeConfig,
    output: OutputFormat,
    account_id: String,
) -> Result<CommandOutput, kanidm_admin::AppError> {
    ensure_interactive_session_allowed(output)?;

    let mut password: Option<String> = None;
    match execute_interactive_operation(
        kanidm,
        OperationKind::PrivilegedWrite,
        OperationPreconditions::PrivilegedWriteReady,
        || {
            let password = match password.as_ref() {
                Some(password) => password.clone(),
                None => {
                    let entered = prompt_confirmed_password("New POSIX/SFTP password")?;
                    password = Some(entered.clone());
                    entered
                }
            };
            set_posix_password_with_config(
                kanidm,
                sftp_runtime,
                PosixPasswordOptions {
                    account_id: account_id.clone(),
                    password,
                    run_auth_test: true,
                },
            )
        },
        |target, error, snapshot| {
            recover_cli_session_interactively(kanidm, output, target, error, snapshot)
        },
    )? {
        OperationOutcome::Success(output) => Ok(output),
        OperationOutcome::Cancelled => Err(kanidm_admin::AppError::Config {
            message: "POSIX password update cancelled before authentication completed".to_string(),
        }),
        OperationOutcome::RecoverableFailure(error) | OperationOutcome::Fatal(error) => Err(error),
    }
}

fn recover_cli_session_interactively(
    kanidm: &KanidmCli,
    output: OutputFormat,
    target: RecoveryTarget,
    error: Option<&kanidm_admin::AppError>,
    snapshot: Option<&SessionSnapshot>,
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
            eprintln!("Starting Kanidm login before continuing the POSIX password update.");
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
            eprintln!(
                "Starting Kanidm reauthentication before continuing the POSIX password update."
            );
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
    let records_history = !matches!(&cli.command, Some(Commands::History(_)));
    let context = resolve_context(ContextOverrides {
        repo_root: cli.repo_root,
        server_url: cli.server_url,
        admin_name: cli.admin_name,
        kanidm_bin: None,
        nix_bin: None,
        vaultwarden_url: None,
        vaultwarden_admin_token_file: None,
        backend_timeout_seconds: cli.backend_timeout_seconds,
    })?;
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
            UserSubcommand::PosixPassword(command) => match command.command {
                UserPosixPasswordSubcommand::Set { account_id } => {
                    let account_id = validate_account_id(&account_id)?;
                    set_posix_password_interactive(
                        &kanidm,
                        &context.sftp_runtime,
                        output,
                        account_id,
                    )
                    .map(Some)
                }
                UserPosixPasswordSubcommand::Test { account_id } => {
                    ensure_interactive_session_allowed(output)?;
                    let account_id = validate_account_id(&account_id)?;
                    test_posix_password_with_config(&kanidm, &context.sftp_runtime, &account_id)
                        .map(Some)
                }
                UserPosixPasswordSubcommand::Diagnose { account_id } => {
                    let account_id = validate_account_id(&account_id)?;
                    diagnose_posix_password_with_config(&kanidm, &context.sftp_runtime, &account_id)
                        .map(Some)
                }
            },
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
            } => {
                let account_id = validate_account_id(&account_id)?;
                let groups = validate_identifier_list("group name", groups)?;
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
                ClientSecretSubcommand::Show { client } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    client_secret_show(&kanidm, &client).map(Some)
                }
                ClientSecretSubcommand::Reset { client } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    client_secret_reset(&kanidm, &client).map(Some)
                }
            },
            ClientSubcommand::Redirect(redirect) => match redirect.command {
                ClientRedirectSubcommand::Add { client, url } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    let url = validate_redirect_url(&url)?;
                    client_redirect_add(&kanidm, &client, &url).map(Some)
                }
                ClientRedirectSubcommand::Remove { client, url } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    let url = validate_redirect_url(&url)?;
                    client_redirect_remove(&kanidm, &client, &url).map(Some)
                }
            },
            ClientSubcommand::Pkce(pkce) => match pkce.command {
                ClientPkceSubcommand::Enable { client } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    client_pkce_enable(&kanidm, &client).map(Some)
                }
                ClientPkceSubcommand::Disable { client } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    client_pkce_disable(&kanidm, &client).map(Some)
                }
            },
            ClientSubcommand::Consent(consent) => match consent.command {
                ClientConsentSubcommand::Enable { client } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
                    client_consent_enable(&kanidm, &client).map(Some)
                }
                ClientConsentSubcommand::Disable { client } => {
                    let client = validate_identifier_field("oauth2 client name", &client)?;
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
                    auth_test,
                } => {
                    if auth_test {
                        ensure_interactive_session_allowed(output)?;
                    }
                    let account_id = validate_account_id(&account_id)?;
                    test_sftp_login_with_policy(
                        &kanidm,
                        &context.sftp_runtime,
                        &account_id,
                        auth_test,
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
                    allow_empty: true
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
    fn parses_user_posix_password_set() {
        let cli = Cli::try_parse_from(["kanidm-admin", "user", "posix-password", "set", "alice"])
            .expect("parse");

        assert!(matches!(
            cli.command,
            Some(Commands::User(UserCommand {
                command: UserSubcommand::PosixPassword(UserPosixPasswordCommand {
                    command: UserPosixPasswordSubcommand::Set { account_id }
                })
            })) if account_id == "alice"
        ));
    }

    #[test]
    fn parses_client_pkce_disable() {
        let cli = Cli::try_parse_from(["kanidm-admin", "client", "pkce", "disable", "files"])
            .expect("parse");

        assert!(matches!(
            cli.command,
            Some(Commands::Client(ClientCommand {
                command: ClientSubcommand::Pkce(ClientPkceCommand {
                    command: ClientPkceSubcommand::Disable { client }
                })
            })) if client == "files"
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

        let test = Cli::try_parse_from([
            "kanidm-admin",
            "local",
            "sftp",
            "test",
            "alice",
            "--auth-test",
        ])
        .expect("parse test");
        assert!(matches!(
            test.command,
            Some(Commands::Local(LocalCommand {
                command: LocalSubcommand::Sftp(LocalSftpCommand {
                    command: LocalSftpSubcommand::Test {
                        account_id,
                        auth_test: true,
                        ..
                    }
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
