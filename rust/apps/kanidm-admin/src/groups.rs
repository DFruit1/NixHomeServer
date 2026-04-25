use clap::ValueEnum;
use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GroupCategory {
    Login,
    AdminIntent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ManagedGroup {
    pub name: &'static str,
    pub category: GroupCategory,
    pub description: &'static str,
}

pub const MANAGED_GROUPS: [ManagedGroup; 13] = [
    ManagedGroup {
        name: "users",
        category: GroupCategory::Login,
        description: "Baseline identity only.",
    },
    ManagedGroup {
        name: "fileshare_users",
        category: GroupCategory::Login,
        description: "Access to files.sydneybasiniot.org through OAuth2 Proxy.",
    },
    ManagedGroup {
        name: "mail-archive-users",
        category: GroupCategory::Login,
        description: "Access to emails.sydneybasiniot.org.",
    },
    ManagedGroup {
        name: "immich-users",
        category: GroupCategory::Login,
        description: "Can sign into Photos / Immich.",
    },
    ManagedGroup {
        name: "immich-admin",
        category: GroupCategory::AdminIntent,
        description: "Intended Photos admin.",
    },
    ManagedGroup {
        name: "paperless-users",
        category: GroupCategory::Login,
        description: "Can sign into Paperless.",
    },
    ManagedGroup {
        name: "paperless-admin",
        category: GroupCategory::AdminIntent,
        description: "Intended Paperless admin.",
    },
    ManagedGroup {
        name: "audiobookshelf-users",
        category: GroupCategory::Login,
        description: "Can sign into Audiobookshelf.",
    },
    ManagedGroup {
        name: "audiobookshelf-admin",
        category: GroupCategory::AdminIntent,
        description: "Intended Audiobookshelf admin.",
    },
    ManagedGroup {
        name: "kavita-login",
        category: GroupCategory::Login,
        description: "Can sign into Books / Kavita.",
    },
    ManagedGroup {
        name: "kavita-admin",
        category: GroupCategory::AdminIntent,
        description: "Intended Books / Kavita admin.",
    },
    ManagedGroup {
        name: "jellyfin-users",
        category: GroupCategory::Login,
        description: "Can sign into Videos / Jellyfin.",
    },
    ManagedGroup {
        name: "jellyfin-admin",
        category: GroupCategory::AdminIntent,
        description: "Intended Videos / Jellyfin admin.",
    },
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AppAccessTarget {
    Files,
    MailArchive,
    Immich,
    Paperless,
    Audiobookshelf,
    Kavita,
    Jellyfin,
}

pub fn managed_group(name: &str) -> Option<&'static ManagedGroup> {
    MANAGED_GROUPS.iter().find(|group| group.name == name)
}

pub fn filter_managed_group_names<'a>(groups: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    let mut managed = groups
        .into_iter()
        .filter(|group| managed_group(group).is_some())
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    managed.sort();
    managed.dedup();
    managed
}

pub fn login_groups(groups: &[String]) -> Vec<String> {
    groups
        .iter()
        .filter(|group| {
            matches!(
                managed_group(group),
                Some(ManagedGroup {
                    category: GroupCategory::Login,
                    ..
                })
            )
        })
        .cloned()
        .collect()
}

pub fn admin_intent_groups(groups: &[String]) -> Vec<String> {
    groups
        .iter()
        .filter(|group| {
            matches!(
                managed_group(group),
                Some(ManagedGroup {
                    category: GroupCategory::AdminIntent,
                    ..
                })
            )
        })
        .cloned()
        .collect()
}

pub fn required_group_for_app(app: AppAccessTarget) -> &'static str {
    match app {
        AppAccessTarget::Files => "fileshare_users",
        AppAccessTarget::MailArchive => "mail-archive-users",
        AppAccessTarget::Immich => "immich-users",
        AppAccessTarget::Paperless => "paperless-users",
        AppAccessTarget::Audiobookshelf => "audiobookshelf-users",
        AppAccessTarget::Kavita => "kavita-login",
        AppAccessTarget::Jellyfin => "jellyfin-users",
    }
}

pub fn managed_group_names() -> Vec<&'static str> {
    MANAGED_GROUPS.iter().map(|group| group.name).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn managed_groups_include_mail_archive() {
        assert_eq!(
            managed_group("mail-archive-users").map(|group| group.description),
            Some("Access to emails.sydneybasiniot.org.")
        );
    }

    #[test]
    fn app_mapping_matches_repo_policy() {
        assert_eq!(
            required_group_for_app(AppAccessTarget::Files),
            "fileshare_users"
        );
        assert_eq!(
            required_group_for_app(AppAccessTarget::MailArchive),
            "mail-archive-users"
        );
        assert_eq!(
            required_group_for_app(AppAccessTarget::Jellyfin),
            "jellyfin-users"
        );
    }

    #[test]
    fn filter_managed_group_names_rejects_unknown_entries() {
        let filtered = filter_managed_group_names(["mail-archive-users", "idm_admins", "users"]);
        assert_eq!(
            filtered,
            vec!["mail-archive-users".to_string(), "users".to_string()]
        );
    }
}
