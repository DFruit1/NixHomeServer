use clap::{Args, Parser, Subcommand};
use kanidm_admin::{
    commands::{
        access::{grant_access, revoke_access, show_access, why_denied},
        auth::auth_status,
        users::{create_user, list_users, show_user, CreateUserOptions},
    },
    config::{resolve_config, ConfigOverrides},
    groups::AppAccessTarget,
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
}

#[derive(Debug, Args)]
struct AuthCommand {
    #[command(subcommand)]
    command: AuthSubcommand,
}

#[derive(Debug, Subcommand)]
enum AuthSubcommand {
    Status,
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
    Create {
        account_id: String,
        #[arg(long)]
        display_name: String,
        #[arg(long)]
        email: Option<String>,
        #[arg(long, default_value_t = true)]
        clear_validity: bool,
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
    WhyDenied {
        #[arg(long)]
        app: AppAccessTarget,
        #[arg(long)]
        user: String,
    },
}

fn main() {
    let cli = Cli::parse();
    let format = cli.format;

    match run(cli) {
        Ok(output) => {
            println!("{}", render_output(format, &output));
        }
        Err(error) => {
            eprintln!("{}", render_error(format, &error));
            std::process::exit(error.exit_code());
        }
    }
}

fn run(cli: Cli) -> Result<kanidm_admin::output::CommandOutput, kanidm_admin::AppError> {
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
            AuthSubcommand::Status => auth_status(&kanidm),
        },
        Commands::Users(command) => match command.command {
            UsersSubcommand::List => list_users(&kanidm),
            UsersSubcommand::Show { account_id } => show_user(&kanidm, &account_id),
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
            ),
        },
        Commands::Access(command) => match command.command {
            AccessSubcommand::Show { account_id } => show_access(&kanidm, &account_id),
            AccessSubcommand::Grant { account_id, group } => {
                grant_access(&kanidm, &account_id, &group)
            }
            AccessSubcommand::Revoke { account_id, group } => {
                revoke_access(&kanidm, &account_id, &group)
            }
            AccessSubcommand::WhyDenied { app, user } => why_denied(&kanidm, &user, app),
        },
    }
}
