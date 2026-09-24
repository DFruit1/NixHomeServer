use media_manager::{
    broker::{InstallSubtitleAction, MoveAction},
    catalog::{
        AbandonPlanOutcome, Catalog, ConfirmPlanOutcome, MutationPlanDraft, RetryPlanOutcome,
    },
};

fn action() -> MoveAction {
    MoveAction {
        source_root_id: "shared-videos".to_string(),
        source_relative_path: "Movies/Arrival.mkv".to_string(),
        destination_root_id: "shared-videos".to_string(),
        destination_relative_path: "Movies/Arrival (2016).mkv".to_string(),
        expected: "5:123".to_string(),
    }
}

#[test]
fn plan_confirmation_is_owner_and_digest_bound() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut catalog = Catalog::initialize(&temp.path().join("control.sqlite3")).expect("catalog");
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: "plan-1".to_string(),
            owner_username: "editor".to_string(),
            digest: "abc123".to_string(),
            request_json: "{}".to_string(),
            expires_at: i64::MAX,
            actions: vec![action().into()],
        })
        .expect("create plan");

    assert_eq!(
        catalog
            .confirm_mutation_plan("plan-1", "other-editor", "abc123", 100)
            .expect("owner check"),
        ConfirmPlanOutcome::NotFound
    );
    assert_eq!(
        catalog
            .confirm_mutation_plan("plan-1", "editor", "wrong", 100)
            .expect("digest check"),
        ConfirmPlanOutcome::DigestMismatch
    );
    assert_eq!(
        catalog
            .confirm_mutation_plan("plan-1", "editor", "abc123", 100)
            .expect("confirm"),
        ConfirmPlanOutcome::Queued
    );
    assert_eq!(
        catalog
            .confirm_mutation_plan("plan-1", "editor", "abc123", 100)
            .expect("cannot confirm twice"),
        ConfirmPlanOutcome::StateConflict
    );
}

#[test]
fn global_queue_claims_one_plan_and_records_completion() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut catalog = Catalog::initialize(&temp.path().join("control.sqlite3")).expect("catalog");
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: "plan-1".to_string(),
            owner_username: "editor".to_string(),
            digest: "abc123".to_string(),
            request_json: "{}".to_string(),
            expires_at: i64::MAX,
            actions: vec![action().into()],
        })
        .expect("create plan");
    catalog
        .confirm_mutation_plan("plan-1", "editor", "abc123", 100)
        .expect("confirm");

    let claimed = catalog
        .claim_next_mutation_plan()
        .expect("claim")
        .expect("queued plan");
    assert_eq!(claimed.id, "plan-1");
    assert_eq!(claimed.actions.len(), 1);
    assert!(catalog
        .claim_next_mutation_plan()
        .expect("second claim")
        .is_none());
    catalog
        .complete_mutation_action("plan-1", 0)
        .expect("complete action");
    catalog
        .finish_mutation_plan("plan-1", None)
        .expect("finish plan");
    assert_eq!(
        catalog.mutation_plan_state("plan-1").expect("state"),
        Some("completed".to_string())
    );
}

#[test]
fn expired_previews_are_claimed_for_staging_cleanup_once() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut catalog = Catalog::initialize(&temp.path().join("control.sqlite3")).expect("catalog");
    let subtitle = InstallSubtitleAction {
        staging_filename: "subtitle-expired.srt".to_string(),
        destination_root_id: "shared-videos".to_string(),
        destination_relative_path: "Movies/Arrival (2016).en.srt".to_string(),
        expected: "42:123".to_string(),
    };
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: "expired-plan".to_string(),
            owner_username: "editor".to_string(),
            digest: "expired-digest".to_string(),
            request_json: "{}".to_string(),
            expires_at: 100,
            actions: vec![subtitle.into()],
        })
        .expect("create expired preview");

    let cleanup = catalog
        .claim_discardable_preview_action(101)
        .expect("claim cleanup")
        .expect("expired action");
    assert_eq!(cleanup.plan_id, "expired-plan");
    assert_eq!(cleanup.ordinal, 0);
    assert_eq!(
        catalog.mutation_plan_state("expired-plan").expect("state"),
        Some("expired".to_string())
    );
    catalog
        .complete_discarded_preview_action(&cleanup.plan_id, cleanup.ordinal)
        .expect("complete cleanup");
    assert!(catalog
        .claim_discardable_preview_action(101)
        .expect("second claim")
        .is_none());
}

#[test]
fn plan_listing_reports_operation_and_is_owner_scoped() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut catalog = Catalog::initialize(&temp.path().join("control.sqlite3")).expect("catalog");
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: "plan-a".to_string(),
            owner_username: "editor".to_string(),
            digest: "digest-a".to_string(),
            request_json: serde_json::json!({
                "operation": { "kind": "canonicalize_names" },
                "itemIds": ["item-1", "item-2"],
            })
            .to_string(),
            expires_at: i64::MAX,
            actions: vec![action().into()],
        })
        .expect("create editor plan");
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: "plan-b".to_string(),
            owner_username: "other".to_string(),
            digest: "digest-b".to_string(),
            request_json: serde_json::json!({
                "kind": "install_subtitle",
                "itemId": "item-9",
            })
            .to_string(),
            expires_at: i64::MAX,
            actions: vec![action().into()],
        })
        .expect("create other plan");

    let mine = catalog
        .list_mutation_plans(Some("editor"), 50)
        .expect("owner list");
    assert_eq!(mine.len(), 1);
    assert_eq!(mine[0].id, "plan-a");
    assert_eq!(mine[0].operation_kind, "canonicalize_names");
    assert_eq!(mine[0].item_ids, vec!["item-1", "item-2"]);
    assert_eq!(mine[0].state, "previewed");
    assert_eq!(mine[0].action_count, 1);
    assert_eq!(mine[0].completed_action_count, 0);

    let all = catalog.list_mutation_plans(None, 50).expect("global list");
    assert_eq!(all.len(), 2);
    assert!(all.iter().any(|plan| plan.id == "plan-b"));
    assert_eq!(
        all.iter()
            .find(|plan| plan.id == "plan-b")
            .expect("other plan")
            .item_ids,
        vec!["item-9"]
    );
}

#[test]
fn abandon_rejects_only_unstarted_plans_owned_by_the_caller() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut catalog = Catalog::initialize(&temp.path().join("control.sqlite3")).expect("catalog");
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: "plan-1".to_string(),
            owner_username: "editor".to_string(),
            digest: "abc123".to_string(),
            request_json: "{}".to_string(),
            expires_at: i64::MAX,
            actions: vec![action().into()],
        })
        .expect("create plan");

    assert_eq!(
        catalog
            .abandon_mutation_plan("plan-1", "other")
            .expect("owner check"),
        AbandonPlanOutcome::NotFound
    );
    assert_eq!(
        catalog
            .abandon_mutation_plan("plan-1", "editor")
            .expect("abandon"),
        AbandonPlanOutcome::Rejected
    );
    assert_eq!(
        catalog
            .abandon_mutation_plan("plan-1", "editor")
            .expect("cannot abandon twice"),
        AbandonPlanOutcome::StateConflict
    );
    assert_eq!(
        catalog.mutation_plan_state("plan-1").expect("state"),
        Some("rejected".to_string())
    );
}

#[test]
fn retry_requeues_only_failed_plans_owned_by_the_caller() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut catalog = Catalog::initialize(&temp.path().join("control.sqlite3")).expect("catalog");
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: "plan-1".to_string(),
            owner_username: "editor".to_string(),
            digest: "abc123".to_string(),
            request_json: "{}".to_string(),
            expires_at: i64::MAX,
            actions: vec![action().into()],
        })
        .expect("create plan");

    assert_eq!(
        catalog
            .retry_mutation_plan("plan-1", "editor")
            .expect("preview is not retryable"),
        RetryPlanOutcome::StateConflict
    );
    catalog
        .confirm_mutation_plan("plan-1", "editor", "abc123", 100)
        .expect("confirm");
    catalog
        .claim_next_mutation_plan()
        .expect("claim")
        .expect("running plan");
    catalog
        .finish_mutation_plan("plan-1", Some("rename target exists"))
        .expect("fail plan");
    assert_eq!(
        catalog.mutation_plan_state("plan-1").expect("state"),
        Some("failed".to_string())
    );
    assert_eq!(
        catalog
            .retry_mutation_plan("plan-1", "other")
            .expect("owner check"),
        RetryPlanOutcome::NotFound
    );
    assert_eq!(
        catalog
            .retry_mutation_plan("plan-1", "editor")
            .expect("retry"),
        RetryPlanOutcome::Queued
    );
    assert_eq!(
        catalog.mutation_plan_state("plan-1").expect("state"),
        Some("queued".to_string())
    );
    assert_eq!(
        catalog
            .retry_mutation_plan("plan-1", "editor")
            .expect("cannot retry a queued plan"),
        RetryPlanOutcome::StateConflict
    );
}

#[test]
fn rejected_previews_are_claimed_for_staging_cleanup() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let mut catalog = Catalog::initialize(&temp.path().join("control.sqlite3")).expect("catalog");
    let subtitle = InstallSubtitleAction {
        staging_filename: "subtitle-rejected.srt".to_string(),
        destination_root_id: "shared-videos".to_string(),
        destination_relative_path: "Movies/Arrival (2016).en.srt".to_string(),
        expected: "42:123".to_string(),
    };
    catalog
        .create_mutation_plan(&MutationPlanDraft {
            id: "rejected-plan".to_string(),
            owner_username: "editor".to_string(),
            digest: "rejected-digest".to_string(),
            request_json: "{}".to_string(),
            expires_at: i64::MAX,
            actions: vec![subtitle.into()],
        })
        .expect("create rejected preview");
    assert_eq!(
        catalog
            .abandon_mutation_plan("rejected-plan", "editor")
            .expect("abandon"),
        AbandonPlanOutcome::Rejected
    );

    let cleanup = catalog
        .claim_discardable_preview_action(1)
        .expect("claim cleanup")
        .expect("rejected action");
    assert_eq!(cleanup.plan_id, "rejected-plan");
    catalog
        .complete_discarded_preview_action(&cleanup.plan_id, cleanup.ordinal)
        .expect("complete cleanup");
    assert!(catalog
        .claim_discardable_preview_action(1)
        .expect("second claim")
        .is_none());
}
