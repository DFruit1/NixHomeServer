use axum::{
    extract::State,
    http::header::CONTENT_TYPE,
    response::{Html, IntoResponse, Response},
    routing::get,
    Router,
};
use std::{env, net::SocketAddr, sync::Arc};

const DEFAULT_ADDRESS: &str = "127.0.0.1";
const DEFAULT_PORT: u16 = 9010;
const DEFAULT_DATA_DIR: &str = ".";
const CUSTOM_CSS: &str = include_str!("../static/custom.css");

#[derive(Clone, Debug)]
struct AppState {
    data_dir: Arc<str>,
}

#[tokio::main]
async fn main() {
    let address = env::var("RUST_SCAFFOLD_ADDRESS").unwrap_or_else(|_| DEFAULT_ADDRESS.to_string());
    let port = env::var("RUST_SCAFFOLD_PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(DEFAULT_PORT);
    let data_dir =
        env::var("RUST_SCAFFOLD_DATA_DIR").unwrap_or_else(|_| DEFAULT_DATA_DIR.to_string());

    let app = app(AppState {
        data_dir: Arc::<str>::from(data_dir),
    });

    let listener = tokio::net::TcpListener::bind(format!("{address}:{port}"))
        .await
        .expect("failed to bind Rust scaffold listener");

    let socket_addr: SocketAddr = listener
        .local_addr()
        .expect("failed to read Rust scaffold listener address");

    eprintln!("rust-scaffold listening on http://{socket_addr}");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("Rust scaffold server exited unexpectedly");
}

fn app(state: AppState) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/healthz", get(healthz))
        .route("/static/custom.css", get(custom_css))
        .with_state(state)
}

async fn index(State(state): State<AppState>) -> Html<String> {
    Html(render_index(&state.data_dir))
}

async fn healthz() -> &'static str {
    "ok"
}

async fn custom_css() -> Response {
    ([(CONTENT_TYPE, "text/css; charset=utf-8")], CUSTOM_CSS).into_response()
}

fn render_index(data_dir: &str) -> String {
    format!(
        r#"<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Rust Scaffold</title>
    <link rel="stylesheet" href="/static/custom.css">
  </head>
  <body>
    <main class="shell">
      <p class="eyebrow">NixOS Rust Scaffold</p>
      <h1>Editable source, reproducible build.</h1>
      <p class="lede">
        This tiny service proves the repo-local Rust workflow. Edit the source or CSS,
        rebuild with Nix, and redeploy through the same server config.
      </p>
      <dl class="details">
        <div>
          <dt>Health check</dt>
          <dd><code>GET /healthz</code></dd>
        </div>
        <div>
          <dt>Data directory</dt>
          <dd><code>{data_dir}</code></dd>
        </div>
      </dl>
    </main>
  </body>
</html>"#
    )
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn index_html_references_custom_css() {
        let html = render_index("/tmp/rust-scaffold");

        assert!(html.contains("/static/custom.css"));
        assert!(html.contains("/tmp/rust-scaffold"));
    }

    #[test]
    fn embedded_custom_css_has_expected_marker() {
        assert!(CUSTOM_CSS.contains(".shell"));
    }
}
