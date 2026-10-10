use indexmap::IndexMap;
use std::collections::HashSet;

use chum_mem_contracts::{CanonicalEventType, EndSessionRequest, MemoryType, SessionEventPayload};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::CHROMA_EMBEDDING_DIMENSIONS;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEventRecord {
    pub id: Uuid,
    pub event_type: CanonicalEventType,
    pub payload: SessionEventPayload,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DerivedMemoryDraft {
    #[serde(rename = "type")]
    pub memory_type: MemoryType,
    pub title: String,
    pub content: String,
    pub summary: String,
    pub importance_score: f64,
    pub confidence_score: f64,
    pub provenance_event_ids: Vec<Uuid>,
    pub metadata: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEpisodeDraft {
    pub episode_ordinal: i32,
    pub episode_type: String,
    pub title: String,
    pub summary: String,
    pub started_at: String,
    pub ended_at: String,
    pub provenance_event_ids: Vec<Uuid>,
    pub metadata: Value,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSimilaritySignals {
    pub file_paths: Vec<String>,
    pub error_signatures: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRelationshipScore {
    pub weight: f64,
    pub edge_type: String,
    pub reasons: Vec<String>,
}

pub fn derive_session_episodes(
    session_id: Uuid,
    provider: &str,
    end_request: &EndSessionRequest,
    events: &[SessionEventRecord],
) -> Vec<SessionEpisodeDraft> {
    if events.is_empty() {
        return Vec::new();
    }

    let first = match events.first() {
        Some(first) => first,
        None => return Vec::new(),
    };

    let mut episodes = Vec::new();
    let mut current = EpisodeBucket::new(1, classify_event(first));

    for event in events {
        let next_type = classify_event(event);
        if should_start_new_episode(&current.events, event, &next_type) {
            episodes.push(materialize_episode(session_id, &current));
            current = EpisodeBucket::new(current.episode_ordinal + 1, next_type);
        }
        current.events.push(event.clone());
    }

    if !current.events.is_empty() {
        episodes.push(materialize_episode(session_id, &current));
    }

    let _ = provider;
    let _ = end_request;
    episodes
}

pub fn derive_memories_from_session(
    session_id: Uuid,
    provider: &str,
    end_request: &EndSessionRequest,
    events: &[SessionEventRecord],
    episodes: Option<&[SessionEpisodeDraft]>,
) -> Vec<DerivedMemoryDraft> {
    let owned_episodes;
    let episodes = if let Some(episodes) = episodes {
        episodes
    } else {
        owned_episodes = derive_session_episodes(session_id, provider, end_request, events);
        &owned_episodes
    };

    let mut memories = derive_atomic_claim_memories(session_id, end_request, events, episodes);
    let has_atomic_claims = memories.iter().any(|memory| {
        !matches!(
            memory.memory_type,
            MemoryType::Summary | MemoryType::Risk | MemoryType::ChangeLog
        )
    });

    if !has_atomic_claims {
        let mut rollup_summary = end_request
            .summary
            .as_ref()
            .map(|value| value.trim().to_string())
            .unwrap_or_default();
        if rollup_summary.is_empty() {
            rollup_summary = episodes
                .iter()
                .map(|episode| format!("{}: {}", episode.title, episode.summary))
                .collect::<Vec<_>>()
                .join("\n");
            rollup_summary = truncate(rollup_summary, 3000);
        }

        if !rollup_summary.is_empty() {
            memories.push(DerivedMemoryDraft {
                memory_type: MemoryType::Summary,
                title: format!("Session summary ({})", provider_str(provider)),
                content: rollup_summary.clone(),
                summary: truncate(rollup_summary.clone(), 300),
                importance_score: 0.75,
                confidence_score: 0.8,
                provenance_event_ids: episodes
                    .iter()
                    .flat_map(|episode| episode.provenance_event_ids.iter().copied())
                    .collect(),
                metadata: json!({
                    "derivation": "session_episode_rollup_v2",
                    "sessionId": session_id,
                    "proofType": "summary",
                    "authorityClass": "model_derived",
                    "verificationStatus": "unverified",
                    "belief": { "admit": false },
                }),
            });
        }

        if let Some(reflection) = derive_reflection_memory(session_id, episodes) {
            memories.push(reflection);
        }

        for episode in episodes {
            memories.push(DerivedMemoryDraft {
                memory_type: MemoryType::Summary,
                title: episode.title.clone(),
                content: episode.summary.clone(),
                summary: truncate(episode.summary.clone(), 300),
                importance_score: if episode.episode_type == "debugging" {
                    0.8
                } else {
                    0.65
                },
                confidence_score: 0.8,
                provenance_event_ids: episode.provenance_event_ids.clone(),
                metadata: json!({
                    "derivation": "session_episode_summary_v1",
                    "sessionId": session_id,
                    "episodeOrdinal": episode.episode_ordinal,
                    "episodeType": episode.episode_type,
                    "proofType": "summary",
                    "authorityClass": "session_derived",
                    "verificationStatus": "unverified",
                    "belief": { "admit": false },
                }),
            });
        }
    }

    dedupe_derived_memories(memories)
}

pub fn extract_session_signals(events: &[SessionEventRecord]) -> SessionSimilaritySignals {
    use indexmap::IndexSet;

    let mut file_paths: IndexSet<String> = IndexSet::new();
    let mut error_signatures: IndexSet<String> = IndexSet::new();

    for event in events {
        if let Some(file_path) = event.payload.file_path.as_deref() {
            let trimmed = file_path.trim();
            if !trimmed.is_empty() {
                file_paths.insert(trimmed.to_string());
            }
        }

        let text = event_text(event).to_lowercase();
        let is_error = event.event_type == CanonicalEventType::Error
            || event.payload.exit_code.is_some_and(|code| code != 0)
            || text.contains("failed");
        if is_error {
            let normalized = normalize_error_signature(&event_text(event));
            if !normalized.is_empty() {
                error_signatures.insert(normalized);
            }
        }
    }

    SessionSimilaritySignals {
        file_paths: file_paths.into_iter().collect(),
        error_signatures: error_signatures.into_iter().collect(),
    }
}

pub fn score_session_relationship(
    current_branch: Option<&str>,
    current_signals: &SessionSimilaritySignals,
    candidate_branch: Option<&str>,
    candidate_signals: &SessionSimilaritySignals,
) -> Option<SessionRelationshipScore> {
    let mut weight = 0.0;
    let mut reasons = Vec::new();

    let current_br = current_branch.filter(|s| !s.is_empty());
    let candidate_br = candidate_branch.filter(|s| !s.is_empty());
    if current_br.is_some() && candidate_br.is_some() && current_br == candidate_br {
        weight += 0.35;
        reasons.push("same_branch".to_string());
    }

    let shared_files = intersect_count(&current_signals.file_paths, &candidate_signals.file_paths);
    if shared_files > 0 {
        weight += (shared_files as f64 * 0.15).min(0.3);
        reasons.push(format!("shared_files:{shared_files}"));
    }

    let shared_errors = intersect_count(
        &current_signals.error_signatures,
        &candidate_signals.error_signatures,
    );
    if shared_errors > 0 {
        weight += (shared_errors as f64 * 0.15).min(0.3);
        reasons.push(format!("shared_errors:{shared_errors}"));
    }

    if weight < 0.35 {
        return None;
    }

    Some(SessionRelationshipScore {
        weight: ((weight.min(1.0)) * 10_000.0).round() / 10_000.0,
        edge_type: if reasons.iter().any(|reason| reason == "same_branch") {
            "same_branch".to_string()
        } else {
            "related_to".to_string()
        },
        reasons,
    })
}

pub fn event_text(event: &SessionEventRecord) -> String {
    [
        event.payload.message.as_deref().unwrap_or(""),
        event.payload.command.as_deref().unwrap_or(""),
        event.payload.tool_name.as_deref().unwrap_or(""),
        event.payload.file_path.as_deref().unwrap_or(""),
    ]
    .into_iter()
    .map(str::trim)
    .filter(|value| !value.is_empty())
    .collect::<Vec<_>>()
    .join(" | ")
}

/// Label stored in `embeddings.model`; bump when the model or dimension changes.
pub const EMBEDDING_MODEL_LABEL: &str = "bge-small-en-v1.5-384";

static EMBEDDER: std::sync::OnceLock<std::sync::Mutex<fastembed::TextEmbedding>> =
    std::sync::OnceLock::new();

fn embedder() -> &'static std::sync::Mutex<fastembed::TextEmbedding> {
    EMBEDDER.get_or_init(|| {
        let options = fastembed::TextInitOptions::new(fastembed::EmbeddingModel::BGESmallENV15)
            .with_show_download_progress(false);
        let model = fastembed::TextEmbedding::try_new(options).unwrap_or_else(|error| {
            panic!(
                "failed to initialise the local embedding model (bge-small-en-v1.5): {error}. \
                 First run needs network access to download it; set FASTEMBED_CACHE_DIR to a \
                 writable, persistent directory."
            )
        });
        std::sync::Mutex::new(model)
    })
}

/// Eagerly load the embedding model (downloads it on first use). Call once at
/// service startup so the first request does not pay the download/warm-up.
pub fn init_embedder() {
    let _ = embed_text("warm-up");
}

/// Embed a batch of texts with the local sentence-embedding model. Output
/// vectors are L2-normalised and `CHROMA_EMBEDDING_DIMENSIONS` wide.
pub fn embed_texts(texts: &[&str]) -> Vec<Vec<f64>> {
    if texts.is_empty() {
        return Vec::new();
    }
    let mut model = embedder()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let embeddings = model
        .embed(texts, Some(32))
        .unwrap_or_else(|error| panic!("embedding {} texts failed: {error}", texts.len()));
    embeddings
        .into_iter()
        .map(|embedding| {
            let mut vector: Vec<f64> = embedding.into_iter().map(f64::from).collect();
            debug_assert_eq!(vector.len(), CHROMA_EMBEDDING_DIMENSIONS);
            let magnitude = vector.iter().map(|value| value * value).sum::<f64>().sqrt();
            if magnitude > 0.0 {
                for value in vector.iter_mut() {
                    *value /= magnitude;
                }
            }
            vector
        })
        .collect()
}

pub fn embed_text(text: &str) -> Vec<f64> {
    embed_texts(&[text])
        .pop()
        .unwrap_or_else(|| vec![0.0_f64; CHROMA_EMBEDDING_DIMENSIONS])
}

fn provider_str(provider: &str) -> &str {
    provider
}

fn derive_atomic_claim_memories(
    session_id: Uuid,
    end_request: &EndSessionRequest,
    events: &[SessionEventRecord],
    episodes: &[SessionEpisodeDraft],
) -> Vec<DerivedMemoryDraft> {
    let mut memories = Vec::new();
    let final_answers = final_answer_event_ids(events);

    for event in events {
        let episode = episodes
            .iter()
            .find(|episode| episode.provenance_event_ids.contains(&event.id));
        let text = event_text(event);
        // D5: compaction summaries, slash-command / skill bodies, background
        // task notifications and hook text arrive as `prompt` events but were
        // not written by the engineer. They never originate a claim.
        if is_file_content_tool_event(event) {
            continue;
        }
        if is_injected_event_text(&text) {
            // A compaction summary is model-written but restates decisions
            // from the compacted part of the session. Keep only its explicit
            // "Decision:" lines, at assistant-answer authority (model_derived,
            // inferred), never as user-confirmed text.
            if is_compaction_summary(&text) {
                memories.extend(extract_model_text_claims(
                    session_id,
                    episode,
                    event,
                    &text,
                    ModelTextSource::CompactionSummary,
                ));
            }
            continue;
        }
        if final_answers.contains(&event.id) {
            memories.extend(extract_model_text_claims(
                session_id,
                episode,
                event,
                &text,
                ModelTextSource::FinalAnswer,
            ));
            continue;
        }
        memories.extend(extract_claims_from_text(
            session_id,
            episode,
            Some(event),
            &text,
            vec![event.id],
            false,
        ));
    }

    if let Some(summary) = end_request.summary.as_deref() {
        let provenance_event_ids = episodes
            .iter()
            .flat_map(|episode| episode.provenance_event_ids.iter().copied())
            .collect::<Vec<_>>();
        memories.extend(extract_claims_from_text(
            session_id,
            None,
            None,
            summary,
            provenance_event_ids,
            true,
        ));
    }

    memories
}

fn extract_claims_from_text(
    session_id: Uuid,
    episode: Option<&SessionEpisodeDraft>,
    event: Option<&SessionEventRecord>,
    text: &str,
    provenance_event_ids: Vec<Uuid>,
    from_summary: bool,
) -> Vec<DerivedMemoryDraft> {
    // v2.2.1 belief gate: Reasoning and TurnContext carry signal but must
    // never originate a durable claim — regardless of what the text says.
    // AgentMessage flows through the classifiers and is rejected downstream
    // as model_derived. See docs/research/v2.2.1-pckc/DESIGN.md §2.
    if event.is_some_and(|evt| {
        matches!(
            evt.event_type,
            CanonicalEventType::Reasoning | CanonicalEventType::TurnContext
        )
    }) {
        return Vec::new();
    }

    let mut claims = Vec::new();
    let cleaned = strip_template_noise(text);
    for segment in claim_segments(&cleaned) {
        if looks_like_code_line(&segment) {
            continue;
        }
        let Some(memory_type) = classify_claim_type(event, &segment) else {
            continue;
        };
        let lower = segment.to_lowercase();
        let proof_type = classify_proof_type(event, from_summary);
        let authority_class = classify_authority_class(event, proof_type, from_summary);
        let verification_status = classify_verification_status(&lower, event, from_summary);
        let admit = should_admit_claim(memory_type, authority_class, verification_status, &lower);
        let claim_key = claim_key(memory_type, &segment, event);
        let title = claim_title(memory_type, &segment);
        let importance_score = claim_importance(memory_type, verification_status);
        let confidence_score = claim_confidence(verification_status, from_summary);
        let claim_polarity = if is_negative_claim(&lower) {
            "negative"
        } else {
            "positive"
        };
        claims.push(DerivedMemoryDraft {
            memory_type,
            title,
            content: truncate(segment.clone(), 3000),
            summary: truncate(segment.clone(), 300),
            importance_score,
            confidence_score,
            provenance_event_ids: provenance_event_ids.clone(),
            metadata: json!({
                "derivation": derivation_name(memory_type, from_summary),
                "sessionId": session_id,
                "episodeOrdinal": episode.map(|value| value.episode_ordinal),
                "episodeType": episode.map(|value| value.episode_type.clone()),
                "claimKey": claim_key,
                "claimPolarity": claim_polarity,
                "proofType": proof_type,
                "authorityClass": authority_class,
                "verificationStatus": verification_status,
                "sourceClass": source_class_for_memory_type(memory_type),
                "rankingRole": ranking_role_for_memory_type(memory_type),
                "belief": { "admit": admit },
                "answerCritical": !matches!(
                    memory_type,
                    MemoryType::ImplementationDetail | MemoryType::Summary | MemoryType::Risk
                ),
            }),
        });
    }
    claims
}

fn claim_segments(text: &str) -> Vec<String> {
    // F27 fix: split at sentence boundaries too, so "Decision: … . Do not change code."
    // yields a decision claim and a separate constraint instead of one negative-polarity blob.
    let normalized = text
        .replace(". ", ".\n")
        .replace("; ", ";\n")
        .replace("? ", "?\n")
        .replace("! ", "!\n");
    normalized
        .split(['\n', '|'])
        .flat_map(|line| line.split(" - "))
        .map(str::trim)
        .filter(|segment| segment.len() >= 12)
        .map(|segment| segment.trim_matches(|ch: char| ch == '-' || ch == '*' || ch == '•'))
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

fn classify_claim_type(event: Option<&SessionEventRecord>, segment: &str) -> Option<MemoryType> {
    let lower = segment.to_lowercase();
    let is_errorish = event.is_some_and(|evt| {
        evt.event_type == CanonicalEventType::Error
            || evt.payload.exit_code.is_some_and(|code| code != 0)
    }) || has_defect_signal(&lower);
    // Open questions need an explicit marker. A bare "?" used to be enough, which
    // turned every user prompt into an `open_question` memory and made a
    // question's own echo the top recall hit (FINDINGS F36). The hook-side
    // title filter hides the echo; this stops storing it in the first place.
    if has_explicit_question_marker(&lower) {
        return Some(MemoryType::OpenQuestion);
    }
    // Conversational decision wordings count only when the user wrote them
    // (prompt/annotation). Tool output and model replies keep needing the
    // literal "decision:" family so a grep hit on "going with" cannot mint a
    // decision (FINDINGS F38/F40).
    // A question-shaped sentence ("are you going with the default?") is never a
    // conversational decision or announcement.
    let user_authored = !lower.trim_end().ends_with('?')
        && event.is_some_and(|evt| {
            matches!(
                evt.event_type,
                CanonicalEventType::Prompt | CanonicalEventType::Annotation
            )
        });
    if lower.contains("decision:")
        || lower.contains("decision update")
        || lower.contains("we decided")
        || lower.contains("policy:")
        || (user_authored && has_conversational_decision_marker(&lower))
    {
        return Some(MemoryType::Decision);
    }
    if lower.contains("constraint:")
        || lower.contains("must ")
        || lower.contains("do not ")
        || lower.contains("should not ")
        || lower.contains("required")
        || lower.contains("fallback only")
    {
        return Some(MemoryType::Constraint);
    }
    if lower.contains("task:")
        || lower.contains("todo:")
        || lower.contains("next:")
        || lower.contains("follow up")
        || lower.contains("need to ")
        || lower.contains("continue ")
    {
        return Some(MemoryType::Task);
    }
    let explicit_fix_marker = [
        "fix:",
        "the fix was",
        "the fix is",
        "root cause",
        "workaround:",
        "verified fix",
        "confirmed fix",
        "fixed by",
    ]
    .iter()
    .any(|marker| lower.contains(marker));
    // A bare "fixed" / "resolved" is a fix only when the segment also names the
    // defect or the cause; "Page 6 is fixed and verified" is a status line,
    // not a fix (D5).
    let bare_fix_word = lower.contains("fixed") || lower.contains("resolved");
    if explicit_fix_marker || (bare_fix_word && (is_errorish || has_fix_context(&lower))) {
        return Some(MemoryType::Fix);
    }
    // Success-only status chatter ("smoke2 passed 4/4 no errors", "all green
    // now") carries no subject or decision; it is not a fact, bug or detail.
    // Only for text the engineer did not type: a user's own short statement
    // keeps its old typing.
    let typed_by_user = event.is_some_and(|evt| {
        matches!(
            evt.event_type,
            CanonicalEventType::Prompt | CanonicalEventType::Annotation
        )
    });
    if !typed_by_user && !is_errorish && is_status_only(&lower) {
        return None;
    }
    if is_errorish {
        return Some(MemoryType::Bug);
    }
    if lower.contains("verified")
        || lower.contains("confirmed")
        || lower.contains("current truth")
        || (user_authored && has_announcement_marker(&lower))
    {
        return Some(MemoryType::Fact);
    }
    if event.is_some_and(|evt| {
        matches!(
            evt.event_type,
            CanonicalEventType::Command
                | CanonicalEventType::ToolCall
                | CanonicalEventType::ToolResult
                | CanonicalEventType::FileChange
        )
    }) {
        return Some(MemoryType::ImplementationDetail);
    }
    None
}

/// Explicit open-question markers. `lower` is the lowercased segment.
fn has_explicit_question_marker(lower: &str) -> bool {
    [
        "open question:",
        "question:",
        "unknown whether",
        "unclear whether",
        "unclear if",
        "not sure whether",
        "not sure if",
        "still unclear",
        "undecided",
        "haven't decided",
        "have not decided",
        "still need to decide",
        "does anyone know",
        "do we know whether",
        "do we know if",
        "tbd:",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
}

/// Conversational ways engineers record a choice in a prompt ("I'm going with
/// X", "we settled on X", "went with X"). Only applied to user-authored text.
fn has_conversational_decision_marker(lower: &str) -> bool {
    [
        "decided:",
        "decided to ",
        "we decided",
        "decided on ",
        "we settled on",
        "settled on ",
        "i'm going with",
        "i am going with",
        "we're going with",
        "we are going with",
        "going with ",
        "we went with",
        "went with ",
        "we agreed",
        "agreed on ",
        "agreed to ",
        "let's go with",
        "lets go with",
        "for the record:",
        "for the record,",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
}

/// "Heads up, X is now Y" / "FYI: X" — a user telling the team a fact. Only
/// applied to user-authored text, and only after the more specific types.
fn has_announcement_marker(lower: &str) -> bool {
    ["heads up", "heads-up", "fyi:", "fyi,", "note that ", "note:"]
        .iter()
        .any(|marker| lower.contains(marker))
}

/// Assistant `response` events that close a turn: no later `response` before
/// the next user `prompt`. With the hooks every Stop event is one of these;
/// imported transcripts carry several replies per turn and only the last
/// counts.
fn final_answer_event_ids(events: &[SessionEventRecord]) -> HashSet<Uuid> {
    let mut finals = HashSet::new();
    let mut last_response: Option<Uuid> = None;
    for event in events {
        match event.event_type {
            CanonicalEventType::Response => last_response = Some(event.id),
            CanonicalEventType::Prompt => {
                if let Some(id) = last_response.take() {
                    finals.insert(id);
                }
            }
            _ => {}
        }
    }
    if let Some(id) = last_response {
        finals.insert(id);
    }
    finals
}

/// Max claims taken from one assistant answer.
const MAX_ASSISTANT_ANSWER_CLAIMS: usize = 4;

/// Claims from the assistant's final answer of a turn (recall review: the
/// facts engineers ask about live in answers, which were never a source).
/// Conservative: only decision / fix / fact segments with an explicit marker,
/// 30–400 chars, at most four per answer; stored as `model_derived` +
/// `inferred` with lower importance and confidence than user-confirmed text,
/// so a user's own statement always outranks and is never superseded by it
/// (reconcile only lets an equal-or-stronger claim supersede).
#[derive(Clone, Copy, PartialEq, Eq)]
enum ModelTextSource {
    /// The assistant's final answer of a turn: decision / fix / fact markers.
    FinalAnswer,
    /// A compaction summary injected as a prompt: decision markers only (D5).
    CompactionSummary,
}

fn extract_model_text_claims(
    session_id: Uuid,
    episode: Option<&SessionEpisodeDraft>,
    event: &SessionEventRecord,
    text: &str,
    source: ModelTextSource,
) -> Vec<DerivedMemoryDraft> {
    let (derivation, claim_source) = match source {
        ModelTextSource::FinalAnswer => ("assistant_answer_claim_v1", "assistant_final_answer"),
        ModelTextSource::CompactionSummary => ("compaction_summary_claim_v1", "compaction_summary"),
    };
    let cleaned = strip_template_noise(text);
    let mut claims = Vec::new();
    for segment in claim_segments(&cleaned) {
        if claims.len() >= MAX_ASSISTANT_ANSWER_CLAIMS {
            break;
        }
        let length = segment.chars().count();
        if !(30..=400).contains(&length) || looks_like_code_line(&segment) {
            continue;
        }
        let lower = segment.to_lowercase();
        if lower.trim_end().ends_with('?')
            || lower.contains("hypothesis")
            || lower.contains("guess")
            || lower.contains("might be")
            || lower.contains("maybe")
            || lower.contains("probably")
            || is_status_only(&lower)
        {
            continue;
        }
        let memory_type = if ["decision:", "decided:", "we decided", "policy:"]
            .iter()
            .any(|marker| lower.contains(marker))
        {
            MemoryType::Decision
        } else if source == ModelTextSource::CompactionSummary {
            continue;
        } else if ["fix:", "the fix was", "the fix is", "root cause", "fixed by"]
            .iter()
            .any(|marker| lower.contains(marker))
        {
            MemoryType::Fix
        } else if ["verified", "confirmed", "current truth"]
            .iter()
            .any(|marker| lower.contains(marker))
        {
            MemoryType::Fact
        } else {
            continue;
        };
        let claim_key = claim_key(memory_type, &segment, Some(event));
        claims.push(DerivedMemoryDraft {
            memory_type,
            title: claim_title(memory_type, &segment),
            content: truncate(segment.clone(), 3000),
            summary: truncate(segment.clone(), 300),
            importance_score: (claim_importance(memory_type, "inferred") - 0.08).max(0.2),
            confidence_score: 0.5,
            provenance_event_ids: vec![event.id],
            metadata: json!({
                "derivation": derivation,
                "sessionId": session_id,
                "episodeOrdinal": episode.map(|value| value.episode_ordinal),
                "episodeType": episode.map(|value| value.episode_type.clone()),
                "claimKey": claim_key,
                "claimPolarity": if is_negative_claim(&lower) { "negative" } else { "positive" },
                "claimSource": claim_source,
                "proofType": "session_event",
                "authorityClass": "model_derived",
                "verificationStatus": "inferred",
                "sourceClass": source_class_for_memory_type(memory_type),
                "rankingRole": ranking_role_for_memory_type(memory_type),
                "belief": { "admit": true },
                "answerCritical": true,
            }),
        });
    }
    claims
}

/// Tools whose captured text is file content (an edit/write input or a read
/// result), never a statement about the project. Their events originate no
/// claims at all.
fn is_file_content_tool_event(event: &SessionEventRecord) -> bool {
    if !matches!(
        event.event_type,
        CanonicalEventType::ToolCall | CanonicalEventType::ToolResult | CanonicalEventType::FileChange
    ) {
        return false;
    }
    let Some(tool) = event.payload.tool_name.as_deref() else {
        return false;
    };
    let tool = tool.trim().to_ascii_lowercase();
    [
        "edit",
        "write",
        "multiedit",
        "notebookedit",
        "read",
        "notebookread",
        "apply_patch",
        "str_replace_editor",
        "str_replace_based_edit_tool",
    ]
    .contains(&tool.as_str())
}

/// Source code, SQL, JSON and test-fixture lines (follow-up to D5: Bash
/// heredocs and pasted code were stored as fix/decision memories). A line
/// counts as code on strong syntax markers, a code-shaped start, an
/// indented identifier followed by call/assignment syntax, or a high share of
/// brackets, quotes and operators. Inline `code` spans are neutralised first,
/// so a prose sentence that mentions `foo::bar` is still prose.
pub fn looks_like_code_line(line: &str) -> bool {
    use regex::Regex;
    use std::sync::LazyLock;
    static INLINE_CODE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"`[^`]*`").unwrap());
    static CODE_START: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(concat!(
            r#"^(?://|/\*|\*/|#\[|#!|#include\b|"[^"]*"\s*[:,)\]]"#,
            r"|(?:let|const|var)\s+(?:mut\s+)?\w+\s*[:=]",
            r"|(?:fn|def|class|struct|enum|impl|mod|interface|type)\s+\w+\s*[(<:{=]",
            r"|(?:pub(?:\(crate\))?|async|export)\s+(?:fn|struct|enum|mod|use|const|crate|default|function|class|type|interface|async)\b",
            r"|use\s+[\w:]+::|(?:import|from)\s+[\w.]+(?:\s+import\b|\s*;|$)",
            r"|return\b.*;$|(?:if|for|while|match|switch)\s*\(|assert\w*!?\s*\(|\.\w+\s*\(|@\w+\s*\()",
        ))
        .unwrap()
    });
    static SQL_START: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            // Lower-case or upper-case keywords only: a capitalised "Set"
            // or "With" starts a sentence, not a query.
            r"^(?:select|insert\s+into|update|delete\s+from|create|alter|drop|with|from|where|and|or|order\s+by|group\s+by|having|limit|join|left\s+join|inner\s+join|values|returning|set|on\s+conflict|SELECT|INSERT\s+INTO|UPDATE|DELETE\s+FROM|CREATE|ALTER|DROP|WITH|FROM|WHERE|AND|OR|ORDER\s+BY|GROUP\s+BY|HAVING|LIMIT|JOIN|LEFT\s+JOIN|INNER\s+JOIN|VALUES|RETURNING|SET|ON\s+CONFLICT)\b",
        )
        .unwrap()
    });
    static SQL_SELECT: LazyLock<Regex> = LazyLock::new(|| {
        // A select list with a comma, star or call, or a FROM followed by a
        // clause keyword. "select the preset from the dropdown" stays prose.
        Regex::new(concat!(
            r"^(?:select\s[^.]*?[,*(][^.]*\sfrom\s+\w",
            r"|select\s.+\sfrom\s+[\w.]+(?:\s+\w+)?\s+(?:where|join|left|inner|order|group|limit)\b",
            r"|SELECT\s.+\sFROM\s+\w)",
        ))
        .unwrap()
    });
    static SQL_LITERAL: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?:^|[\s(=,])'[^']*'(?:$|[\s),;])").unwrap());
    static INDENTED_IDENT: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^(?:\t|\s{2,})[A-Za-z_][\w.]*(?:::\w+)*\s*(?:\(|=[^=]|\.\w|\[|:\s*$|\?)").unwrap()
    });
    // Never in prose: escaped newlines/quotes, JSON keys, closing tags,
    // shell heredocs, interpolation, SQL pattern matching.
    const DEFINITE: &[&str] = &[
        "\\n", "\\\"", "{\"", "</", "<<'", "<<\"", "<<eof", "${", " ilike ", " like '%",
    ];
    // Code-typical, but a quoting sentence can contain them.
    const LIKELY: &[&str] = &[
        "::", "=>", "\");", "\"),", "\"],", "\"},", "');", "();", "/>", "&&", "||", "!=", "==",
        "+=",
    ];
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return false;
    }
    let text = INLINE_CODE.replace_all(trimmed, "x");
    let text = text.replace("**", "").replace("__", "");
    let lower = text.to_lowercase();
    if DEFINITE.iter().any(|marker| lower.contains(marker))
        || CODE_START.is_match(&text)
        || INDENTED_IDENT.is_match(line)
        || SQL_SELECT.is_match(&text)
        || (SQL_START.is_match(&text)
            && (SQL_LITERAL.is_match(&text)
                || text.contains('=')
                || lower.contains("select *")
                || text.contains("(*)")
                || text.trim_end().ends_with(';')))
    {
        return true;
    }
    // A line opening with a bracket is a literal only with literal syntax in
    // it; "(Note: ...)" and "[Image #2] ..." are prose.
    if text.starts_with(['(', '[', '{', '}', ']', ')'])
        && (text.contains('"')
            || text.contains('=')
            || text.contains(';')
            || text.contains('{')
            || text.contains('}')
            || text.trim_end().ends_with([',', '(', '[', '{']))
    {
        return true;
    }
    // A line that reads as a sentence (mostly plain words) stays prose even
    // when it quotes something code-like.
    if reads_as_prose(&text) {
        return false;
    }
    if LIKELY.iter().any(|marker| lower.contains(marker)) {
        return true;
    }
    let non_space: Vec<char> = text.chars().filter(|ch| !ch.is_whitespace()).collect();
    if non_space.len() >= 8 {
        let symbols = non_space
            .iter()
            .filter(|ch| "(){}[]<>;=&\"\\$^~".contains(**ch))
            .count();
        if symbols * 100 >= non_space.len() * 15 {
            return true;
        }
    }
    let end = text.trim_end();
    end.ends_with('{')
        || end.ends_with('(')
        || end.ends_with('[')
        || end.ends_with("),")
        || end.ends_with("],")
        || end.ends_with("},")
        || end.ends_with("\",")
        || end.ends_with('\\')
        || (end.ends_with(';') && (text.contains('(') || text.contains('=') || text.contains('"')))
}

/// At least eight whitespace-separated tokens, 70% of them plain words.
fn reads_as_prose(text: &str) -> bool {
    let words: Vec<&str> = text.split_whitespace().collect();
    if words.len() < 8 {
        return false;
    }
    let plain = words
        .iter()
        .filter(|word| {
            let core = word.trim_matches(|ch: char| !ch.is_alphanumeric());
            core.chars().count() >= 2
                && core
                    .chars()
                    .all(|ch| ch.is_alphabetic() || matches!(ch, '\'' | '\u{2019}' | '-'))
        })
        .count();
    plain * 100 >= words.len() * 70
}

/// D5: text that reaches the store as a `prompt` event but was injected by
/// the client, not typed by the engineer: compaction summaries, slash-command
/// and skill bodies, background-task notifications, local-command echoes and
/// hook feedback. Checked on the start of the event text only, so a prompt
/// that merely quotes one of these later on is still classified normally.
fn is_compaction_summary(text: &str) -> bool {
    text.trim_start()
        .to_lowercase()
        .starts_with("this session is being continued from a previous conversation")
}

pub fn is_injected_event_text(text: &str) -> bool {
    use regex::Regex;
    use std::sync::LazyLock;
    static SLASH_COMMAND_BODY: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^#\s+/[a-z][\w:-]*(?:\s|$)").unwrap());
    static HOOK_FEEDBACK: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"^(?:stop|subagentstop|pretooluse|posttooluse|userpromptsubmit|sessionstart|sessionend|precompact|notification)(?::|\s+hook\b)",
        )
        .unwrap()
    });
    const PREFIXES: &[&str] = &[
        "this session is being continued from a previous conversation",
        "base directory for this skill:",
        "caveat: the messages below were generated by the user while running local commands",
        "[request interrupted by user",
        "<command-name>",
        "<command-message>",
        "<command-args>",
        "<task-notification>",
        "<local-command-caveat>",
        "<local-command-stdout>",
        "<local-command-stderr>",
        "<bash-input>",
        "<bash-stdout>",
        "<bash-stderr>",
        "<system-reminder>",
        "<user-prompt-submit-hook>",
        "<artifact-content-authored-by-others",
    ];
    let head: String = text.trim_start().chars().take(200).collect::<String>().to_lowercase();
    PREFIXES.iter().any(|prefix| head.starts_with(prefix))
        || SLASH_COMMAND_BODY.is_match(&head)
        || HOOK_FEEDBACK.is_match(&head)
}

/// Remove negated defect mentions ("no errors", "0 failed", "errors: 0",
/// "error-free") so a success report does not read as a bug.
fn strip_negated_defects(lower: &str) -> String {
    use regex::Regex;
    use std::sync::LazyLock;
    static NEGATED: LazyLock<Vec<Regex>> = LazyLock::new(|| {
        [
            r"\b(?:no|0|zero|without|never any)\s+(?:new\s+|more\s+|other\s+|remaining\s+)?(?:errors?|exceptions?|failures?|failed(?:\s+tests?)?|bugs?)\b",
            r"\b(?:errors?|failures?|failed|exceptions?)\s*[:=]\s*0\b",
            r"\berror[- ]free\b",
        ]
        .iter()
        .map(|pattern| Regex::new(pattern).unwrap())
        .collect()
    });
    let mut text = lower.to_string();
    for pattern in NEGATED.iter() {
        text = pattern.replace_all(&text, " ").into_owned();
    }
    text
}

/// A defect signal for bug typing: a failure/error/exception word that is not
/// negated, or an explicit "bug:" marker (D5: "smoke2 passed 4/4 no errors"
/// used to become a bug because it contains "error").
fn has_defect_signal(lower: &str) -> bool {
    let text = strip_negated_defects(lower);
    text.contains("failed")
        || text.contains("error")
        || text.contains("exception")
        || text.contains("bug:")
}

/// Words that tie a bare "fixed"/"resolved" to an actual defect or cause.
fn has_fix_context(lower: &str) -> bool {
    [
        "bug", "issue", "because", "caused", "due to", " by ", "regression", "crash", "broken",
        "leak", "race", "timeout", "deadlock", "flaky",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
}

/// Short success-only status lines with no subject or decision content:
/// "Page 6 is fixed and verified, and every suite passes.", "smoke2 passed
/// 4/4 no errors.", "All green, deployed." At most one content word may
/// remain once status words, filler and numbers are removed, and the line
/// must not carry a reason, a mechanism or a negated-away defect.
fn is_status_only(lower: &str) -> bool {
    const STATUS: &[&str] = &[
        "fixed", "verified", "confirmed", "passes", "passed", "passing", "pass", "done",
        "complete", "completed", "green", "works", "working", "succeeded", "succeeds",
        "successful", "successfully", "deployed", "merged", "pushed", "ready", "finished",
        "resolved", "ok", "okay", "landed", "shipped", "clean", "live",
    ];
    const FILLER: &[&str] = &[
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being", "and", "or", "but",
        "it", "its", "this", "that", "these", "those", "now", "all", "every", "everything",
        "each", "both", "has", "have", "had", "of", "on", "in", "at", "to", "for", "with", "i",
        "we", "you", "also", "still", "as", "expected", "so", "far", "too", "again", "already",
        "just", "fully", "looks", "look", "good", "great", "fine", "nice", "test", "tests",
        "suite", "suites", "check", "checks", "smoke", "result", "results", "run", "runs",
        "build", "builds", "ci", "lint", "typecheck", "no", "errors", "error", "failures",
        "failed", "warnings", "warning", "zero", "should", "will", "here", "there", "my", "our",
        "your", "me", "us", "they", "then", "and", "now", "yes", "both",
    ];
    if [
        "because", "since ", "instead", "so that", " by ", " via ", "`", "=", "->", "→",
        "root cause", "decid", "fix was", "fix is", "caused", "due to", "means",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
    {
        return false;
    }
    let text = strip_negated_defects(lower);
    if has_defect_signal(&text) {
        return false;
    }
    let tokens: Vec<&str> = text
        .split(|ch: char| !ch.is_alphanumeric())
        .filter(|token| !token.is_empty())
        .collect();
    if !tokens.iter().any(|token| STATUS.contains(token)) {
        return false;
    }
    let content_words = tokens
        .iter()
        .filter(|token| {
            token.chars().count() >= 2
                && !token.chars().all(|ch| ch.is_ascii_digit())
                && !STATUS.contains(token)
                && !FILLER.contains(token)
        })
        .count();
    content_words <= 1
}

/// D6: the time a derived memory refers to — the latest `created_at` among
/// its provenance events (the API maps that field from `session_events.
/// event_time`). `None` when no provenance event is known or parsable; the
/// caller then falls back to its old rule.
pub fn memory_source_time(
    draft: &DerivedMemoryDraft,
    events: &[SessionEventRecord],
) -> Option<String> {
    use time::OffsetDateTime;
    use time::format_description::well_known::Rfc3339;
    events
        .iter()
        .filter(|event| draft.provenance_event_ids.contains(&event.id))
        .filter_map(|event| OffsetDateTime::parse(&event.created_at, &Rfc3339).ok())
        .max()
        .and_then(|value| value.format(&Rfc3339).ok())
}

/// Drop template- and shell-shaped text before claim extraction (recall
/// review: `<summary>`/`<event>` blocks, `[structured-output-enforce]`
/// headers, the injected "## Context (established facts" block, `Bash |`
/// tool lines, `VAR=/path` assignments, bare shell commands and file-path
/// lists made up most of the stored "memories").
pub fn strip_template_noise(text: &str) -> String {
    use regex::Regex;
    use std::sync::LazyLock;
    static TAG_BLOCKS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
        [
            "summary",
            "event",
            "system-reminder",
            "command-output",
            "local-command-stdout",
            "local-command-stderr",
            "local-command-caveat",
            "command-name",
            "command-message",
            "command-args",
            "task-notification",
            "bash-input",
            "bash-stdout",
            "bash-stderr",
            "user-prompt-submit-hook",
        ]
            .iter()
            .map(|tag| Regex::new(&format!(r"(?is)<{tag}\b[^>]*>.*?(?:</{tag}>|\z)")).unwrap())
            .collect()
    });
    static ENV_ASSIGN: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=\S*/").unwrap());
    static FILE_TOKEN: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^[\w.~@-]*(?:/[\w.@-]*)+$|^[\w-]+\.[A-Za-z0-9]{1,5}$").unwrap());
    const SHELL_HEADS: &[&str] = &[
        "cd", "ls", "grep", "rg", "cat", "sed", "awk", "find", "git", "docker", "curl", "psql",
        "gcloud", "npm", "pnpm", "npx", "cargo", "python", "python3", "bash", "sh", "zsh",
        "export", "echo", "jq", "head", "tail", "kubectl", "make", "uv", "node", "gh", "ssh",
        "scp", "rm", "cp", "mv", "mkdir", "chmod", "sudo", "wc", "sort", "xargs", "tee", "env",
    ];

    let mut text = text.to_string();
    for block in TAG_BLOCKS.iter() {
        text = block.replace_all(&text, "\n").into_owned();
    }
    let mut kept = Vec::new();
    let mut in_context_block = false;
    let mut in_fence = false;
    for line in text.lines() {
        let trimmed = line.trim();
        // Fenced code blocks never carry a claim.
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence || looks_like_code_line(line) {
            continue;
        }
        let lower = trimmed.to_lowercase();
        if lower.starts_with("## context (established facts") {
            in_context_block = true;
            continue;
        }
        if in_context_block {
            if trimmed.starts_with('#') {
                in_context_block = false;
            } else {
                continue;
            }
        }
        if lower.contains("[structured-output-enforce]")
            || lower.starts_with("bash |")
            || lower.starts_with("bash|")
            || ENV_ASSIGN.is_match(trimmed)
        {
            continue;
        }
        let tokens: Vec<&str> = trimmed.split_whitespace().collect();
        if let Some(head) = tokens.first() {
            let head = head.trim_start_matches(['$', '>', '%']).trim();
            let shellish = tokens.iter().skip(1).any(|token| {
                token.contains('/')
                    || (token.starts_with('-') && token.len() > 1)
                    || matches!(*token, "|" | "&&" | "||" | ">" | ">>" | "2>&1")
            });
            if SHELL_HEADS.contains(&head) && shellish {
                continue;
            }
            if tokens.iter().any(|token| token.contains('/'))
                && tokens.iter().all(|token| {
                    FILE_TOKEN.is_match(token.trim_matches(|c: char| matches!(c, ',' | ';' | '`' | '"' | '\'')))
                })
            {
                continue;
            }
        }
        kept.push(line);
    }
    kept.join("\n")
}

fn classify_proof_type(event: Option<&SessionEventRecord>, from_summary: bool) -> &'static str {
    if from_summary {
        return "summary";
    }
    match event.map(|value| value.event_type) {
        Some(CanonicalEventType::Prompt | CanonicalEventType::Annotation) => "user_confirmation",
        Some(
            CanonicalEventType::ToolResult
            | CanonicalEventType::Command
            | CanonicalEventType::FileChange,
        ) => "tool_result",
        Some(CanonicalEventType::TestResult | CanonicalEventType::Error) => "test_result",
        _ => "session_event",
    }
}

fn classify_authority_class(
    event: Option<&SessionEventRecord>,
    proof_type: &str,
    from_summary: bool,
) -> &'static str {
    if from_summary {
        return "model_derived";
    }
    match proof_type {
        "user_confirmation" => "user_confirmed",
        "tool_result" => "tool_verified",
        "test_result" => "test_verified",
        _ => match event.map(|value| value.event_type) {
            // AgentMessage is structured assistant output; Reasoning and
            // TurnContext are defense-in-depth in case the hard gate is
            // bypassed (it should not be).
            Some(
                CanonicalEventType::Response
                | CanonicalEventType::AgentMessage
                | CanonicalEventType::Reasoning
                | CanonicalEventType::TurnContext,
            ) => "model_derived",
            _ => "session_derived",
        },
    }
}

fn classify_verification_status(
    lower: &str,
    event: Option<&SessionEventRecord>,
    from_summary: bool,
) -> &'static str {
    if lower.contains("hypothesis") || lower.contains("guess") || lower.contains("might be") {
        return "unverified";
    }
    if from_summary {
        return "inferred";
    }
    match event.map(|value| value.event_type) {
        Some(CanonicalEventType::Prompt | CanonicalEventType::Annotation) => "user_confirmed",
        Some(
            CanonicalEventType::ToolResult
            | CanonicalEventType::Command
            | CanonicalEventType::FileChange,
        ) => "verified",
        Some(CanonicalEventType::TestResult | CanonicalEventType::Error) => "verified",
        Some(CanonicalEventType::Response) => "inferred",
        _ => "inferred",
    }
}

fn should_admit_claim(
    memory_type: MemoryType,
    authority_class: &str,
    verification_status: &str,
    lower: &str,
) -> bool {
    if lower.contains("hypothesis") || lower.contains("guess") || lower.contains("might be") {
        return false;
    }
    let explicit_task_marker = ["task:", "todo:", "next:", "follow up", "continue "]
        .iter()
        .any(|marker| lower.contains(marker));
    let explicit_question_marker = has_explicit_question_marker(lower);
    match memory_type {
        MemoryType::Decision | MemoryType::Constraint => {
            matches!(verification_status, "user_confirmed" | "verified")
                && authority_class != "model_derived"
        }
        MemoryType::Task => {
            (matches!(verification_status, "user_confirmed" | "verified")
                || (verification_status == "inferred"
                    && authority_class == "session_derived"
                    && explicit_task_marker))
                && authority_class != "model_derived"
        }
        MemoryType::OpenQuestion => {
            (matches!(verification_status, "user_confirmed" | "verified")
                || (verification_status == "inferred"
                    && authority_class == "session_derived"
                    && explicit_question_marker))
                && authority_class != "model_derived"
        }
        MemoryType::Fact | MemoryType::Bug | MemoryType::Fix | MemoryType::ImplementationDetail => {
            matches!(verification_status, "verified" | "user_confirmed")
                || matches!(
                    authority_class,
                    "tool_verified" | "test_verified" | "user_confirmed"
                )
        }
        MemoryType::Summary | MemoryType::Risk | MemoryType::ChangeLog => false,
    }
}

fn claim_title(memory_type: MemoryType, segment: &str) -> String {
    let prefix = match memory_type {
        MemoryType::Fact => "Fact",
        MemoryType::Decision => "Decision",
        MemoryType::Task => "Task",
        MemoryType::Constraint => "Constraint",
        MemoryType::Bug => "Bug",
        MemoryType::Fix => "Fix",
        MemoryType::OpenQuestion => "Open question",
        MemoryType::Summary => "Summary",
        MemoryType::ImplementationDetail => "Implementation detail",
        MemoryType::ChangeLog => "Change log",
        MemoryType::Risk => "Risk",
    };
    format!("{prefix}: {}", truncate(strip_claim_prefixes(segment), 96))
}

fn claim_importance(memory_type: MemoryType, verification_status: &str) -> f64 {
    let base = match memory_type {
        MemoryType::Decision | MemoryType::Constraint | MemoryType::Fix => 0.92,
        MemoryType::Task | MemoryType::Bug | MemoryType::Fact => 0.86,
        MemoryType::OpenQuestion => 0.7,
        MemoryType::ImplementationDetail => 0.74,
        MemoryType::Summary | MemoryType::Risk | MemoryType::ChangeLog => 0.45,
    };
    match verification_status {
        "verified" | "user_confirmed" => base,
        "inferred" => (base - 0.12).max(0.2),
        "unverified" | "contradicted" => (base - 0.25).max(0.1),
        _ => base,
    }
}

fn claim_confidence(verification_status: &str, from_summary: bool) -> f64 {
    let base: f64 = match verification_status {
        "verified" => 0.9,
        "user_confirmed" => 0.86,
        "inferred" => 0.68,
        "contradicted" => 0.24,
        "unverified" => 0.2,
        _ => 0.5,
    };
    if from_summary {
        (base - 0.08).max(0.1)
    } else {
        base
    }
}

fn claim_key(memory_type: MemoryType, segment: &str, event: Option<&SessionEventRecord>) -> String {
    let anchor = event
        .and_then(|value| value.payload.file_path.clone())
        .unwrap_or_else(|| "global".to_string());
    let canonical = canonical_claim_text(strip_claim_prefixes(segment).as_str());
    format!(
        "{}:{}:{}",
        memory_type_str(memory_type),
        canonical_claim_text(&anchor),
        canonical
    )
}

fn canonical_claim_text(value: &str) -> String {
    value
        .to_lowercase()
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .filter(|token| token.len() >= 3)
        .take(10)
        .collect::<Vec<_>>()
        .join("_")
}

fn strip_claim_prefixes(value: &str) -> String {
    let lowered = value.trim();
    let prefixes = [
        "decision:",
        "decision update:",
        "task:",
        "todo:",
        "next:",
        "constraint:",
        "open question:",
        "question:",
        "bug:",
        "fix:",
        "fact:",
    ];
    for prefix in prefixes {
        if lowered.to_lowercase().starts_with(prefix) {
            return lowered[prefix.len()..].trim().to_string();
        }
    }
    lowered.to_string()
}

fn derivation_name(memory_type: MemoryType, from_summary: bool) -> &'static str {
    match (memory_type, from_summary) {
        (_, true) => "pckc_summary_claim_v1",
        (MemoryType::Decision, false) => "pckc_decision_claim_v1",
        (MemoryType::Task, false) => "pckc_task_claim_v1",
        (MemoryType::Constraint, false) => "pckc_constraint_claim_v1",
        (MemoryType::Bug, false) => "pckc_bug_claim_v1",
        (MemoryType::Fix, false) => "pckc_fix_claim_v1",
        (MemoryType::Fact, false) => "pckc_fact_claim_v1",
        (MemoryType::OpenQuestion, false) => "pckc_open_question_claim_v1",
        (MemoryType::ImplementationDetail, false) => "pckc_implementation_claim_v1",
        _ => "pckc_claim_v1",
    }
}

fn source_class_for_memory_type(memory_type: MemoryType) -> &'static str {
    match memory_type {
        MemoryType::Decision => "decision",
        MemoryType::Task => "task",
        MemoryType::Constraint => "constraint",
        MemoryType::Fact => "fact",
        MemoryType::Bug => "bug",
        MemoryType::Fix => "fix",
        MemoryType::OpenQuestion => "open_question",
        MemoryType::ImplementationDetail => "implementation_detail",
        MemoryType::Summary | MemoryType::ChangeLog => "session_summary",
        MemoryType::Risk => "risk",
    }
}

fn ranking_role_for_memory_type(memory_type: MemoryType) -> &'static str {
    match memory_type {
        MemoryType::Decision => "durable_decision",
        MemoryType::Task => "active_task",
        MemoryType::Constraint => "constraint_guardrail",
        MemoryType::Fact => "project_fact",
        MemoryType::Bug => "known_bug",
        MemoryType::Fix => "verified_fix",
        MemoryType::OpenQuestion => "open_question",
        MemoryType::ImplementationDetail => "implementation_note",
        MemoryType::Summary | MemoryType::ChangeLog => "summary_fallback",
        MemoryType::Risk => "risk",
    }
}

fn is_negative_claim(lower: &str) -> bool {
    [
        "do not",
        "should not",
        "not ",
        "disabled",
        "rejected",
        "fallback only",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
}

fn derive_reflection_memory(
    session_id: Uuid,
    episodes: &[SessionEpisodeDraft],
) -> Option<DerivedMemoryDraft> {
    if episodes.len() < 2 {
        return None;
    }

    // Use insertion-ordered map to match Node.js tie-breaking behavior:
    // Object.entries() returns keys in insertion order, and sort is stable,
    // so on ties the first-inserted key wins (conversation > implementation > debugging).
    let mut type_counts: IndexMap<String, u32> = IndexMap::new();
    type_counts.insert("conversation".to_string(), 0);
    type_counts.insert("implementation".to_string(), 0);
    type_counts.insert("debugging".to_string(), 0);
    for episode in episodes {
        *type_counts.entry(episode.episode_type.clone()).or_default() += 1;
    }

    // Sort descending by count; IndexMap preserves insertion order for equal elements
    let dominant_type = {
        let mut entries: Vec<_> = type_counts.iter().collect();
        entries.sort_by(|a, b| b.1.cmp(a.1));
        entries
            .first()
            .map(|(k, _)| (*k).clone())
            .unwrap_or_else(|| "conversation".to_string())
    };
    let recent = episodes.iter().rev().take(3).collect::<Vec<_>>();
    let unresolved_risk = has_trailing_debugging_without_implementation(episodes);
    let content = truncate(
        [
            format!("Dominant work mode: {dominant_type}"),
            format!(
                "Episode mix: conversation={}, implementation={}, debugging={}",
                type_counts.get("conversation").copied().unwrap_or_default(),
                type_counts
                    .get("implementation")
                    .copied()
                    .unwrap_or_default(),
                type_counts.get("debugging").copied().unwrap_or_default()
            ),
            format!(
                "Recent episode summaries: {}",
                recent
                    .iter()
                    .rev()
                    .map(|episode| truncate(episode.summary.clone(), 120))
                    .collect::<Vec<_>>()
                    .join(" || ")
            ),
            if unresolved_risk {
                "Risk: session ended with unresolved debugging context.".to_string()
            } else {
                "Risk: no unresolved debugging signal detected.".to_string()
            },
        ]
        .join("\n"),
        3000,
    );

    Some(DerivedMemoryDraft {
        memory_type: if unresolved_risk {
            MemoryType::Risk
        } else {
            MemoryType::Summary
        },
        title: if unresolved_risk {
            "Session reflection risk".to_string()
        } else {
            "Session reflection summary".to_string()
        },
        summary: truncate(content.clone(), 300),
        content,
        importance_score: if unresolved_risk { 0.82 } else { 0.68 },
        confidence_score: 0.72,
        provenance_event_ids: episodes
            .iter()
            .flat_map(|episode| episode.provenance_event_ids.iter().copied())
            .collect(),
        metadata: json!({
            "derivation": "session_reflection_v1",
            "sessionId": session_id,
            "dominantEpisodeType": dominant_type,
            "unresolvedRisk": unresolved_risk,
            "proofType": "summary",
            "authorityClass": "session_derived",
            "verificationStatus": "unverified",
            "sourceClass": "reflection",
            "rankingRole": "reflection_fallback",
            "belief": { "admit": false },
        }),
    })
}

#[derive(Debug, Clone)]
struct EpisodeBucket {
    episode_ordinal: i32,
    episode_type: String,
    events: Vec<SessionEventRecord>,
}

impl EpisodeBucket {
    fn new(episode_ordinal: i32, episode_type: String) -> Self {
        Self {
            episode_ordinal,
            episode_type,
            events: Vec::new(),
        }
    }
}

fn classify_event(event: &SessionEventRecord) -> String {
    let lower = event_text(event).to_lowercase();
    let is_errorish = event.event_type == CanonicalEventType::Error
        || event.payload.exit_code.is_some_and(|code| code != 0)
        || lower.contains("failed")
        || lower.contains("error")
        || lower.contains("exception");
    if is_errorish {
        return "debugging".to_string();
    }

    let is_impl = matches!(
        event.event_type,
        CanonicalEventType::Command
            | CanonicalEventType::ToolCall
            | CanonicalEventType::ToolResult
            | CanonicalEventType::FileChange
    ) || lower.contains("apply_patch");
    if is_impl {
        return "implementation".to_string();
    }

    "conversation".to_string()
}

fn should_start_new_episode(
    current_events: &[SessionEventRecord],
    next_event: &SessionEventRecord,
    next_type: &str,
) -> bool {
    if current_events.is_empty() {
        return false;
    }

    let previous = match current_events.last() {
        Some(previous) => previous,
        None => return false,
    };

    if classify_event(previous) != next_type {
        return true;
    }

    let previous_time = time::OffsetDateTime::parse(
        &previous.created_at,
        &time::format_description::well_known::Rfc3339,
    )
    .ok();
    let next_time = time::OffsetDateTime::parse(
        &next_event.created_at,
        &time::format_description::well_known::Rfc3339,
    )
    .ok();
    let gap_minutes = match (previous_time, next_time) {
        (Some(previous_time), Some(next_time)) => {
            let gap = next_time - previous_time;
            (gap.whole_seconds().max(0) as f64) / 60.0
        }
        _ => 0.0,
    };

    current_events.len() >= 8 || gap_minutes > 15.0
}

fn materialize_episode(session_id: Uuid, bucket: &EpisodeBucket) -> SessionEpisodeDraft {
    let texts = bucket
        .events
        .iter()
        .map(event_text)
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    let summary = truncate(texts.join("\n"), 3000);
    let first_text = texts
        .first()
        .cloned()
        .unwrap_or_else(|| bucket.episode_type.clone());
    let title = format!(
        "Episode {}: {} - {}",
        bucket.episode_ordinal,
        bucket.episode_type,
        truncate(first_text, 80)
    );

    SessionEpisodeDraft {
        episode_ordinal: bucket.episode_ordinal,
        episode_type: bucket.episode_type.clone(),
        title,
        summary,
        started_at: bucket
            .events
            .first()
            .map(|event| event.created_at.clone())
            .unwrap_or_else(now_rfc3339),
        ended_at: bucket
            .events
            .last()
            .map(|event| event.created_at.clone())
            .unwrap_or_else(now_rfc3339),
        provenance_event_ids: bucket.events.iter().map(|event| event.id).collect(),
        metadata: {
            use indexmap::IndexSet;
            let event_types: Vec<&str> = bucket
                .events
                .iter()
                .map(|event| canonical_event_type_str(event.event_type))
                .collect::<IndexSet<_>>()
                .into_iter()
                .collect();
            json!({
                "derivation": "session_episode_compaction_v1",
                "sessionId": session_id,
                "eventCount": bucket.events.len(),
                "eventTypes": event_types,
            })
        },
    }
}

fn canonical_event_type_str(event_type: CanonicalEventType) -> &'static str {
    match event_type {
        CanonicalEventType::Prompt => "prompt",
        CanonicalEventType::Response => "response",
        CanonicalEventType::ToolCall => "tool_call",
        CanonicalEventType::ToolResult => "tool_result",
        CanonicalEventType::FileChange => "file_change",
        CanonicalEventType::Command => "command",
        CanonicalEventType::TestResult => "test_result",
        CanonicalEventType::Summary => "summary",
        CanonicalEventType::Error => "error",
        CanonicalEventType::Annotation => "annotation",
        CanonicalEventType::Reasoning => "reasoning",
        CanonicalEventType::TurnContext => "turn_context",
        CanonicalEventType::AgentMessage => "agent_message",
    }
}

fn dedupe_derived_memories(memories: Vec<DerivedMemoryDraft>) -> Vec<DerivedMemoryDraft> {
    let mut keyed: IndexMap<String, DerivedMemoryDraft> = IndexMap::new();
    for memory in memories {
        let episode_ordinal = match memory.metadata.get("episodeOrdinal") {
            Some(Value::Number(n)) => n.to_string(),
            _ => "session".to_string(),
        };
        let type_str = memory_type_str(memory.memory_type);
        let claim_key = memory
            .metadata
            .get("claimKey")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let key = format!(
            "{type_str}:{episode_ordinal}:{claim_key}:{}:{}",
            memory.title, memory.summary
        );
        keyed.entry(key).or_insert(memory);
    }
    keyed.into_values().collect()
}

fn memory_type_str(memory_type: MemoryType) -> &'static str {
    match memory_type {
        MemoryType::Summary => "summary",
        MemoryType::Decision => "decision",
        MemoryType::Task => "task",
        MemoryType::Constraint => "constraint",
        MemoryType::Bug => "bug",
        MemoryType::Fix => "fix",
        MemoryType::OpenQuestion => "open_question",
        MemoryType::ImplementationDetail => "implementation_detail",
        MemoryType::Risk => "risk",
        MemoryType::Fact => "fact",
        MemoryType::ChangeLog => "change_log",
    }
}

fn normalize_error_signature(value: &str) -> String {
    use regex::Regex;
    use std::sync::LazyLock;

    static HEX_RUN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[0-9a-f]{7,}").unwrap());
    static WHITESPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());

    let lowered = value.to_lowercase();
    let without_hex = HEX_RUN.replace_all(&lowered, "");
    let collapsed = WHITESPACE.replace_all(&without_hex, " ");
    let trimmed = collapsed.trim();
    trimmed.chars().take(160).collect()
}

fn intersect_count(left: &[String], right: &[String]) -> usize {
    let right_set = right.iter().collect::<HashSet<_>>();
    left.iter()
        .filter(|value| right_set.contains(value))
        .count()
}

fn has_trailing_debugging_without_implementation(episodes: &[SessionEpisodeDraft]) -> bool {
    for episode in episodes.iter().rev() {
        if episode.episode_type == "implementation" {
            return false;
        }
        if episode.episode_type == "debugging" {
            return true;
        }
    }
    false
}

fn truncate(mut value: String, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value;
    }
    value = value.chars().take(max_chars).collect();
    value
}

fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}


#[cfg(test)]
mod tests {
    use super::*;
    use chum_mem_contracts::{CanonicalEventType, EndSessionRequest, SessionEventPayload};

    #[test]
    fn derives_atomic_bug_claim_for_debugging_session() {
        let session_id = Uuid::nil();
        let events = vec![
            SessionEventRecord {
                id: Uuid::from_u128(1),
                event_type: CanonicalEventType::Command,
                payload: SessionEventPayload {
                    command: Some("cargo test".to_string()),
                    ..SessionEventPayload::default()
                },
                created_at: "2026-04-10T00:00:00Z".to_string(),
            },
            SessionEventRecord {
                id: Uuid::from_u128(2),
                event_type: CanonicalEventType::Error,
                payload: SessionEventPayload {
                    message: Some("tests failed".to_string()),
                    ..SessionEventPayload::default()
                },
                created_at: "2026-04-10T00:01:00Z".to_string(),
            },
        ];
        let end_request = EndSessionRequest {
            session_id,
            summary: None,
            metadata: json!({}),
            defer: None,
        };

        let memories =
            derive_memories_from_session(session_id, "codex", &end_request, &events, None);

        assert!(
            memories
                .iter()
                .any(|memory| memory.memory_type == MemoryType::Bug)
        );
    }

    #[test]
    fn rejects_model_derived_open_question_from_response() {
        let session_id = Uuid::nil();
        let events = vec![SessionEventRecord {
            id: Uuid::from_u128(3),
            event_type: CanonicalEventType::Response,
            payload: SessionEventPayload {
                message: Some(
                    "Open question: maybe the reranker should ignore summaries?".to_string(),
                ),
                ..SessionEventPayload::default()
            },
            created_at: "2026-04-10T00:02:00Z".to_string(),
        }];
        let end_request = EndSessionRequest {
            session_id,
            summary: None,
            metadata: json!({}),
            defer: None,
        };

        let memories =
            derive_memories_from_session(session_id, "codex", &end_request, &events, None);

        assert!(!memories.iter().any(|memory| {
            memory.memory_type == MemoryType::OpenQuestion
                && memory
                    .metadata
                    .get("belief")
                    .and_then(|value| value.get("admit"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
        }));
    }

    #[test]
    fn admits_explicit_task_from_user_prompt() {
        let session_id = Uuid::nil();
        let events = vec![SessionEventRecord {
            id: Uuid::from_u128(4),
            event_type: CanonicalEventType::Prompt,
            payload: SessionEventPayload {
                message: Some("Task: finish the proof compiler for context_build.".to_string()),
                ..SessionEventPayload::default()
            },
            created_at: "2026-04-10T00:03:00Z".to_string(),
        }];
        let end_request = EndSessionRequest {
            session_id,
            summary: None,
            metadata: json!({}),
            defer: None,
        };

        let memories =
            derive_memories_from_session(session_id, "codex", &end_request, &events, None);

        assert!(memories.iter().any(|memory| {
            memory.memory_type == MemoryType::Task
                && memory
                    .metadata
                    .get("belief")
                    .and_then(|value| value.get("admit"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
        }));
    }

    // ── v2.2.1 belief gate tests ────────────────────────────────────

    fn end_request_default(session_id: Uuid) -> EndSessionRequest {
        EndSessionRequest {
            session_id,
            summary: None,
            metadata: json!({}),
            defer: None,
        }
    }

    #[test]
    fn reasoning_event_never_originates_a_claim() {
        // Even when the reasoning text explicitly contains "Decision: ..." —
        // the belief gate must reject it by construction.
        let session_id = Uuid::nil();
        let events = vec![SessionEventRecord {
            id: Uuid::from_u128(10),
            event_type: CanonicalEventType::Reasoning,
            payload: SessionEventPayload {
                message: Some(
                    "Decision: switch to weighted set-cover for context_compile.".to_string(),
                ),
                ..SessionEventPayload::default()
            },
            created_at: "2026-04-15T00:00:00Z".to_string(),
        }];

        let memories = derive_memories_from_session(
            session_id,
            "codex",
            &end_request_default(session_id),
            &events,
            None,
        );

        // No memories whose provenance references the reasoning event,
        // and definitely no admitted decision.
        assert!(!memories.iter().any(|memory| {
            memory.memory_type == MemoryType::Decision
                && memory.provenance_event_ids.contains(&Uuid::from_u128(10))
        }));
    }

    #[test]
    fn turn_context_event_never_originates_a_claim() {
        let session_id = Uuid::nil();
        let events = vec![SessionEventRecord {
            id: Uuid::from_u128(11),
            event_type: CanonicalEventType::TurnContext,
            payload: SessionEventPayload {
                message: Some("Task: finish the proof compiler for context_build.".to_string()),
                ..SessionEventPayload::default()
            },
            created_at: "2026-04-15T00:01:00Z".to_string(),
        }];

        let memories = derive_memories_from_session(
            session_id,
            "codex",
            &end_request_default(session_id),
            &events,
            None,
        );

        assert!(!memories.iter().any(|memory| {
            memory.memory_type == MemoryType::Task
                && memory.provenance_event_ids.contains(&Uuid::from_u128(11))
        }));
    }

    #[test]
    fn agent_message_rejected_without_user_confirmation() {
        // AgentMessage routes through the classifier chain and lands in
        // authority_class=model_derived, verification=inferred — which
        // should_admit_claim rejects for every durable type.
        let session_id = Uuid::nil();
        let events = vec![SessionEventRecord {
            id: Uuid::from_u128(12),
            event_type: CanonicalEventType::AgentMessage,
            payload: SessionEventPayload {
                message: Some("Decision: use tokio::select for the worker scheduler.".to_string()),
                ..SessionEventPayload::default()
            },
            created_at: "2026-04-15T00:02:00Z".to_string(),
        }];

        let memories = derive_memories_from_session(
            session_id,
            "codex",
            &end_request_default(session_id),
            &events,
            None,
        );

        assert!(!memories.iter().any(|memory| {
            memory.memory_type == MemoryType::Decision
                && memory
                    .metadata
                    .get("belief")
                    .and_then(|value| value.get("admit"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
        }));
    }

    // ── Review 2026-10-09: classifier wordings (F38/F40) and prompt echoes (F36) ──

    fn single_event(event_type: CanonicalEventType, message: &str) -> Vec<SessionEventRecord> {
        vec![SessionEventRecord {
            id: Uuid::from_u128(99),
            event_type,
            payload: SessionEventPayload {
                message: Some(message.to_string()),
                ..SessionEventPayload::default()
            },
            created_at: "2026-10-09T00:00:00Z".to_string(),
        }]
    }

    fn admitted_types(events: &[SessionEventRecord]) -> Vec<MemoryType> {
        let session_id = Uuid::nil();
        derive_memories_from_session(session_id, "claude", &end_request_default(session_id), events, None)
            .into_iter()
            .filter(|memory| {
                memory
                    .metadata
                    .get("belief")
                    .and_then(|value| value.get("admit"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
            })
            .map(|memory| memory.memory_type)
            .collect()
    }

    #[test]
    fn conversational_decision_wordings_in_prompts_derive_decisions() {
        for wording in [
            "I'm going with Cloud Tasks for the class-record import retries.",
            "We settled on 25 students per /process-answers request.",
            "Decided: the DepEd answer sheet is A4.",
            "We went with a 60 second rubrics timeout after looking at the p99.",
            "For the record: hotfixes branch from production-patch only.",
        ] {
            let events = single_event(CanonicalEventType::Prompt, wording);
            let types = admitted_types(&events);
            assert!(
                types.contains(&MemoryType::Decision),
                "expected a decision for {wording:?}, got {types:?}"
            );
        }
    }

    #[test]
    fn conversational_decision_wordings_in_tool_output_do_not_derive_decisions() {
        let events = single_event(
            CanonicalEventType::ToolResult,
            "README: going with the default settings is recommended for most users.",
        );
        let types = admitted_types(&events);
        assert!(
            !types.contains(&MemoryType::Decision),
            "tool output must not mint a decision, got {types:?}"
        );
    }

    #[test]
    fn question_shaped_prompt_with_decision_phrase_is_not_a_decision() {
        let events = single_event(
            CanonicalEventType::Prompt,
            "Are we going with Celery or Cloud Tasks for the retries?",
        );
        let types = admitted_types(&events);
        assert!(types.is_empty(), "expected no claim, got {types:?}");
    }

    #[test]
    fn heads_up_announcement_in_prompt_derives_a_fact() {
        let events = single_event(
            CanonicalEventType::Prompt,
            "Heads up, the rubrics request timeout is now 60 seconds in ai_utils.",
        );
        let types = admitted_types(&events);
        assert!(
            types.contains(&MemoryType::Fact),
            "expected a fact, got {types:?}"
        );
    }

    #[test]
    fn heads_up_with_constraint_wording_keeps_the_more_specific_type() {
        let events = single_event(
            CanonicalEventType::Prompt,
            "Heads up: do not deploy gradechum-api on Fridays.",
        );
        let types = admitted_types(&events);
        assert!(
            types.contains(&MemoryType::Constraint) && !types.contains(&MemoryType::Fact),
            "expected a constraint only, got {types:?}"
        );
    }

    #[test]
    fn bare_question_prompt_is_not_stored_as_open_question() {
        let events = single_event(
            CanonicalEventType::Prompt,
            "Where are we running the DepEd answer-sheet export pilot, and who decided?",
        );
        let types = admitted_types(&events);
        assert!(
            !types.contains(&MemoryType::OpenQuestion),
            "a bare question must not become an open_question echo, got {types:?}"
        );
    }

    #[test]
    fn explicit_open_question_marker_in_prompt_is_still_stored() {
        let events = single_event(
            CanonicalEventType::Prompt,
            "Open question: should the extractor move off Vertex global?",
        );
        let types = admitted_types(&events);
        assert!(
            types.contains(&MemoryType::OpenQuestion),
            "expected an open question, got {types:?}"
        );
    }

    #[test]
    fn question_mark_inside_tool_output_is_not_an_open_question() {
        let events = single_event(
            CanonicalEventType::ToolResult,
            "GET /v1/tasks/?ordering=-datetime_created returned 200 in 81 ms.",
        );
        let types = admitted_types(&events);
        assert!(
            !types.contains(&MemoryType::OpenQuestion),
            "a query string must not become an open question, got {types:?}"
        );
    }

    fn event_at(id: u128, event_type: CanonicalEventType, message: &str) -> SessionEventRecord {
        SessionEventRecord {
            id: Uuid::from_u128(id),
            event_type,
            payload: SessionEventPayload {
                message: Some(message.to_string()),
                ..SessionEventPayload::default()
            },
            created_at: format!("2026-10-09T00:00:{:02}Z", id % 60),
        }
    }

    fn admitted(events: &[SessionEventRecord]) -> Vec<DerivedMemoryDraft> {
        let session_id = Uuid::nil();
        derive_memories_from_session(session_id, "claude", &end_request_default(session_id), events, None)
            .into_iter()
            .filter(|memory| {
                memory
                    .metadata
                    .get("belief")
                    .and_then(|value| value.get("admit"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
            })
            .collect()
    }

    #[test]
    fn status_chit_chat_is_not_an_open_question_but_real_unknowns_are() {
        let chit_chat = single_event(CanonicalEventType::Prompt, "what's the status now?");
        assert!(admitted_types(&chit_chat).is_empty());
        let unknown = single_event(
            CanonicalEventType::Prompt,
            "Does anyone know whether the extractor still runs on Vertex global?",
        );
        assert!(admitted_types(&unknown).contains(&MemoryType::OpenQuestion));
        let undecided = single_event(
            CanonicalEventType::Prompt,
            "We are still undecided on the DepEd export host for the pilot.",
        );
        assert!(admitted_types(&undecided).contains(&MemoryType::OpenQuestion));
    }

    #[test]
    fn template_and_shell_shaped_text_is_dropped() {
        let text = "<summary>Fixed the build. We decided to ship.</summary>\n\
[structured-output-enforce] Decision: must reply in JSON\n\
## Context (established facts\n\
- Decision: customers get refunds within 3 days\n\
## Next\n\
Bash | grep -rn fixed src/\n\
TURBOVEC_PATH=/data/turbovec\n\
cd /private/tmp/x && cargo test --release 2>&1 | tail\n\
src/a.rs src/b.rs docs/c.md\n\
Decision: hotfixes branch from production-patch only.";
        let cleaned = strip_template_noise(text);
        assert_eq!(cleaned.trim(), "## Next\nDecision: hotfixes branch from production-patch only.");
        let events = single_event(CanonicalEventType::Prompt, text);
        let drafts = admitted(&events);
        assert_eq!(drafts.len(), 1, "got {:?}", drafts.iter().map(|d| &d.title).collect::<Vec<_>>());
        assert_eq!(drafts[0].memory_type, MemoryType::Decision);
    }

    #[test]
    fn prose_mentioning_git_is_kept() {
        let cleaned = strip_template_noise("git push is denied in these repos; use the gh API instead.");
        assert!(cleaned.contains("git push is denied"));
    }

    #[test]
    fn fix_markers_in_prompts() {
        for wording in [
            "The fix was raising the express.json body limit to 25mb in server.js.",
            "Root cause: Puppeteer's 30 second timeout on 40+ page exams.",
        ] {
            let events = single_event(CanonicalEventType::Prompt, wording);
            assert!(
                admitted_types(&events).contains(&MemoryType::Fix),
                "expected a fix for {wording:?}"
            );
        }
    }

    #[test]
    fn final_assistant_answer_is_a_lower_authority_claim_source() {
        let events = vec![
            event_at(1, CanonicalEventType::Prompt, "Why did the Android upload fail with 413?"),
            event_at(
                2,
                CanonicalEventType::Response,
                "Looking at server.js now. The fix was raising the body limit.",
            ),
            event_at(
                3,
                CanonicalEventType::Response,
                "Root cause: express.json defaults to a 1mb body limit in gradechum-mobile-file-upload. Maybe we should also log sizes.",
            ),
        ];
        let drafts = admitted(&events);
        let from_answer: Vec<_> = drafts
            .iter()
            .filter(|d| d.metadata.get("claimSource").and_then(Value::as_str) == Some("assistant_final_answer"))
            .collect();
        assert_eq!(from_answer.len(), 1, "only the final reply counts: {:?}",
            drafts.iter().map(|d| &d.title).collect::<Vec<_>>());
        let claim = from_answer[0];
        assert_eq!(claim.memory_type, MemoryType::Fix);
        assert!(claim.content.contains("express.json"));
        assert_eq!(claim.metadata["authorityClass"], "model_derived");
        assert_eq!(claim.metadata["verificationStatus"], "inferred");
        assert!(claim.confidence_score < 0.86 && claim.importance_score < 0.92);
        // The intermediate reply contributes nothing.
        assert!(!drafts.iter().any(|d| d.provenance_event_ids == vec![Uuid::from_u128(2)]));
    }

    #[test]
    fn assistant_answer_without_marker_or_with_hedge_derives_nothing() {
        let events = vec![
            event_at(1, CanonicalEventType::Prompt, "Which rubric model should we use?"),
            event_at(
                2,
                CanonicalEventType::Response,
                "Gemini 3.5 Flash Lite is about twice as fast as 3.7 Flash on the harness. Decision: probably 3.5 Flash Lite, but it might be thinner on math.",
            ),
        ];
        let drafts = admitted(&events);
        assert!(
            !drafts.iter().any(|d| d.metadata.get("claimSource").and_then(Value::as_str) == Some("assistant_final_answer")),
            "got {:?}", drafts.iter().map(|d| &d.title).collect::<Vec<_>>()
        );
    }

    #[test]
    fn final_answer_ids_close_each_turn() {
        let events = vec![
            event_at(1, CanonicalEventType::Prompt, "q1 prompt text"),
            event_at(2, CanonicalEventType::Response, "a1 part one"),
            event_at(3, CanonicalEventType::ToolResult, "tool output"),
            event_at(4, CanonicalEventType::Response, "a1 final"),
            event_at(5, CanonicalEventType::Prompt, "q2 prompt text"),
            event_at(6, CanonicalEventType::Response, "a2 final"),
        ];
        let finals = final_answer_event_ids(&events);
        assert_eq!(finals, [Uuid::from_u128(4), Uuid::from_u128(6)].into_iter().collect());
    }

    // ── D5: injected boilerplate, defect signal for bug/fix, status chatter ──

    #[test]
    fn injected_boilerplate_events_originate_no_claims() {
        let cases = [
            (CanonicalEventType::Prompt, "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion.\n\nWe should use the blue queue.\nThe fix was raising the timeout because uploads failed.\nPlease continue the conversation from where we left it off."),
            (CanonicalEventType::Prompt, "Base directory for this skill: /tmp/skills/demo\n\n# Demo skill\nMust follow a user message and must be the last block.\nEscalate after 3 failed attempts."),
            (CanonicalEventType::Prompt, "# /loop — schedule a recurring or self-paced prompt\n\nYou must parse the interval. Do not run more than once per minute."),
            (CanonicalEventType::Command, "<command-name>/rename</command-name>\n<command-message>rename</command-message>\n<command-args>Demo Session Name</command-args>"),
            (CanonicalEventType::Prompt, "<task-notification>\n<task-id>abc123</task-id>\n<result>Fixed the widget bug because the cache key was wrong. Decision: keep the cache.</result>\n</task-notification>"),
            (CanonicalEventType::Prompt, "<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages.</local-command-caveat>"),
            (CanonicalEventType::Prompt, "Stop hook feedback:\nYou must run the tests before stopping; 2 failed."),
            (CanonicalEventType::Prompt, "<system-reminder>Decision: the build must stay green.</system-reminder>"),
        ];
        for (event_type, text) in cases {
            let events = single_event(event_type, text);
            let drafts = admitted(&events);
            assert!(
                drafts.is_empty(),
                "boilerplate must not originate claims: {:?} -> {:?}",
                &text[..40.min(text.len())],
                drafts.iter().map(|d| &d.title).collect::<Vec<_>>()
            );
        }
    }

    #[test]
    fn compaction_summary_keeps_only_explicit_decisions_at_model_authority() {
        let events = single_event(
            CanonicalEventType::Prompt,
            "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion.\n\n\
- Final decision: the widget service uses the blue queue for every export.\n\
- The fix was raising the timeout because uploads failed.\n\
- Page 6 is fixed and verified.\n\
- You must keep answers short.\n\
Please continue the conversation from where we left it off without asking the user any further questions.",
        );
        let drafts = admitted(&events);
        assert_eq!(drafts.len(), 1, "got {:?}", drafts.iter().map(|d| &d.title).collect::<Vec<_>>());
        let decision = &drafts[0];
        assert_eq!(decision.memory_type, MemoryType::Decision);
        assert!(decision.content.contains("blue queue"));
        assert_eq!(decision.metadata["claimSource"], "compaction_summary");
        assert_eq!(decision.metadata["authorityClass"], "model_derived");
        assert_eq!(decision.metadata["verificationStatus"], "inferred");
    }

    #[test]
    fn injected_detection_only_looks_at_the_start() {
        assert!(!is_injected_event_text(
            "Decision: drop lines like 'This session is being continued from a previous conversation' before extraction."
        ));
        assert!(!is_injected_event_text("# Release notes for the widget service"));
        assert!(!is_injected_event_text("Stop the worker before running the backfill."));
        assert!(is_injected_event_text("  # /review-all-changes\nRun lint checks."));
        let events = single_event(
            CanonicalEventType::Prompt,
            "Decision: drop lines like 'This session is being continued from a previous conversation' before extraction.",
        );
        assert!(admitted_types(&events).contains(&MemoryType::Decision));
    }

    #[test]
    fn real_decisions_are_kept_alongside_boilerplate() {
        let events = vec![
            event_at(1, CanonicalEventType::Prompt, "This session is being continued from a previous conversation that ran out of context. Decision: use Redis."),
            event_at(2, CanonicalEventType::Prompt, "I'm going with Cloud Tasks for the import retries because Celery has no retry visibility."),
            event_at(3, CanonicalEventType::Prompt, "Decision: widget exports are A4 only."),
            event_at(4, CanonicalEventType::Response, "Page 6 is fixed and verified, and every suite passes."),
        ];
        let drafts = admitted(&events);
        let decisions: Vec<_> = drafts
            .iter()
            .filter(|d| d.memory_type == MemoryType::Decision)
            .map(|d| d.content.clone())
            .collect();
        assert_eq!(decisions.len(), 2, "got {decisions:?}");
        assert!(decisions.iter().any(|c| c.contains("Cloud Tasks")));
        assert!(decisions.iter().any(|c| c.contains("A4")));
        // The compaction summary's short "Decision: use Redis." is under the
        // 30-char floor for model-written text, so nothing comes from it.
        assert!(!drafts.iter().any(|d| d.content.contains("Redis")));
        assert!(!drafts.iter().any(|d| d.provenance_event_ids == vec![Uuid::from_u128(4)]));
    }

    #[test]
    fn success_reports_are_not_bugs() {
        for (event_type, text) in [
            (CanonicalEventType::Prompt, "smoke2 passed 4/4 no errors."),
            (CanonicalEventType::ToolResult, "test result: ok. 12 passed; 0 failed; 0 ignored"),
            (CanonicalEventType::ToolResult, "Lint finished with zero errors and errors: 0 warnings: 3"),
            (CanonicalEventType::Response, "All checks passed without errors on the second run."),
        ] {
            let events = single_event(event_type, text);
            let types = admitted_types(&events);
            assert!(
                !types.contains(&MemoryType::Bug) && !types.contains(&MemoryType::Fix),
                "{text:?} must not be a bug/fix, got {types:?}"
            );
        }
    }

    #[test]
    fn real_defects_are_still_bugs_and_fixes() {
        let bug = single_event(
            CanonicalEventType::ToolResult,
            "TypeError: cannot read properties of undefined (reading 'score') in grade.ts",
        );
        assert!(admitted_types(&bug).contains(&MemoryType::Bug));
        let partial = single_event(
            CanonicalEventType::ToolResult,
            "test result: FAILED. 11 passed; 1 failed; 0 ignored",
        );
        assert!(admitted_types(&partial).contains(&MemoryType::Bug));
        let fix = single_event(
            CanonicalEventType::Prompt,
            "Fixed the 413 on Android uploads by raising the body limit to 25mb.",
        );
        assert!(admitted_types(&fix).contains(&MemoryType::Fix));
        let status = single_event(CanonicalEventType::ToolResult, "Page 6 is fixed.");
        assert!(!admitted_types(&status).contains(&MemoryType::Fix));
    }

    #[test]
    fn status_only_detection() {
        for line in [
            "page 6 is fixed and verified, and every suite passes.",
            "smoke2 passed 4/4 no errors.",
            "all green, deployed and verified.",
        ] {
            assert!(is_status_only(line), "{line:?} should be status-only");
        }
        for line in [
            "verified: the rubric endpoint returns 400 when no answer key arrives within 65 seconds.",
            "the extractor is fixed because the vertex region moved to us-central1.",
            "tests failed on the widget page.",
            "decision: we use the widget queue.",
        ] {
            assert!(!is_status_only(line), "{line:?} should not be status-only");
        }
        // Substantive assistant facts are still taken.
        let events = vec![
            event_at(1, CanonicalEventType::Prompt, "What does the rubric endpoint do without a key?"),
            event_at(
                2,
                CanonicalEventType::Response,
                "Verified: the rubric endpoint returns 400 when no answer key arrives within 65 seconds.",
            ),
        ];
        assert!(admitted(&events).iter().any(|d| d.memory_type == MemoryType::Fact
            && d.metadata.get("claimSource").and_then(Value::as_str) == Some("assistant_final_answer")));
    }

    // ── D6: a memory is dated at its source event, not the session end ──

    #[test]
    fn memory_time_is_the_source_event_time() {
        let mut first = event_at(1, CanonicalEventType::Prompt, "Decision: widget exports are A4 only.");
        first.created_at = "2026-10-02T09:15:00Z".to_string();
        let mut second = event_at(2, CanonicalEventType::Prompt, "Constraint: never deploy the widget API on Fridays.");
        second.created_at = "2026-10-05T14:00:00.250Z".to_string();
        let mut last = event_at(3, CanonicalEventType::Prompt, "thanks, that is all for today");
        last.created_at = "2026-10-09T18:00:00Z".to_string();
        let events = vec![first, second, last];
        let drafts = admitted(&events);
        let time_of = |needle: &str| {
            let draft = drafts.iter().find(|d| d.content.contains(needle)).expect(needle);
            memory_source_time(draft, &events)
        };
        assert_eq!(time_of("A4").as_deref(), Some("2026-10-02T09:15:00Z"));
        assert_eq!(time_of("Fridays").as_deref(), Some("2026-10-05T14:00:00.25Z"));

        // Several provenance events: the latest one; none known: None.
        let mut multi = drafts[0].clone();
        multi.provenance_event_ids = vec![Uuid::from_u128(1), Uuid::from_u128(2)];
        assert_eq!(memory_source_time(&multi, &events).as_deref(), Some("2026-10-05T14:00:00.25Z"));
        multi.provenance_event_ids = vec![Uuid::from_u128(77)];
        assert_eq!(memory_source_time(&multi, &events), None);
    }

    // ── D5 follow-up: code-shaped content from tool calls is not a memory ──

    fn tool_event(
        id: u128,
        event_type: CanonicalEventType,
        tool: &str,
        command: Option<&str>,
        message: Option<&str>,
    ) -> SessionEventRecord {
        SessionEventRecord {
            id: Uuid::from_u128(id),
            event_type,
            payload: SessionEventPayload {
                tool_name: Some(tool.to_string()),
                command: command.map(str::to_string),
                message: message.map(str::to_string),
                ..SessionEventPayload::default()
            },
            created_at: format!("2026-10-10T00:00:{:02}Z", id % 60),
        }
    }

    fn admitted_contents(events: &[SessionEventRecord]) -> Vec<(MemoryType, String)> {
        admitted(events)
            .into_iter()
            .map(|d| (d.memory_type, d.content))
            .collect()
    }

    #[test]
    fn rust_test_tuple_in_a_bash_heredoc_is_not_a_fix() {
        let command = r#"python3 - <<'PY'
p='derivation.rs'; s=open(p).read()
cases = """
            (CanonicalEventType::Prompt, "<task-notification>\n<task-id>abc123</task-id>\n<result>Fixed the widget bug because the cache key was wrong. Decision: keep the cache.</result>\n</task-notification>"),
"""
open(p,'w').write(s)
PY"#;
        let events = vec![tool_event(1, CanonicalEventType::ToolResult, "Bash", Some(command), Some("Bash"))];
        let got = admitted_contents(&events);
        assert!(got.is_empty(), "got {got:?}");
    }

    #[test]
    fn sql_in_a_bash_heredoc_is_not_a_fix() {
        let command = r#"timeout 60 psql <<'SQL'
select type, left(regexp_replace(content,'\s+',' ','g'),90) c from memories where superseded_at is null
 and (content ilike '%session is being continued%' or content ilike '# /loop%' or content ilike '%is fixed and verified%') limit 40;
SQL"#;
        let events = vec![tool_event(2, CanonicalEventType::ToolResult, "Bash", Some(command), Some("Bash"))];
        let got = admitted_contents(&events);
        assert!(got.is_empty(), "got {got:?}");
    }

    #[test]
    fn fixture_tuples_are_not_decisions() {
        let command = r#"cat > e2e.py <<'PY'
E = [
 ("2026-10-03T10:05:00Z", "prompt",  {"message": "Base directory for this skill: /tmp/skills/widget-demo\n\nMust follow a user message. Do not edit generated files."}),
 ("2026-10-06T13:00:00Z", "prompt",  {"message": "Decision: widget API deploys only on Tuesdays and Thursdays."}),
 ("2026-10-07T14:00:00Z", "prompt",  {"message": "Constraint: never deploy the widget API on Fridays."}),
]
PY"#;
        let events = vec![tool_event(3, CanonicalEventType::ToolResult, "Bash", Some(command), Some("Bash"))];
        let got = admitted_contents(&events);
        assert!(got.is_empty(), "got {got:?}");
        // The same fixture pasted into a prompt is also not a decision.
        let pasted = single_event(
            CanonicalEventType::Prompt,
            r#" ("2026-10-06T13:00:00Z", "prompt",  {"message": "Decision: widget API deploys only on Tuesdays and Thursdays."}),"#,
        );
        assert!(admitted_types(&pasted).is_empty());
    }

    #[test]
    fn file_content_tools_originate_no_claims() {
        let events = vec![
            tool_event(4, CanonicalEventType::ToolCall, "Edit", None, Some("Decision: widget exports are A4 only. The fix was raising the timeout.")),
            tool_event(5, CanonicalEventType::ToolResult, "Write", None, Some("Constraint: never deploy on Fridays.")),
            tool_event(6, CanonicalEventType::ToolResult, "Read", None, Some("Root cause: the renderer waited 30 seconds for fonts.")),
            tool_event(7, CanonicalEventType::ToolResult, "MultiEdit", None, Some("Decision: keep the cache.")),
            tool_event(8, CanonicalEventType::ToolResult, "NotebookEdit", None, Some("Decision: keep the notebook.")),
        ];
        let got = admitted_contents(&events);
        assert!(got.is_empty(), "got {got:?}");
    }

    #[test]
    fn prose_decisions_inside_tool_output_and_prompts_are_kept() {
        let command = "git commit -F - <<'EOF'\nfix(widgets): retry exports\n\nDecision: widget exports retry through Cloud Tasks because Celery hides retries.\nEOF";
        let events = vec![tool_event(9, CanonicalEventType::ToolResult, "Bash", Some(command), Some("Bash"))];
        let got = admitted_contents(&events);
        assert!(
            got.iter().any(|(t, c)| *t == MemoryType::Decision && c.contains("Cloud Tasks")),
            "got {got:?}"
        );

        let prompt = single_event(
            CanonicalEventType::Prompt,
            "Here is the old code:\n```rust\nlet decision = \"Decision: fake\";\n```\nDecision: route widget retries through `chum_mem::jobs::enqueue` instead of Celery.",
        );
        let got = admitted_contents(&prompt);
        assert_eq!(got.len(), 1, "got {got:?}");
        assert_eq!(got[0].0, MemoryType::Decision);
        assert!(got[0].1.contains("chum_mem::jobs::enqueue"));
    }

    #[test]
    fn code_line_detection() {
        for code in [
            r#"            (CanonicalEventType::Prompt, "<task-notification>\n<task-id>abc</task-id>"),"#,
            " and (content ilike '%session is being continued%' or content ilike '# /loop%')",
            r#" ("2026-10-03T10:05:00Z", "prompt",  {"message": "Decision: x"}),"#,
            "select id, type from memories where project_id = $1;",
            "select type, left(content,90) from memories where superseded_at is null",
            "    memories.extend(extract_claims(event));",
            "let source_time = memory_source_time(&draft, &records);",
            "import json",
            r#"{"type": "decision", "content": "Decision: keep it"}"#,
            "fn is_status_only(lower: &str) -> bool {",
        ] {
            assert!(looks_like_code_line(code), "{code:?} should be code");
        }
        for prose in [
            "I'm going with Cloud Tasks for the widget export retries because Celery has no retry visibility.",
            "Decision: widget API deploys only on Tuesdays and Thursdays.",
            "export runs on the GCP memory VM pilot, not the Mac Studio.",
            "let's go with Cloud Tasks for the retries.",
            "Update: the rubrics timeout is now 60 seconds (was 45).",
            "With Cloud Tasks we're safe, it's visible in the console.",
            "Decision: use `chum_mem::jobs::enqueue` for retries.",
            "found and quantified 5 root causes;",
            "Model policy: \"we're going to use gemini 3-flash-preview\" for the experiment.",
            "(Note: for additive and deductive, it will be a multiple toggle).",
            "[Image #2] this should not be possible.",
            "select the widget preset from the dropdown before exporting.",
            "and the strict rule is *my* choice from your answer, not something he confirmed.",
            "Set 3 is live and verified: subtitled *Civil Engineering*, all 10 problems.",
            "**On \"the goal is 5 seconds\": not reachable with correct values.**",
        ] {
            assert!(!looks_like_code_line(prose), "{prose:?} should be prose");
        }
    }
}
