-- 0025: the git remote a project's repository snapshot belongs to. Set by the
-- first repository sync that reports one (X-Chum-Repo-Remote); later syncs
-- from a checkout of a different remote are rejected so a stray clone cannot
-- write its files into the team's shared snapshot.
alter table public.projects
  add column if not exists repository_remote text;
