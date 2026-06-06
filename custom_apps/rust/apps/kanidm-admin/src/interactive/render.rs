use crate::output::{error_text, render_error, section_title, OutputFormat};
use crate::AppError;

pub fn print_output(title: &str, body: &str) {
    print_block(title, body);
}

pub fn print_note(title: &str, body: &str) {
    print_block(title, body);
}

pub fn print_error(error: &AppError) {
    print_block("Error", &render_error(OutputFormat::Human, error));
}

pub fn print_block(title: &str, body: &str) {
    let _ = console::Term::stdout().clear_screen();
    let rendered_title = if title == "Error" {
        error_text(title)
    } else {
        section_title(title)
    };
    println!("\n== {rendered_title} ==\n");
    println!("{body}");
    println!();
}
