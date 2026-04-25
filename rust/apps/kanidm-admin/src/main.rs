use clap::{Args, Parser, Subcommand};
use kanidm_admin::{
    commands::{
        access::{grant_access, revoke_access, set_access, show_access, why_denied, SetAccessOptions},
        auth::{auth_login, auth_reauth, auth_status},
        config::show_config,
        jellyfin::set_jellyfin_password,
        users::{
            create_user, delete_user, disable_user, enable_user, list_users, reset_token,
            show_user, CreateUserOptions, DeleteUserOptions, ResetTokenOptions,
        },
    },
    config::{resolve_config, ConfigOverrides},
    groups::AppAccessTarget,
    interactive,
    kanidm_cli::KanidmCli,
    output::{render_error, render_output, OutputFormat},
};

#[derive(Debug, Parser)]
#[command(name = "kanidm-admin")]
#[command(about = "Focused Kanidm operator CLI for users and access groups.")]
struct Cli {
    #[arg(long, global = true)]
    repo_root: Option<std::path::PathBuf>,

    #[arg(long, global = true)]
    server_url: Option<String>,

    #[arg(long, global = true)]
    admin_name: Option<String>,

    #[arg(long, global = true, value_enum, default_value_t = OutputFormat::Human)]
    format: OutputFormat,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    Auth(AuthCommand),
    Users(UsersCommand),
    Access(AccessCommand),
    Jellyfin(JellyfinCommand),
    Config(ConfigCommand),
    #[command(alias = "tui")]
    Interactive,
}

#[derive(Debug, Args)]
struct AuthCommand {
    #[command(subcommand)]
    command: AuthSubcommand,
}

#[derive(Debug, Subcommand)]
enum AuthSubcommand {
    Status,
    Login,
    Reauth,
}

#[derive(Debug, Args)]
struct UsersCommand {
    #[command(subcommand)]
    command: UsersSubcommand,
}

#[derive(Debug, Subcommand)]
enum UsersSubcommand {
    List,
    Show {
        account_id: String,
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
    Create {
        account_id: String,
        #[arg(long)]
        display_name: String,
        #[arg(long)]
        email: Option<String>,
        #[arg(long, default_value_t = true)]
        clear_validity: bool,
    },
    ResetToken {
        account_id: String,
        #[arg(long, default_value_t = 3600)]
        ttl: u64,
    },
}

#[derive(Debug, Args)]
struct AccessCommand {
    #[command(subcommand)]
    command: AccessSubcommand,
}

#[derive(Debug, Subcommand)]
enum AccessSubcommand {
    Show {
        account_id: String,
    },
    Grant {
        account_id: String,
        group: String,
    },
    Revoke {
        account_id: String,
        group: String,
    },
    Set {
        account_id: String,
        #[arg(long = "group")]
        groups: Vec<String>,
        #[arg(long, default_value_t = false)]
        allow_empty: bool,
    },
    WhyDenied {
        #[arg(long)]
        app: AppAccessTarget,
        #[arg(long)]
        user: String,
    },
}

#[derive(Debug, Args)]
struct JellyfinCommand {
    #[command(subcommand)]
    command: JellyfinSubcommand,
}

#[derive(Debug, Subcommand)]
enum JellyfinSubcommand {
    SetPassword {
        account_id: String,
        #[arg(long, default_value = "JELLYFIN_PASSWORD")]
        password_env: String,
    },
}

#[derive(Debug, Args)]
struct ConfigCommand {
    #[command(subcommand)]
    command: ConfigSubcommand,
}

#[derive(Debug, Subcommand)]
enum ConfigSubcommand {
    Show,
}

fn main() {
    let cli = Cli::parse();
    let format = cli.format;

    match run(cli) {
        Ok(Some(output)) => {
            println!("{}", render_output(format, &output));
        }
        Ok(None) => {}
        Err(error) => {
            eprintln!("{}", render_error(format, &error));
            std::process::exit(error.exit_code());
        }
    }
}

fn run(cli: Cli) -> Result<Option<kanidm_admin::output::CommandOutput>, kanidm_admin::AppError> {
    let format = cli.format;
    let config = resolve_config(ConfigOverrides {
        repo_root: cli.repo_root,
        server_url: cli.server_url,
        admin_name: cli.admin_name,
        kanidm_bin: None,
        nix_bin: None,
    })?;
    let kanidm = KanidmCli::new(&config);

    match cli.command {
        Commands::Auth(command) => match command.command {
            AuthSubcommand::Status => auth_status(&kanidm).map(Some),
            AuthSubcommand::Login => auth_login(&kanidm).map(Some),
            AuthSubcommand::Reauth => auth_reauth(&kanidm).map(Some),
        },
        Commands::Users(command) => match command.command {
            UsersSubcommand::List => list_users(&kanidm).map(Some),
            UsersSubcommand::Show { account_id } => show_user(&kanidm, &account_id).map(Some),
            UsersSubcommand::Disable { account_id } => disable_user(&kanidm, &account_id).map(Some),
            UsersSubcommand::Enable { account_id } => enable_user(&kanidm, &account_id).map(Some),
            UsersSubcommand::Delete {
                account_id,
                confirm,
            } => delete_user(
                &kanidm,
                DeleteUserOptions {
                    account_id,
                    confirm,
                },
            )
            .map(Some),
            UsersSubcommand::Create {
                account_id,
                display_name,
                email,
                clear_validity,
            } => create_user(
                &kanidm,
                CreateUserOptions {
                    account_id,
                    display_name,
                    email,
                    clear_validity,
                },
            )
            .map(Some),
            UsersSubcommand::ResetToken { account_id, ttl } => reset_token(
                &kanidm,
                ResetTokenOptions {
                    account_id,
                    ttl_seconds: ttl,
                },
            )
            .map(Some),
        },
        Commands::Access(command) => match command.command {
            AccessSubcommand::Show { account_id } => show_access(&kanidm, &account_id).map(Some),
            AccessSubcommand::Grant { account_id, group } => {
                grant_access(&kanidm, &account_id, &group).map(Some)
            }
            AccessSubcommand::Revoke { account_id, group } => {
                revoke_access(&kanidm, &account_id, &group).map(Some)
            }
            AccessSubcommand::Set {
                account_id,
                groups,
                allow_empty,
            } => set_access(
                &kanidm,
                SetAccessOptions {
                    account_id,
                    groups,
                    allow_empty,
                },
            )
            .map(Some),
            AccessSubcommand::WhyDenied { app, user } => why_denied(&kanidm, &user, app).map(Some),
        },
        Commands::Jellyfin(command) => match command.command {
            JellyfinSubcommand::SetPassword {
                account_id,
                password_env,
            } => set_jellyfin_password(&account_id, &password_env).map(Some),
        },
        Commands::Config(command) => match command.command {
            ConfigSubcommand::Show => Ok(Some(show_config(&config))),
        },
        Commands::Interactive => {
            if format != OutputFormat::Human {
                return Err(kanidm_admin::AppError::Config {
                    message: "interactive mode only supports --format human".to_string(),
                });
            }
            interactive::run(&config, &kanidm)?;
            Ok(None)
        }
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use super::*;

    #[test]
    fn parses_auth_login() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "auth",
            "login",
        ])
        .expect("parse");

        assert!(matches!(
            cli.command,
            Commands::Auth(AuthCommand {
                command: AuthSubcommand::Login
            })
        ));
    }

    #[test]
    fn parses_auth_reauth() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "auth",
            "reauth",
        ])
        .expect("parse");

        assert!(matches!(
            cli.command,
            Commands::Auth(AuthCommand {
                command: AuthSubcommand::Reauth
            })
        ));
    }

    #[test]
    fn parses_jellyfin_set_password() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "jellyfin",
            "set-password",
            "dsaw",
            "--password-env",
            "CUSTOM_JF_PASSWORD",
        ])
        .expect("parse");

        assert!(matches!(
            cli.command,
            Commands::Jellyfin(JellyfinCommand {
                command: JellyfinSubcommand::SetPassword {
                    account_id,
                    password_env
                }
            }) if account_id == "dsaw" && password_env == "CUSTOM_JF_PASSWORD"
        ));
    }

    #[test]
    fn parses_users_reset_token() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "users",
            "reset-token",
            "dsaw",
            "--ttl",
            "7200",
        ])
        .expect("parse");

        assert!(matches!(
            cli.command,
            Commands::Users(UsersCommand {
                command: UsersSubcommand::ResetToken {
                    account_id,
                    ttl: 7200
                }
            }) if account_id == "dsaw"
        ));
    }

    #[test]
    fn parses_users_delete() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "users",
            "delete",
            "dsaw",
            "--confirm",
            "dsaw",
        ])
        .expect("parse");

        assert!(matches!(
            cli.command,
            Commands::Users(UsersCommand {
                command: UsersSubcommand::Delete {
                    account_id,
                    confirm
                }
            }) if account_id == "dsaw" && confirm == "dsaw"
        ));
    }

    #[test]
    fn parses_access_set() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "access",
            "set",
            "dsaw",
            "--group",
            "users",
            "--group",
            "paperless-users",
            "--allow-empty",
        ])
        .expect("parse");

        assert!(matches!(
            cli.command,
            Commands::Access(AccessCommand {
                command: AccessSubcommand::Set {
                    account_id,
                    groups,
                    allow_empty: true
                }
            }) if account_id == "dsaw" && groups == vec!["users".to_string(), "paperless-users".to_string()]
        ));
    }

    #[test]
    fn parses_interactive_alias() {
        let cli = Cli::try_parse_from([
            "kanidm-admin",
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "tui",
        ])
        .expect("parse");

        assert!(matches!(cli.command, Commands::Interactive));
    }
}
