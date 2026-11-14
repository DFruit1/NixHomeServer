use std::io::{self, Write};

use clap::Parser;
use serde_json::{json, Value};

use crate::server::{self, SearchParams};

/// Search all registered collections using the web application's search engine.
/// Run through sudo search-cli on the server to use its service configuration.
#[derive(Parser)]
#[command(name = "search query")]
struct Args {
    /// Search terms; pass literal double quotes for a phrase, or -- before exclusions.
    #[arg(
        required_unless_present = "list_sources",
        conflicts_with = "list_sources"
    )]
    query: Vec<String>,
    /// List registered sources and their indexing status instead of searching.
    #[arg(long)]
    list_sources: bool,
    /// Emit UI-ordered results, combined facets, coverage and warnings as JSON.
    #[arg(long)]
    json: bool,
    #[arg(long, default_value = "broad", value_parser = ["broad", "all"])]
    matching: String,
    #[arg(long, default_value = "all", value_parser = ["all", "indexed", "live"])]
    scope: String,
    #[arg(long)]
    source: Option<String>,
    #[arg(long)]
    kind: Option<String>,
    #[arg(long = "type")]
    content_type: Option<String>,
    #[arg(long)]
    owner: Option<String>,
    #[arg(long)]
    author: Option<String>,
    /// Partial author, sender or correspondent name.
    #[arg(long)]
    creator: Option<String>,
    /// Inferred filter keys to ignore: kind,creator,after,before,sort.
    #[arg(long)]
    ignore_intent: Option<String>,
    #[arg(long)]
    tag: Option<String>,
    #[arg(long)]
    series: Option<String>,
    #[arg(long)]
    year: Option<String>,
    /// Inclusive start date, YYYY-MM-DD.
    #[arg(long)]
    after: Option<String>,
    /// Inclusive end date, YYYY-MM-DD.
    #[arg(long)]
    before: Option<String>,
    /// Load through this zero-based page, retaining earlier pages and live hits.
    #[arg(long, default_value_t = 0)]
    page: usize,
    #[arg(long, default_value_t = 25, value_parser = clap::value_parser!(u16).range(1..=200))]
    page_size: u16,
    #[arg(long, default_value = "relevance", value_parser = ["relevance", "newest"])]
    sort: String,
}

pub async fn run() -> Result<(), String> {
    let args = Args::parse_from(
        std::iter::once("search query".to_string()).chain(std::env::args().skip(2)),
    );
    let body = if args.list_sources {
        server::sources_local().await?
    } else {
        // Deserialize the same wire contract and use the same validation as HTTP.
        let params: SearchParams = serde_json::from_value(json!({
            "q": args.query.join(" "), "matching": args.matching, "scope": args.scope,
            "source": args.source, "kind": args.kind, "type": args.content_type,
            "owner": args.owner, "author": args.author, "creator": args.creator,
            "ignoreIntent": args.ignore_intent, "tag": args.tag,
            "series": args.series, "year": args.year, "after": args.after,
            "before": args.before, "page": args.page, "pageSize": args.page_size,
            "sort": args.sort,
        }))
        .map_err(|err| format!("invalid search options: {err}"))?;
        server::query_local(params).await?
    };
    let mut output = io::BufWriter::new(io::stdout().lock());
    if args.json {
        serde_json::to_writer_pretty(&mut output, &body).map_err(|err| err.to_string())?;
        writeln!(output).map_err(|err| err.to_string())?;
    } else {
        print_text(&mut output, &body).map_err(|err| err.to_string())?;
    }
    output.flush().map_err(|err| err.to_string())
}

/// Collection content is untrusted: do not emit embedded terminal controls.
fn clean(value: &str) -> String {
    value.chars().filter(|ch| !ch.is_control()).collect()
}

fn string(value: &Value, key: &str) -> String {
    clean(value[key].as_str().unwrap_or_default())
}

fn print_text(output: &mut impl Write, body: &Value) -> io::Result<()> {
    if let Some(sources) = body["sources"].as_array() {
        for source in sources {
            writeln!(
                output,
                "{}\t{}",
                string(source, "id"),
                string(source, "displayName")
            )?;
            if let Some(error) = source["lastError"].as_str() {
                writeln!(output, "  Index warning: {}", clean(error))?;
            }
        }
        return Ok(());
    }
    if let Some(filters) = body["interpretation"]["filters"].as_object() {
        for (name, value) in filters {
            writeln!(
                output,
                "Inferred {name}: {}",
                clean(value.as_str().unwrap_or_default())
            )?;
        }
    }
    if let Some(read_as) = body["literalFallback"].as_object() {
        let reading: Vec<String> = read_as
            .iter()
            .map(|(name, value)| format!("{name} {}", clean(value.as_str().unwrap_or_default())))
            .collect();
        writeln!(
            output,
            "Nothing matched when read as {}; searched the words as typed.",
            reading.join(", ")
        )?;
    }
    if body["relaxed"] == true {
        writeln!(
            output,
            "Nothing contained every word; showing the closest matches."
        )?;
    }
    if let Some(unknown) = body["unknownTerms"].as_array() {
        let unknown: Vec<_> = unknown
            .iter()
            .filter_map(Value::as_str)
            .map(clean)
            .collect();
        if !unknown.is_empty() {
            writeln!(
                output,
                "Not in the library as typed: {}. Close spellings were searched.",
                unknown.join(", ")
            )?;
        }
    }
    write!(output, "{} matches shown", body["shown"])?;
    if body["liveTotal"].as_u64().unwrap_or(0) > 0 {
        write!(output, " · {} live", body["liveTotal"])?;
    }
    if body["libraryTotal"].as_u64().unwrap_or(0) > 0 {
        write!(output, " · {} in library", body["libraryTotal"])?;
    }
    writeln!(output)?;
    if let Some(hits) = body["hits"].as_array() {
        for hit in hits {
            writeln!(
                output,
                "\n[{}] {}",
                string(hit, "source"),
                string(hit, "title")
            )?;
            let snippet = clean(&crate::text::html_to_text(
                hit["snippet"].as_str().unwrap_or_default(),
            ));
            if !snippet.is_empty() {
                writeln!(output, "  {snippet}")?;
            }
            if let Some(copies) = hit["copies"].as_u64().filter(|copies| *copies > 0) {
                writeln!(output, "  {} identical copies", copies + 1)?;
            }
            writeln!(output, "  {}", string(hit, "appUrl"))?;
        }
    }
    if let Some(terms) = body["relatedTerms"].as_array() {
        let terms: Vec<_> = terms.iter().filter_map(Value::as_str).map(clean).collect();
        if !terms.is_empty() {
            writeln!(output, "Related wording: {}", terms.join(", "))?;
        }
    }
    for issue in body["sourceIssues"].as_array().into_iter().flatten() {
        writeln!(
            output,
            "Warning [{}]: last sync failed; results may be out of date.",
            string(issue, "id")
        )?;
    }
    if body["hasMore"] == true {
        writeln!(output, "\nMore indexed results available with --page.")?;
    }
    if body["limited"] == true {
        writeln!(output, "Live results are a bounded sample.")?;
    }
    if let Some(warnings) = body["warnings"].as_array() {
        for warning in warnings {
            writeln!(
                output,
                "Warning [{}]: {}",
                string(warning, "source"),
                string(warning, "message")
            )?;
        }
    }
    Ok(())
}
