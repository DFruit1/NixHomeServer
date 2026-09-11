use serde_json::Value;
include!("api_contract_generated.rs");

pub fn assert_component(name: &str, value: &Value) {
    let contract: Value = serde_json::from_str(API_CONTRACT).unwrap();
    assert!(
        matches(
            value,
            contract["components"]["schemas"]
                .get(name)
                .expect("known component"),
            &contract
        ),
        "response does not match {name}: {value}"
    );
}

fn matches(value: &Value, schema: &Value, contract: &Value) -> bool {
    if let Some(accepted) = schema.as_bool() {
        return accepted;
    }
    if let Some(reference) = schema["$ref"].as_str() {
        return matches(
            value,
            contract
                .pointer(&reference[1..])
                .expect("valid schema reference"),
            contract,
        );
    }
    if value.is_null() && schema["nullable"] == true {
        return true;
    }
    for key in ["allOf", "anyOf", "oneOf"] {
        if let Some(parts) = schema[key].as_array() {
            let count = parts
                .iter()
                .filter(|part| matches(value, part, contract))
                .count();
            if (key == "allOf" && count != parts.len())
                || (key == "anyOf" && count == 0)
                || (key == "oneOf" && count != 1)
            {
                return false;
            }
        }
    }
    if let Some(expected) = schema.get("const") {
        if value != expected {
            return false;
        }
    }
    if let Some(values) = schema["enum"].as_array() {
        if !values.contains(value) {
            return false;
        }
    }
    let kind_matches = |kind: &str| match kind {
        "object" => value.is_object(),
        "array" => value.is_array(),
        "string" => value.is_string(),
        "integer" => value.is_i64() || value.is_u64(),
        "number" => value.is_number(),
        "boolean" => value.is_boolean(),
        "null" => value.is_null(),
        _ => panic!("unsupported schema type {kind}"),
    };
    if let Some(kind) = schema["type"].as_str() {
        if !kind_matches(kind) {
            return false;
        }
    }
    if let Some(kinds) = schema["type"].as_array() {
        if !kinds
            .iter()
            .any(|kind| kind_matches(kind.as_str().unwrap()))
        {
            return false;
        }
    }
    if let Some(object) = value.as_object() {
        if let Some(required) = schema["required"].as_array() {
            if required
                .iter()
                .any(|key| !object.contains_key(key.as_str().unwrap()))
            {
                return false;
            }
        }
        for (key, child) in object {
            if let Some(spec) = schema["properties"].get(key) {
                if !matches(child, spec, contract) {
                    return false;
                }
            } else if let Some(spec) = schema.get("additionalProperties") {
                if !matches(child, spec, contract) {
                    return false;
                }
            }
        }
    }
    if let (Some(items), Some(spec)) = (value.as_array(), schema.get("items")) {
        if !items.iter().all(|item| matches(item, spec, contract)) {
            return false;
        }
    }
    true
}
