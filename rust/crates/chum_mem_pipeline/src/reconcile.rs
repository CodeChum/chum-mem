//! PCKC claim reconciliation policy.
//!
//! Pure functions extracted from the API's `derive_and_persist_session_memories`
//! monolith so the async `reconcile-claim-state` worker job can reuse the same
//! supersession/contradiction rules without pulling in api/main.rs.

use chum_mem_contracts::{AuthorityClass, MemoryType, VerificationStatus};

/// Returns true when `current` should supersede `prior` according to the PCKC
/// policy table: (memory_type pair, strength comparison).
///
/// Keep in sync with the original implementation at
/// `rust/apps/api/src/main.rs::current_supersedes_prior` (pre v2.2.1 fix).
pub fn current_supersedes_prior(
    current_memory_type: MemoryType,
    prior_memory_type: MemoryType,
    current_verification: Option<VerificationStatus>,
    prior_verification: Option<VerificationStatus>,
    current_authority: Option<AuthorityClass>,
    prior_authority: Option<AuthorityClass>,
) -> bool {
    let current_stronger = claim_strength(current_authority, current_verification)
        >= claim_strength(prior_authority, prior_verification);
    matches!(
        (current_memory_type, prior_memory_type),
        (MemoryType::Fix, MemoryType::Bug)
            | (MemoryType::Decision, MemoryType::Decision)
            | (MemoryType::Constraint, MemoryType::Constraint)
            | (MemoryType::Constraint, MemoryType::Decision)
            | (MemoryType::Fact, MemoryType::Fact)
            | (MemoryType::Task, MemoryType::Task)
    ) && current_stronger
}

/// Composite strength score used to compare two claims.
pub fn claim_strength(
    authority_class: Option<AuthorityClass>,
    verification_status: Option<VerificationStatus>,
) -> i32 {
    let authority_score = match authority_class {
        Some(AuthorityClass::Repository) => 50,
        Some(AuthorityClass::TestVerified) => 45,
        Some(AuthorityClass::ToolVerified) => 40,
        Some(AuthorityClass::UserConfirmed) => 35,
        Some(AuthorityClass::SessionDerived) => 20,
        Some(AuthorityClass::ModelDerived) => 0,
        None => 10,
    };
    authority_score + verification_rank(verification_status)
}

/// Ordinal rank for the verification axis.
pub fn verification_rank(status: Option<VerificationStatus>) -> i32 {
    match status {
        Some(VerificationStatus::Verified) => 4,
        Some(VerificationStatus::UserConfirmed) => 3,
        Some(VerificationStatus::Inferred) => 2,
        Some(VerificationStatus::Unverified) => 1,
        Some(VerificationStatus::Contradicted) => 0,
        None => 1,
    }
}

pub fn parse_authority_class(value: &str) -> Option<AuthorityClass> {
    match value {
        "repository" => Some(AuthorityClass::Repository),
        "test_verified" => Some(AuthorityClass::TestVerified),
        "tool_verified" => Some(AuthorityClass::ToolVerified),
        "user_confirmed" => Some(AuthorityClass::UserConfirmed),
        "session_derived" => Some(AuthorityClass::SessionDerived),
        "model_derived" => Some(AuthorityClass::ModelDerived),
        _ => None,
    }
}

pub fn parse_verification_status(value: &str) -> Option<VerificationStatus> {
    match value {
        "verified" => Some(VerificationStatus::Verified),
        "user_confirmed" => Some(VerificationStatus::UserConfirmed),
        "inferred" => Some(VerificationStatus::Inferred),
        "unverified" => Some(VerificationStatus::Unverified),
        "contradicted" => Some(VerificationStatus::Contradicted),
        _ => None,
    }
}

pub fn parse_memory_type(value: &str) -> MemoryType {
    match value {
        "fact" => MemoryType::Fact,
        "decision" => MemoryType::Decision,
        "task" => MemoryType::Task,
        "bug" => MemoryType::Bug,
        "summary" => MemoryType::Summary,
        "implementation_detail" => MemoryType::ImplementationDetail,
        "change_log" => MemoryType::ChangeLog,
        "risk" => MemoryType::Risk,
        "constraint" => MemoryType::Constraint,
        "fix" => MemoryType::Fix,
        "open_question" => MemoryType::OpenQuestion,
        _ => MemoryType::Fact,
    }
}

/// Content words of a claim: lowercase alphanumeric tokens of 3+ chars, minus
/// claim prefixes and filler words.
fn claim_words(text: &str) -> std::collections::HashSet<String> {
    const FILLER: &[&str] = &[
        "the", "and", "for", "with", "that", "this", "from", "into", "are", "was", "were", "has",
        "have", "its", "their", "they", "them", "but", "not", "all", "any", "can", "per",
        "decision", "product", "constraint", "fix", "fact", "bug", "task", "next",
    ];
    text.to_lowercase()
        .split(|ch: char| !ch.is_alphanumeric())
        .filter(|word| word.chars().count() >= 3 && !FILLER.contains(word))
        .map(ToOwned::to_owned)
        .collect()
}

/// True when two claims of the same type say the same thing in near-identical
/// words: the same decision recorded in several sessions, or a copy cut off
/// mid-sentence. Word-set overlap (Jaccard) of at least 0.7, or a truncated
/// copy: the shorter claim (6+ content words) has 80% of its words in a longer
/// one that runs on for at least 3 more words. "Use Cloud Tasks for retries"
/// vs "Use Celery for retries" differ in one word and stay separate.
pub fn near_duplicate_claims(a: &str, b: &str) -> bool {
    let (a, b) = (claim_words(a), claim_words(b));
    let (small, large) = if a.len() <= b.len() { (&a, &b) } else { (&b, &a) };
    if small.len() < 4 {
        return false;
    }
    let shared = small.intersection(large).count();
    let union = small.len() + large.len() - shared;
    let jaccard = shared as f64 / union as f64;
    let containment = shared as f64 / small.len() as f64;
    jaccard >= 0.7 || (small.len() >= 6 && large.len() >= small.len() + 3 && containment >= 0.8)
}

/// A near-duplicate of the same type is replaced by the newer copy when the
/// newer one is at least as strong (never let a model-written copy retire an
/// engineer's own statement).
pub fn near_duplicate_supersedes(
    current_authority: Option<AuthorityClass>,
    current_verification: Option<VerificationStatus>,
    prior_authority: Option<AuthorityClass>,
    prior_verification: Option<VerificationStatus>,
) -> bool {
    claim_strength(current_authority, current_verification)
        >= claim_strength(prior_authority, prior_verification)
}

#[cfg(test)]
mod near_duplicate_tests {
    use super::near_duplicate_claims;

    #[test]
    fn same_decision_in_other_words_is_a_duplicate() {
        assert!(near_duplicate_claims(
            "Product decision: an EDIT share on a class gives full edit access to the linked activity.",
            "Decision: Product decision: an EDIT share on the viewed class gives full edit access to the linked activity.",
        ));
    }

    #[test]
    fn copy_cut_mid_sentence_is_a_duplicate() {
        assert!(near_duplicate_claims(
            "Product decision: an EDIT share on a class gives full edit access to the linked activity, except delete.",
            "Product decision: an EDIT share on a class means full edit access to the",
        ));
    }

    #[test]
    fn different_claims_on_the_same_topic_are_not() {
        assert!(!near_duplicate_claims(
            "EDIT sharers must be able to download the answer sheet and questionnaire of a linked activity.",
            "VIEW sharers only read the linked activity and never see unmatched papers.",
        ));
        assert!(!near_duplicate_claims(
            "Use Cloud Tasks for class-record import retries.",
            "Use Celery for class-record import retries.",
        ));
    }
}
