//! Late-event derivation race (review 2, finding 6), against a real Postgres.
//!
//! These tests need a migrated chum-mem database and are skipped unless
//! `CHUM_MEM_TEST_DATABASE_URL` is set — point it at a throw-away local stack,
//! never a shared server. Each test works in its own fresh project, so they
//! can run against a database that holds other data and in parallel.

use std::time::Duration;

use chum_mem_contracts::{ActorType, TeamRole};
use chum_mem_db::{
    RepositoryContext, WorkerJobRecord, apply_repository_context, claim_next_worker_job,
    complete_worker_job, enqueue_debounced_worker_job, enqueue_worker_job, ensure_scope_entities,
    mark_session_completed, resolve_session_for_append, upsert_ingested_project,
};
use serde_json::json;
use sqlx::PgPool;
use sqlx::postgres::PgPoolOptions;
use uuid::Uuid;

const JOB: &str = "derive-session-memories";

async fn test_pool() -> Option<PgPool> {
    let url = std::env::var("CHUM_MEM_TEST_DATABASE_URL").ok().filter(|v| !v.is_empty());
    let Some(url) = url else {
        eprintln!("skipped: CHUM_MEM_TEST_DATABASE_URL not set");
        return None;
    };
    Some(
        PgPoolOptions::new()
            .max_connections(4)
            .connect(&url)
            .await
            .expect("connect to CHUM_MEM_TEST_DATABASE_URL"),
    )
}

fn context(project_id: Uuid) -> RepositoryContext {
    RepositoryContext {
        organization_id: Uuid::from_u128(1),
        team_id: Uuid::from_u128(2),
        project_id: Some(project_id),
        actor_id: None,
        actor_type: ActorType::System,
        team_role: TeamRole::Admin,
    }
}

async fn fresh_project(pool: &PgPool) -> RepositoryContext {
    let ctx = context(Uuid::new_v4());
    let mut tx = pool.begin().await.unwrap();
    apply_repository_context(&mut *tx, &ctx).await.unwrap();
    ensure_scope_entities(&mut tx, &RepositoryContext { project_id: None, ..ctx.clone() })
        .await
        .unwrap();
    upsert_ingested_project(&mut tx, &ctx, ctx.project_id.unwrap(), None)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    ctx
}

async fn enqueue(pool: &PgPool, ctx: &RepositoryContext, key: &str, n: i64) -> WorkerJobRecord {
    let mut tx = pool.begin().await.unwrap();
    apply_repository_context(&mut *tx, ctx).await.unwrap();
    let job = enqueue_worker_job(
        &mut tx,
        ctx,
        ctx.project_id.unwrap(),
        None,
        None,
        JOB,
        key,
        50,
        3,
        None,
        &json!({ "n": n }),
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
    job
}

async fn claim(pool: &PgPool, ctx: &RepositoryContext) -> Option<WorkerJobRecord> {
    let mut tx = pool.begin().await.unwrap();
    apply_repository_context(&mut *tx, ctx).await.unwrap();
    let job = claim_next_worker_job(&mut tx, ctx, "race-test-worker", &[JOB])
        .await
        .unwrap();
    tx.commit().await.unwrap();
    job
}

async fn complete(pool: &PgPool, ctx: &RepositoryContext, job: &WorkerJobRecord) {
    let mut tx = pool.begin().await.unwrap();
    apply_repository_context(&mut *tx, ctx).await.unwrap();
    // The return value changed from () to "re-queued?"; the test reads the row.
    let _ = complete_worker_job(&mut tx, job).await.unwrap();
    tx.commit().await.unwrap();
}

async fn job_status(pool: &PgPool, id: Uuid) -> String {
    sqlx::query_scalar("select status::text from public.worker_jobs where id = $1")
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap()
}

/// The worker is running the derivation job (it already loaded the events)
/// when a late event enqueues the same dedupe key: the enqueue merges into the
/// running row. Completing that row used to drop the new work for good.
#[tokio::test]
async fn job_reenqueued_while_running_is_queued_again_not_completed() {
    let Some(pool) = test_pool().await else { return };
    let ctx = fresh_project(&pool).await;
    let key = format!("derive:{}", Uuid::new_v4());

    enqueue(&pool, &ctx, &key, 1).await;
    let running = claim(&pool, &ctx).await.expect("claims the job");
    assert_eq!(running.payload["n"], 1);

    // Late event arrives mid-run.
    let merged = enqueue(&pool, &ctx, &key, 2).await;
    assert_eq!(merged.id, running.id, "merged into the running row");

    complete(&pool, &ctx, &running).await;
    assert_eq!(
        job_status(&pool, running.id).await,
        "pending",
        "work enqueued during the run must run again"
    );

    // The re-run sees the newest payload; with nothing new it completes.
    let rerun = claim(&pool, &ctx).await.expect("re-run is claimable");
    assert_eq!(rerun.id, running.id);
    assert_eq!(rerun.payload["n"], 2);
    complete(&pool, &ctx, &rerun).await;
    assert_eq!(job_status(&pool, running.id).await, "completed");
}

/// Control: a run nobody re-enqueued completes normally.
#[tokio::test]
async fn job_not_reenqueued_completes() {
    let Some(pool) = test_pool().await else { return };
    let ctx = fresh_project(&pool).await;
    let key = format!("derive:{}", Uuid::new_v4());
    enqueue(&pool, &ctx, &key, 1).await;
    let running = claim(&pool, &ctx).await.unwrap();
    complete(&pool, &ctx, &running).await;
    assert_eq!(job_status(&pool, running.id).await, "completed");
}

async fn debounced(
    pool: &PgPool,
    ctx: &RepositoryContext,
    key: &str,
    available_at: time::OffsetDateTime,
    max_delay_secs: i64,
) -> WorkerJobRecord {
    let mut tx = pool.begin().await.unwrap();
    apply_repository_context(&mut *tx, ctx).await.unwrap();
    let at = available_at
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap();
    let job = enqueue_debounced_worker_job(
        &mut tx,
        ctx,
        ctx.project_id.unwrap(),
        None,
        JOB,
        key,
        50,
        3,
        &at,
        max_delay_secs,
        &json!({}),
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();
    job
}

/// Each late event restarts the quiet period (the old enqueue kept the
/// earliest available_at), up to created_at + max delay.
#[tokio::test]
async fn late_derivation_is_a_real_debounce_with_a_cap() {
    let Some(pool) = test_pool().await else { return };
    let ctx = fresh_project(&pool).await;
    let key = format!("derive:{}", Uuid::new_v4());
    let now = time::OffsetDateTime::now_utc();

    let first = debounced(&pool, &ctx, &key, now + time::Duration::seconds(60), 600).await;
    let second = debounced(&pool, &ctx, &key, now + time::Duration::seconds(120), 600).await;
    assert_eq!(first.id, second.id);
    assert!(
        second.available_at > first.available_at,
        "a later event pushes the run out: {} -> {}",
        first.available_at,
        second.available_at
    );
    // Far beyond the cap: clamped to created_at + 600 s.
    let third = debounced(&pool, &ctx, &key, now + time::Duration::seconds(5_000), 600).await;
    let cap = first.created_at + time::Duration::seconds(600);
    assert!(
        (third.available_at - cap).abs() < time::Duration::seconds(2),
        "capped at created_at + max delay: {} vs {}",
        third.available_at,
        cap
    );
}

/// An append must not read a session as `active` while a concurrent
/// session/end has marked it completed but not committed: it waits for the
/// end and then sees `completed` (so it schedules a late derivation).
#[tokio::test]
async fn append_waits_for_an_in_flight_session_end() {
    let Some(pool) = test_pool().await else { return };
    let ctx = fresh_project(&pool).await;
    let session_id: Uuid = sqlx::query_scalar(
        r#"
        insert into public.sessions (organization_id, team_id, project_id, provider, external_session_id, status)
        values ($1, $2, $3, 'claude', $4, 'active')
        returning id
        "#,
    )
    .bind(ctx.organization_id)
    .bind(ctx.team_id)
    .bind(ctx.project_id.unwrap())
    .bind(format!("race-{}", Uuid::new_v4()))
    .fetch_one(&pool)
    .await
    .unwrap();

    // session/end: marks the session completed and is still deriving.
    let mut end_tx = pool.begin().await.unwrap();
    apply_repository_context(&mut *end_tx, &ctx).await.unwrap();
    mark_session_completed(&mut end_tx, session_id, &json!({"derivedAt": "now"}), None, false)
        .await
        .unwrap();

    // Concurrent append.
    let append_pool = pool.clone();
    let append_ctx = ctx.clone();
    let append = tokio::spawn(async move {
        let mut tx = append_pool.begin().await.unwrap();
        apply_repository_context(&mut *tx, &append_ctx).await.unwrap();
        let session = resolve_session_for_append(&mut tx, &append_ctx, session_id)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        session.status
    });

    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!append.is_finished(), "the append must wait for the in-flight end");
    end_tx.commit().await.unwrap();
    let status = tokio::time::timeout(Duration::from_secs(10), append)
        .await
        .expect("append finishes once the end commits")
        .unwrap();
    assert_eq!(status, "completed", "the append sees the committed end, so the event is late");
}
