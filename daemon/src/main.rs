//! `omafiled` — Omafile's transfer engine.
//!
//! A command line for now. The socket interface the plugin speaks to comes
//! later (ticket 12 measures the protocol before it is locked); this exists so
//! the engine can be exercised and trusted on its own.

use omafiled::engine::Conflict;
use omafiled::{Engine, Journal, Options, Outcome};
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "\
omafiled — every file is committed by atomic rename, or not at all.

Usage:
  omafiled copy <source> <destination> [--checksum]
  omafiled move <source> <destination> [--checksum]
  omafiled unfinished
  omafiled serve [--socket <path>]
               Serve the socket. Under systemd socket activation the listener
               is inherited and --socket is not consulted; run by hand it binds
               the path itself, and refuses rather than take a running daemon's
               clients.

Options:
  --replace    Commit over an existing destination. Without this, and without
               --keep-both, an existing destination is left alone.
  --keep-both  Land beside an existing destination under a free name.
  --checksum   Read the committed file back and hash it against the source.
               Off by default: measured at 2.5-2.7x wall-clock. The size check
               is unconditional and free, and alone would have caught every
               file in the incident this program exists to prevent.
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args[0] == "-h" || args[0] == "--help" {
        print!("{USAGE}");
        return ExitCode::SUCCESS;
    }

    let journal = match Journal::open_default() {
        Ok(j) => j,
        Err(e) => {
            eprintln!("omafiled: cannot open the journal: {e}");
            return ExitCode::FAILURE;
        }
    };
    let engine = Engine::new(journal);

    let checksum = args.iter().any(|a| a == "--checksum");
    let positional: Vec<&String> = args.iter().filter(|a| !a.starts_with("--")).collect();
    let on_conflict = if args.iter().any(|a| a == "--replace") {
        Conflict::Replace
    } else if args.iter().any(|a| a == "--keep-both") {
        Conflict::KeepBoth
    } else {
        Conflict::Skip
    };
    let opts = Options { checksum, on_conflict };

    if positional.first().map(|s| s.as_str()) == Some("serve") {
        let sock = args
            .iter()
            .position(|a| a == "--socket")
            .and_then(|i| args.get(i + 1))
            .map(PathBuf::from)
            .unwrap_or_else(omafiled::server::default_socket_path);
        return match omafiled::server::serve(&sock) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("omafiled: {e}");
                ExitCode::FAILURE
            }
        };
    }

    match positional.first().map(|s| s.as_str()) {
        Some("unfinished") => match Journal::open_default().and_then(|j| j.unfinished()) {
            Ok(entries) if entries.is_empty() => {
                println!("Nothing unfinished. (Completed transfers are not recorded.)");
                ExitCode::SUCCESS
            }
            Ok(entries) => {
                for e in entries {
                    println!(
                        "{} → {}  resumable from {} of {} bytes",
                        e.source.display(),
                        e.destination.display(),
                        e.bytes_done,
                        e.expected_size
                    );
                }
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("omafiled: {e}");
                ExitCode::FAILURE
            }
        },
        Some(verb @ ("copy" | "move")) => {
            if positional.len() < 3 {
                eprintln!("omafiled: {verb} needs a source and a destination");
                return ExitCode::FAILURE;
            }
            let src = PathBuf::from(positional[1]);
            let dst = PathBuf::from(positional[2]);
            let result = if verb == "copy" {
                engine.copy_file(&src, &dst, opts)
            } else {
                engine.move_file(&src, &dst, opts)
            };
            match result {
                Ok(Outcome::Moved { .. }) => {
                    println!("Moved — same filesystem, nothing was copied");
                    ExitCode::SUCCESS
                }
                Ok(Outcome::SkippedExisting) => {
                    println!("Skipped — the destination already exists");
                    println!("  pass --replace to commit over it, or --keep-both to land beside it");
                    ExitCode::SUCCESS
                }
                Ok(Outcome::Copied { tier, bytes, replaced, .. }) => {
                    println!("{}{}", tier.label(), if replaced { " — replaced an existing file" } else { "" });
                    println!("  {}", tier.detail(bytes));
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("omafiled: {e}");
                    ExitCode::FAILURE
                }
            }
        }
        _ => {
            eprint!("{USAGE}");
            ExitCode::FAILURE
        }
    }
}
