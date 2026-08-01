use media_manager::{
    broker::{InstallSubtitleAction, MoveAction},
    catalog::{Catalog, ConfirmPlanOutcome, MutationPlanDraft},
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
    let mut catalog = Catalog::open(&temp.path().join("control.sqlite3")).expect("catalog");
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
    let mut catalog = Catalog::open(&temp.path().join("control.sqlite3")).expect("catalog");
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
    let mut catalog = Catalog::open(&temp.path().join("control.sqlite3")).expect("catalog");
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
        .claim_expired_preview_action(101)
        .expect("claim cleanup")
        .expect("expired action");
    assert_eq!(cleanup.plan_id, "expired-plan");
    assert_eq!(cleanup.ordinal, 0);
    assert_eq!(
        catalog.mutation_plan_state("expired-plan").expect("state"),
        Some("expired".to_string())
    );
    catalog
        .complete_expired_preview_action(&cleanup.plan_id, cleanup.ordinal)
        .expect("complete cleanup");
    assert!(catalog
        .claim_expired_preview_action(101)
        .expect("second claim")
        .is_none());
}
