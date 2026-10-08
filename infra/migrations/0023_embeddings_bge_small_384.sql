-- 0023: switch memory embeddings from the 1536-dim FNV token hash to a real
-- sentence embedding model (bge-small-en-v1.5, 384 dims). Existing hashed
-- vectors are incompatible and are dropped; POST /api/admin/reembed rebuilds
-- them from memories.
delete from public.embeddings;
drop index if exists public.embeddings_hnsw_idx;
alter table public.embeddings alter column embedding type vector(384);
create index if not exists embeddings_hnsw_idx
  on public.embeddings using hnsw (embedding vector_cosine_ops)
  with (m = 16, ef_construction = 64);
