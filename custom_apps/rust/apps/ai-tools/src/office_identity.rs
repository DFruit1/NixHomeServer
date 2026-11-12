//! Online directory proof, never a username-to-privilege shortcut. The Unix
//! token is fetched afresh for each operation; NSS corroborates numeric mapping
//! only and never supplies cached group membership.

use reqwest::{Client, Url};
use serde::Deserialize;
use serde_json::json;
use std::{collections::BTreeMap, ffi::CStr, net::SocketAddr, time::Duration};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub(crate) struct Principal {
    pub uid: u32,
    pub gid: u32,
    pub groups: Vec<u32>,
}

#[derive(Deserialize)]
struct Group {
    name: String,
    spn: String,
    gidnumber: u32,
}

#[derive(Deserialize)]
struct UnixToken {
    name: String,
    spn: String,
    uuid: String,
    gidnumber: u32,
    groups: Vec<Group>,
    #[serde(default)]
    valid: bool,
}

pub(crate) async fn resolve(
    base: &str,
    humans: &[String],
    subject: &str,
    username: &str,
) -> Result<Principal, String> {
    let subject = Uuid::parse_str(subject).map_err(|_| "Unrecognized caller identity")?;
    if subject.is_nil() {
        return Err("Unrecognized caller identity".into());
    }
    let base = Url::parse(base).map_err(|_| "Invalid directory configuration")?;
    if base.scheme() != "https"
        || !base.username().is_empty()
        || base.password().is_some()
        || base.query().is_some()
        || base.fragment().is_some()
        || base.path() != "/"
    {
        return Err("Invalid directory configuration".into());
    }
    let host = base.host_str().ok_or("Invalid directory configuration")?;
    let client = Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        // Only the anonymous auth transaction uses a private, fresh cookie jar.
        // No user SSO credential is consumed, cached, or sent to this client.
        .cookie_store(true)
        .resolve(
            host,
            SocketAddr::from(([127, 0, 0, 1], base.port_or_known_default().unwrap_or(443))),
        )
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|_| "Directory is unavailable")?;
    let mut result = serde_json::Value::Null;
    for step in [
        json!({"init2":{"username":"anonymous","issue":"token","privileged":false}}),
        json!({"begin":"anonymous"}),
        json!({"cred":"anonymous"}),
    ] {
        let response = client
            .post(
                base.join("v1/auth")
                    .map_err(|_| "Invalid directory configuration")?,
            )
            .json(&json!({"step":step}))
            .send()
            .await
            .map_err(|_| "Directory is unavailable")?;
        if !response.status().is_success() {
            return Err("Directory is unavailable".into());
        }
        result = bounded_json(response).await?;
    }
    let token = result
        .get("state")
        .and_then(|s| s.get("success"))
        .and_then(|s| s.as_str())
        .filter(|s| s.len() <= 16384)
        .ok_or("Directory is unavailable")?;
    let response = client
        .get(
            base.join(&format!("v1/account/{subject}/_unix/_token"))
                .map_err(|_| "Invalid directory configuration")?,
        )
        .bearer_auth(token)
        .send()
        .await
        .map_err(|_| "Directory is unavailable")?;
    if !response.status().is_success() {
        return Err("Caller is not an active approved file user".into());
    }
    let token: UnixToken = serde_json::from_value(bounded_json(response).await?)
        .map_err(|_| "Directory returned an invalid identity")?;
    principal(&token, &subject, username, humans, user_name, group_name)
}

async fn bounded_json(mut response: reqwest::Response) -> Result<serde_json::Value, String> {
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "Directory is unavailable")?
    {
        if bytes.len() + chunk.len() > 128 * 1024 {
            return Err("Directory returned an oversized identity".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| "Directory returned an invalid identity".into())
}

fn canonical_pair(name: &str, spn: &str) -> bool {
    if name.is_empty()
        || name
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || "@,:/\\".contains(c))
    {
        return false;
    }
    let Some((local, domain)) = spn.split_once('@') else {
        return false;
    };
    // Validate without trimming/case folding the identity. Canonical DNS
    // realms use ASCII (including IDNA A-labels); a final DNS root dot is OK.
    let domain = domain.strip_suffix('.').unwrap_or(domain);
    local == name
        && !domain.is_empty()
        && domain.len() <= 253
        && domain.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
                && label.as_bytes()[0].is_ascii_alphanumeric()
                && label.as_bytes()[label.len() - 1].is_ascii_alphanumeric()
        })
}

fn principal(
    token: &UnixToken,
    subject: &Uuid,
    username: &str,
    humans: &[String],
    user: impl Fn(u32) -> Option<String>,
    group: impl Fn(u32) -> Option<String>,
) -> Result<Principal, String> {
    let denied = || "Caller is not an active approved file user".to_string();
    if !token.valid
        || !canonical_pair(&token.name, &token.spn)
        || token.gidnumber < 1000
        || Uuid::parse_str(&token.uuid).ok().as_ref() != Some(subject)
        || !(username == token.name || username == token.spn)
        || !humans.contains(&token.name)
        || token.groups.len() > 128
    {
        return Err(denied());
    }
    let name = user(token.gidnumber).ok_or_else(denied)?;
    if name != token.name && name != token.spn {
        return Err(denied());
    }
    // The token may omit the private primary group from its group list. It is
    // still a kernel grant, so corroborate it separately rather than silently
    // trusting the same number as the UID.
    let primary = group(token.gidnumber).ok_or_else(denied)?;
    if primary != token.name && primary != token.spn {
        return Err(denied());
    }
    let mut groups = BTreeMap::from([(token.gidnumber, (&token.name, &token.spn))]);
    for entry in &token.groups {
        if entry.gidnumber < 1000 || !canonical_pair(&entry.name, &entry.spn) {
            return Err(denied());
        }
        let identity = (&entry.name, &entry.spn);
        if groups
            .get(&entry.gidnumber)
            .is_some_and(|existing| *existing != identity)
        {
            return Err(denied());
        }
        let name = group(entry.gidnumber).ok_or_else(denied)?;
        if name != entry.name && name != entry.spn {
            return Err(denied());
        }
        groups.insert(entry.gidnumber, identity);
    }
    Ok(Principal {
        uid: token.gidnumber,
        gid: token.gidnumber,
        groups: groups.into_keys().collect(),
    })
}

fn user_name(uid: u32) -> Option<String> {
    let mut item = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 65536];
    // SAFETY: reentrant NSS call writes only into the provided record/buffer.
    let rc = unsafe {
        libc::getpwuid_r(
            uid,
            item.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if rc != 0 || result.is_null() {
        return None;
    }
    let item = unsafe { item.assume_init() };
    if item.pw_name.is_null() || item.pw_uid != uid || item.pw_gid != uid {
        return None;
    }
    unsafe { CStr::from_ptr(item.pw_name) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

fn group_name(gid: u32) -> Option<String> {
    let mut item = std::mem::MaybeUninit::<libc::group>::uninit();
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 65536];
    // SAFETY: record, buffer and result out-pointer remain live for this call.
    let rc = unsafe {
        libc::getgrgid_r(
            gid,
            item.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if rc != 0 || result.is_null() {
        return None;
    }
    let item = unsafe { item.assume_init() };
    if item.gr_name.is_null() || item.gr_gid != gid {
        return None;
    }
    unsafe { CStr::from_ptr(item.gr_name) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    // A missing/colliding primary group must not become an implicit grant to
    // an unrelated local group's files, even if the Unix token omits it.
    #[test]
    fn primary_group_must_be_corroborated_even_without_supplementary_groups() {
        let subject = Uuid::new_v4();
        let token = UnixToken {
            name: "alice".into(),
            spn: "alice@example.test".into(),
            uuid: subject.to_string(),
            gidnumber: 20000,
            groups: vec![],
            valid: true,
        };
        let humans = vec!["alice".into()];
        for result in [None, Some("unrelated-local-group".into())] {
            assert!(principal(
                &token,
                &subject,
                "alice",
                &humans,
                |_| Some("alice".into()),
                |_| result.clone()
            )
            .is_err());
        }
        for name in ["alice", "alice@example.test"] {
            assert_eq!(
                principal(
                    &token,
                    &subject,
                    "alice@example.test",
                    &humans,
                    |_| Some("alice".into()),
                    |_| Some(name.into())
                )
                .unwrap()
                .groups,
                vec![20000]
            );
        }
    }

    #[test]
    fn directory_alias_conflicts_and_reused_group_ids_fail_closed() {
        let subject = Uuid::new_v4();
        let mut token = UnixToken {
            name: "alice".into(),
            spn: "bob@example.test".into(),
            uuid: subject.to_string(),
            gidnumber: 20000,
            groups: vec![],
            valid: true,
        };
        let humans = vec!["alice".into()];
        assert!(principal(
            &token,
            &subject,
            "alice",
            &humans,
            |_| Some("alice".into()),
            |_| Some("alice".into())
        )
        .is_err());
        token.spn = "alice@example.test".into();
        token.groups = vec![Group {
            name: "shared".into(),
            spn: "other@example.test".into(),
            gidnumber: 2001,
        }];
        assert!(principal(
            &token,
            &subject,
            "alice",
            &humans,
            |_| Some("alice".into()),
            |id| Some(if id == 20000 { "alice" } else { "shared" }.into())
        )
        .is_err());
        token.groups[0].spn = "shared@example.test".into();
        token.groups.push(Group {
            name: "other".into(),
            spn: "other@example.test".into(),
            gidnumber: 2001,
        });
        let calls = std::cell::Cell::new(0);
        assert!(principal(
            &token,
            &subject,
            "alice",
            &humans,
            |_| Some("alice".into()),
            |id| {
                if id == 20000 {
                    return Some("alice".into());
                }
                calls.set(calls.get() + 1);
                Some(if calls.get() == 1 { "shared" } else { "other" }.into())
            }
        )
        .is_err());
    }
    #[test]
    fn office_principal_requires_subject_valid_human_and_exact_nss_mapping() {
        let subject = Uuid::new_v4();
        let mut token = UnixToken {
            name: "alice".into(),
            spn: "alice@example.test".into(),
            uuid: subject.to_string(),
            gidnumber: 20000,
            groups: vec![Group {
                name: "shared".into(),
                spn: "shared@example.test".into(),
                gidnumber: 2001,
            }],
            valid: true,
        };
        let humans = vec!["alice".into()];
        let resolve = |t: &UnixToken| {
            principal(
                t,
                &subject,
                "alice",
                &humans,
                |_| Some("alice".into()),
                |gid| Some(if gid == 20000 { "alice" } else { "shared" }.into()),
            )
        };
        assert_eq!(resolve(&token).unwrap().groups, vec![2001, 20000]);
        token.groups.push(Group {
            name: "alice".into(),
            spn: "alice@example.test".into(),
            gidnumber: 20000,
        });
        assert_eq!(resolve(&token).unwrap().groups, vec![2001, 20000]);
        token.groups.pop();
        for domain in [
            " ",
            "example.test\n",
            "\0",
            ".example",
            "example..test",
            "-example.test",
            "example-.test",
            "example/path",
            "example:443",
            "realm@other",
            "",
        ] {
            token.spn = format!("alice@{domain}");
            assert!(resolve(&token).is_err(), "malformed user realm {domain:?}");
            token.spn = "alice@example.test".into();
            token.groups[0].spn = format!("shared@{domain}");
            assert!(resolve(&token).is_err(), "malformed group realm {domain:?}");
            token.groups[0].spn = "shared@example.test".into();
        }
        token.valid = false;
        assert!(resolve(&token).is_err());
        token.valid = true;
        token.uuid = Uuid::new_v4().to_string();
        assert!(resolve(&token).is_err());
        token.uuid = subject.to_string();
        assert!(principal(
            &token,
            &subject,
            "alice",
            &[],
            |_| Some("alice".into()),
            |_| Some("shared".into())
        )
        .is_err());
        assert!(principal(
            &token,
            &subject,
            "alice",
            &humans,
            |_| Some("other-local-user".into()),
            |_| Some("shared".into())
        )
        .is_err());
        token.groups[0].gidnumber = 0;
        assert!(resolve(&token).is_err());
    }
}
