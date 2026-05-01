use clap::{Args, Parser, Subcommand};
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
        group::{group_members, list_groups, search_groups, show_group},
        local::stage_jellyfin_password,
        membership::{
            add_membership, remove_membership, set_membership, show_membership,
            SetMembershipOptions,
        },
        policy::{
            reset_group_auth_expiry, reset_group_privilege_expiry, set_group_auth_expiry,
            set_group_privilege_expiry, show_group_policy,
        },
        session::{
            ensure_interactive_session_allowed, session_login, session_logout, session_reauth,
            session_status,
        },
        user::{
            assign_system_admin, create_user, delete_user, disable_user, enable_user, list_users,
            reset_token, show_user, CreateUserOptions, DeleteUserOptions, ResetTokenOptions,
        },
    },
    output::{render_error, render_output, OutputFormat},
    validation::{
        validate_account_id, validate_display_name, validate_email, validate_identifier_field,
        validate_redirect_url, validate_seconds_field, AUTH_EXPIRY_MAX_SECONDS,
        AUTH_EXPIRY_MIN_SECONDS, PRIVILEGE_EXPIRY_MAX_SECONDS, PRIVILEGE_EXPIRY_MIN_SECONDS,
        RESET_TOKEN_TTL_MAX_SECONDS, RESET_TOKEN_TTL_MIN_SECONDS,
    },
};

#[derive(Debug, Parser)]
#[command(name = "kanidm-admin")]
#[command(
    about = "Live-discovery Kanidm operator CLI for sessions, users, groups, clients, and policy."
)]
struct Cli {
    #[arg(long, global = true)]
    repo_root: Option<std::path::PathBuf>,

    #[arg(long, global = true)]
    server_url: Option<String>,

    #[arg(long, global = true)]
    admin_name: Option<String>,

    #[arg(long, global = true, value_enum, default_value_t = OutputFormat::Human)]
    output: OutputFormat,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Debug, Subcommand)]
enum Commands {
    Doctor,
    Context(ContextCommand),
    Session(SessionCommand),
    User(UserCommand),
    Group(GroupCommand),
    Membership(MembershipCommand),
    Client(ClientCommand),
    Policy(PolicyCommand),
    Local(LocalCommand),
}

#[derive(Debug, Args)]
struct ContextCommand {
    #[command(subcommand)]
    command: ContextSubcommand,
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
    Status,
    Login,
    Reauth,
    Logout,
}

#[derive(Debug, Args)]
struct UserCommand {
    #[command(subcommand)]
    command: UserSubcommand,
}

#[derive(Debug, Subcommand)]
enum UserSubcommand {
    List,
    Show {
        account_id: String,
    },
    Create {
        account_id: String,
        #[arg(long)]
        display_name: String,
        #[arg(long)]
        email: Option<String>,
        #[arg(long, default_value_t = true)]
        clear_validity: bool,
    },
    Disable {
        account_id: String,
    },
    Enable {
        account_id: String,
    },
    Delete {
        account_id: String,
        #[arg(long)]
        confirm: String,
    },
    ResetToken {
        account_id: String,
        #[arg(long, default_value_t = 3600)]
        ttl: u64,
    },
    AssignSystemAdmin {
        account_id: String,
    },
}

#[derive(Debug, Args)]
struct GroupCommand {
    #[command(subcommand)]
    command: GroupSubcommand,
}

#[derive(Debug, Subcommand)]
enum GroupSubcommand {
    List,
    Search { query: String },
    Show { group: String },
    Members { group: String },
}

#[derive(Debug, Args)]
struct MembershipCommand {
    #[command(subcommand)]
    command: MembershipSubcommand,
}

#[derive(Debug, Subcommand)]
enum MembershipSubcommand {
    Show {
        account_id: String,
    },
    Add {
        account_id: String,
        groups: Vec<String>,
    },
    Remove {
        account_id: String,
        groups: Vec<String>,
    },
    Set {
        account_id: String,
        groups: Vec<String>,
        #[arg(long, default_value_t = false)]
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
}

fn main() {
    let cli = Cli::parse();
    let output = cli.output;

    match run(cli) {
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

fn run(cli: Cli) -> Result<Option<kanidm_admin::output::CommandOutput>, kanidm_admin::AppError> {
    let output = cli.output;
    let context = resolve_context(ContextOverrides {
        repo_root: cli.repo_root,
        server_url: cli.server_url,
        admin_name: cli.admin_name,
        kanidm_bin: None,
        nix_bin: None,
    })?;
    let kanidm = KanidmCli::new(&context);

    match cli.command {
        None => {
            if output != OutputFormat::Human {
                return Err(kanidm_admin::AppError::Config {
                    message: "interactive mode only supports --output human".to_string(),
                });
            }
            interactive::run(&context, &kanidm)?;
            Ok(None)
        }
        Some(Commands::Doctor) => doctor(&context, &kanidm).map(Some),
        Some(Commands::Context(command)) => match command.command {
            ContextSubcommand::Show => Ok(Some(show_context(&context))),
        },
        Some(Commands::Session(command)) => match command.command {
            SessionSubcommand::Status => session_status(&kanidm).map(Some),
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
                clear_validity,
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
                        clear_validity,
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
            UserSubcommand::AssignSystemAdmin { account_id } => {
                let account_id = validate_account_id(&account_id)?;
                assign_system_admin(&kanidm, &account_id).map(Some)
            }
        },
        Some(Commands::Group(command)) => match command.command {
            GroupSubcommand::List => list_groups(&kanidm).map(Some),
            GroupSubcommand::Search { query } => search_groups(&kanidm, &query).map(Some),
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
                add_membership(&kanidm, &account_id, &groups).map(Some)
            }
            MembershipSubcommand::Remove { account_id, groups } => {
                let account_id = validate_account_id(&account_id)?;
                let groups = validate_identifier_list("group name", groups)?;
                remove_membership(&kanidm, &account_id, &groups).map(Some)
            }
            MembershipSubcommand::Set {
                account_id,
                groups,
                allow_empty,
            } => {
                let account_id = validate_account_id(&account_id)?;
                let groups = validate_identifier_list("group name", groups)?;
                set_membership(
                    &kanidm,
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
            },
        },
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
    use clap::Parser;

    use super::*;

    #[test]
    fn parses_default_tui_without_subcommand() {
        let cli = Cli::try_parse_from(["kanidm-admin"]).expect("parse");
        assert!(cli.command.is_none());
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
    fn parses_assign_system_admin() {
        let cli = Cli::try_parse_from(["kanidm-admin", "user", "assign-system-admin", "dsaw"])
            .expect("parse");

        assert!(matches!(
            cli.command,
            Some(Commands::User(UserCommand {
                command: UserSubcommand::AssignSystemAdmin { account_id }
            })) if account_id == "dsaw"
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
}
