-- ログイン / マイページ 用の追加設定
-- schema.sql を実行したあとに、Supabase の SQL Editor で実行してください(何度実行しても安全です)。
--
-- 実行後の挙動:
--   * 閲覧は誰でも可能。書き込み・編集・削除はログイン必須で、編集・削除は投稿者本人のみ。
--   * 投稿者名はプロフィールの表示名が DB 側で自動的に入る(なりすまし不可)。
--   * 表示名を変えると、過去の投稿の名前も追従する。
--   * 返信が付くとスレッドの最終更新が DB 側で更新される。
--   * delete_my_account() で本人のアカウントと投稿を削除できる(退会)。

-- ---------------------------------------------------------------- プロフィール
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 30),
  created_at   timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_update on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated using (id = auth.uid());
create policy profiles_update on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- 初回ログイン(サインアップ)時にプロフィールを自動作成。
-- 表示名の既定は「ユーザー」+ID 先頭 4 文字。Google の本名やメールアドレスは、
-- 意図せず公開されないよう既定では使いません(マイページで変更できます)。
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    left(coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
      'ユーザー' || left(replace(new.id::text, '-', ''), 4)
    ), 30)
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 既にユーザーがいる場合の補完
insert into public.profiles (id, display_name)
select u.id,
       left(coalesce(nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                     'ユーザー' || left(replace(u.id::text, '-', ''), 4)), 30)
from auth.users u
on conflict (id) do nothing;

-- ---------------------------------------------------------------- 投稿に持ち主を持たせる
-- 既存の(ログイン導入前の)投稿は user_id が null のままで、誰も編集・削除できなくなります。
alter table public.threads add column if not exists user_id uuid references public.profiles (id) on delete cascade;
alter table public.replies add column if not exists user_id uuid references public.profiles (id) on delete cascade;
create index if not exists threads_user_idx on public.threads (user_id);
create index if not exists replies_user_idx on public.replies (user_id);

-- 投稿時: 持ち主と名前を DB 側で確定。更新時: 持ち主は変更不可、名前は本人の直接更新では変更不可
-- (pg_trigger_depth() > 1 は表示名変更に伴う同期更新のとき)
create or replace function public.set_post_author()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.user_id := auth.uid();
    new.name := coalesce((select p.display_name from public.profiles p where p.id = auth.uid()), '');
  else
    new.user_id := old.user_id;
    if pg_trigger_depth() = 1 then
      new.name := old.name;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists threads_set_author on public.threads;
create trigger threads_set_author
  before insert or update on public.threads
  for each row execute function public.set_post_author();

drop trigger if exists replies_set_author on public.replies;
create trigger replies_set_author
  before insert or update on public.replies
  for each row execute function public.set_post_author();

-- 表示名を変えたら過去の投稿の名前も更新
create or replace function public.sync_author_name()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.display_name is distinct from old.display_name then
    update public.threads set name = new.display_name where user_id = new.id;
    update public.replies set name = new.display_name where user_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_sync_name on public.profiles;
create trigger profiles_sync_name
  after update on public.profiles
  for each row execute function public.sync_author_name();

-- 返信が付いたらスレッドの最終更新を進める(返信者はスレッドの持ち主とは限らないため DB 側で)
create or replace function public.bump_thread()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.threads
     set updated_at = greatest(updated_at, new.created_at)
   where id = new.thread_id;
  return null;
end;
$$;

drop trigger if exists replies_bump_thread on public.replies;
create trigger replies_bump_thread
  after insert on public.replies
  for each row execute function public.bump_thread();

-- ---------------------------------------------------------------- RLS(書き込みは本人のみ)
do $$
declare t text;
begin
  foreach t in array array['threads', 'replies'] loop
    execute format('drop policy if exists bbs_insert on public.%I', t);
    execute format('drop policy if exists bbs_update on public.%I', t);
    execute format('drop policy if exists bbs_delete on public.%I', t);
    execute format('create policy bbs_insert on public.%I for insert to authenticated with check (user_id = auth.uid())', t);
    execute format('create policy bbs_update on public.%I for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
    execute format('create policy bbs_delete on public.%I for delete to authenticated using (user_id = auth.uid())', t);
  end loop;
end $$;
-- select ポリシー(bbs_select)は schema.sql のまま: 誰でも閲覧できます。

-- ---------------------------------------------------------------- 退会
-- 本人のアカウントを削除する。プロフィール、本人のスレッド(他の人の返信を含む)、本人の返信も連鎖して消える。
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
