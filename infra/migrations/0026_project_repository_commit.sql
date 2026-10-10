-- 0026: the default-branch commit a project's repository snapshot reflects.
-- Docs sync protocol 2 (review 2, finding 5): clients upload the tree of the
-- repository's default branch (origin/HEAD), never their working copy, with
-- the commit's committer time. The snapshot only moves forward: a sync from an
-- older commit than the one recorded here is rejected with 409, so an engineer
-- on a stale or different branch can neither delete nor revert docs for
-- everyone. Additive; NULL = no protocol-2 sync yet.
alter table public.projects
  add column if not exists repository_commit_at timestamptz,
  add column if not exists repository_commit text,
  add column if not exists repository_ref text;
