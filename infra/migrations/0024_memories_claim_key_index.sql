-- 0024: lookup index for cross-session memory dedupe. session/end checks for an
-- active memory with the same claim key before inserting a new one; without
-- this index that check scans every memory of the project per derived claim.
create index if not exists memories_project_claim_key_idx
  on public.memories (project_id, (metadata->>'claimKey'))
  where superseded_at is null;
