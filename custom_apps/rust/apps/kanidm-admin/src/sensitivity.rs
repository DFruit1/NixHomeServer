use serde_json::{json, Value};

pub const REDACTED: &str = "<redacted>";

pub fn invocation_args_are_sensitive(args: &[String]) -> bool {
    args_have_sensitive_output(args) || args_have_secret_stdin(args)
}

pub fn args_have_sensitive_output(args: &[String]) -> bool {
    args.windows(2).any(|window| {
        matches!(
            window,
            [a, b] if a == "read-secret" || b == "read-secret" || a == "reset-token" || b == "reset-token"
        )
    }) || args.windows(3).any(|window| {
        matches!(
            window,
            [a, b, c]
                if a == "user" && b == "reset-token"
                    || a == "client" && b == "secret" && matches!(c.as_str(), "show" | "reset")
                    || a == "credential" && b == "create-reset-token"
                    || a == "oauth2" && matches!(b.as_str(), "show-basic-secret" | "reset-basic-secret")
                    || a == "person" && b == "credential" && c == "create-reset-token"
                    || a == "system" && b == "oauth2" && matches!(c.as_str(), "show-basic-secret" | "reset-basic-secret")
        )
    })
}

pub fn args_have_secret_stdin(args: &[String]) -> bool {
    args.windows(3).any(|window| {
        matches!(
            window,
            [a, b, c]
                if a == "person" && b == "posix" && c == "set-password"
                    || a == "user" && b == "posix-password" && c == "set"
                    || b == "kanidm-admin-root" && c == "chpasswd"
                    || b.ends_with("/kanidm-admin-root") && c == "chpasswd"
        )
    }) || args.windows(4).any(|window| {
        matches!(
            window,
            [a, b, c, d]
                if a == "sudo"
                    && b == "-n"
                    && (c == "kanidm-admin-root" || c.ends_with("/kanidm-admin-root"))
                    && d == "chpasswd"
        )
    })
}

pub fn backend_output_redaction_payload() -> Value {
    json!({
        "stdout": true,
        "stderr": true,
        "secret_labels": ["kanidm_sensitive_output"],
    })
}

pub fn sanitize_sensitive_value(value: Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(key, value)| {
                    let sanitized = if is_sensitive_key(&key) {
                        Value::String(REDACTED.to_string())
                    } else {
                        sanitize_sensitive_value(value)
                    };
                    (key, sanitized)
                })
                .collect(),
        ),
        Value::Array(values) => {
            Value::Array(values.into_iter().map(sanitize_sensitive_value).collect())
        }
        other => other,
    }
}

pub fn is_sensitive_key(key: &str) -> bool {
    matches!(
        key,
        "raw_output" | "reset_token" | "reset_url" | "token" | "stdout" | "stderr"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_secret_outputs_and_stdin() {
        assert!(args_have_sensitive_output(&[
            "person".to_string(),
            "credential".to_string(),
            "create-reset-token".to_string(),
            "alice".to_string(),
        ]));
        assert!(args_have_sensitive_output(&[
            "client".to_string(),
            "secret".to_string(),
            "show".to_string(),
            "files".to_string(),
        ]));
        assert!(args_have_secret_stdin(&[
            "person".to_string(),
            "posix".to_string(),
            "set-password".to_string(),
            "alice".to_string(),
        ]));
        assert!(args_have_sensitive_output(&[
            "sudo".to_string(),
            "-n".to_string(),
            "kanidm-admin-root".to_string(),
            "read-secret".to_string(),
            "/run/agenix/secret".to_string(),
        ]));
    }
}
