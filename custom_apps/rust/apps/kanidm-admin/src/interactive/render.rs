use crate::AppError;

pub fn print_output(title: &str, body: &str) {
    print_block(title, body);
}

pub fn print_note(title: &str, body: &str) {
    print_block(title, body);
}

pub fn print_error(error: &AppError) {
    print_block("Error", &error.human_message());
}

pub fn print_block(title: &str, body: &str) {
    println!("\n== {title} ==\n");
    println!("{body}");
    println!();
}
