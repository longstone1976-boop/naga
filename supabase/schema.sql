-- みんなの掲示板 用スキーマ
-- Supabase ダッシュボードの「SQL Editor」に貼り付けて実行してください。
-- ログイン機能を使う場合は、このあとに auth.sql も実行してください
-- (ここで作る「誰でも書き込み・編集・削除できる」ポリシーは auth.sql で本人のみに置き換わります)。

create table if not exists public.threads (
  id         uuid primary key default gen_random_uuid(),
  title      text   not null check (char_length(title) between 1 and 80),
  name       text   not null default '' check (char_length(name) <= 30),
  body       text   not null check (char_length(body) between 1 and 2000),
  created_at bigint not null,          -- epoch ミリ秒
  updated_at bigint not null,
  edited_at  bigint
);

create table if not exists public.replies (
  id         uuid primary key default gen_random_uuid(),
  thread_id  uuid   not null references public.threads (id) on delete cascade,
  name       text   not null default '' check (char_length(name) <= 30),
  body       text   not null check (char_length(body) between 1 and 2000),
  created_at bigint not null,
  edited_at  bigint
);

create index if not exists replies_thread_created_idx
  on public.replies (thread_id, created_at);

-- Row Level Security: 現在の掲示板の挙動(誰でも閲覧・書き込み・編集・削除)に合わせています。
alter table public.threads enable row level security;
alter table public.replies enable row level security;

do $$
declare t text; op text;
begin
  foreach t in array array['threads', 'replies'] loop
    foreach op in array array['select', 'insert', 'update', 'delete'] loop
      execute format('drop policy if exists %I on public.%I', 'bbs_' || op, t);
    end loop;
    execute format('create policy bbs_select on public.%I for select to anon, authenticated using (true)', t);
    execute format('create policy bbs_insert on public.%I for insert to anon, authenticated with check (true)', t);
    execute format('create policy bbs_update on public.%I for update to anon, authenticated using (true) with check (true)', t);
    execute format('create policy bbs_delete on public.%I for delete to anon, authenticated using (true)', t);
  end loop;
end $$;

-- リアルタイム更新(他の人の書き込みが即時に反映される)
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'threads') then
    alter publication supabase_realtime add table public.threads;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'replies') then
    alter publication supabase_realtime add table public.replies;
  end if;
end $$;
