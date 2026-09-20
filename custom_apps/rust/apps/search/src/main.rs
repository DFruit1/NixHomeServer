mod bootstrap_solr;
mod config;
mod db;
mod extract;
mod facets;
mod federate;
mod identity;
mod indexer;
mod paperless_search;
mod pdf_archive;
mod retry;
mod server;
mod solr;
mod text;
mod timeutil;
mod zim_search;

use std::process::ExitCode;

fn main() -> ExitCode {
    let command = match std::env::args().nth(1) {
        Some(cmd) => cmd,
        None => {
            eprintln!(
                "usage: search <serve|index|index-daemon|reindex|reconcile|archive-pdfs|bootstrap-solr>"
            );
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
        "reindex" => runtime.block_on(indexer::run_reindex()),
        "reconcile" => runtime.block_on(indexer::run_reconcile()),
        "archive-pdfs" => runtime.block_on(pdf_archive::run()),
        "bootstrap-solr" => runtime.block_on(bootstrap_solr::run()),
        other => {
            eprintln!("unknown command: {other}");
            eprintln!(
                "usage: search <serve|index|index-daemon|reindex|reconcile|archive-pdfs|bootstrap-solr>"
            );
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
