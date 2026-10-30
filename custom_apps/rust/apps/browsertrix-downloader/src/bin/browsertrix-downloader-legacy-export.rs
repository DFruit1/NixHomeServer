//! Explicit offline maintenance; never run automatically at startup or rollback.
fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 2 {
        eprintln!("Usage: browsertrix-downloader-legacy-export SOURCE_DB NEW_PRIVATE_DESTINATION_DB\nPreserves SOURCE_DB. Exports compatible completed shared standalone history only. All other work stays parked in SOURCE_DB. Keep the current Nix private-storage/service-group boundary during binary rollback; this does not copy payloads or enable an old crawler.");
        std::process::exit(2);
    }
    match browsertrix_downloader::legacy_export::export(
        std::path::Path::new(&args[0]),
        std::path::Path::new(&args[1]),
    ) {
        Ok(receipt) => println!(
            "{}",
            serde_json::to_string(&receipt).expect("receipt serializes")
        ),
        Err(error) => {
            eprintln!("Legacy export refused or incomplete: {error}. Do not select an incomplete destination.");
            std::process::exit(1);
        }
    }
}
