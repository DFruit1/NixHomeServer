mod bootstrap_solr;
mod config;
mod db;
mod extract;
mod indexer;
mod server;
mod solr;
mod text;
mod timeutil;

use std::process::ExitCode;

fn main() -> ExitCode {
    let command = match std::env::args().nth(1) {
        Some(cmd) => cmd,
        None => {
            eprintln!("usage: search <serve|index|index-daemon|reconcile|bootstrap-solr>");
            return ExitCode::FAILURE;
        }
    };

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(err) => {
            eprintln!("failed to start async runtime: {err}");
            return ExitCode::FAILURE;
        }
    };

    let result = match command.as_str() {
        "serve" => runtime.block_on(server::run()),
        "index" => runtime.block_on(indexer::run_index()),
        "index-daemon" => runtime.block_on(indexer::run_index_daemon()),
        "reconcile" => runtime.block_on(indexer::run_reconcile()),
        "bootstrap-solr" => runtime.block_on(bootstrap_solr::run()),
        other => {
            eprintln!("unknown command: {other}");
            eprintln!("usage: search <serve|index|index-daemon|reconcile|bootstrap-solr>");
            return ExitCode::FAILURE;
        }
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("search {command} failed: {err}");
            ExitCode::FAILURE
        }
    }
}
