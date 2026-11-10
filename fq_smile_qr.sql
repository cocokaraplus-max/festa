-- fq_smile_qr.sql ［SupabaseのSQL・福祉クエスト］
-- 笑顔コンテストを「番号のQRを読んで投票する」形にする（fq-smile-qr-v1）
--  ・応募のあった写真の数だけ 1番, 2番, … を作る。番号ごとに読み取り用の記号（QRの中身）を付ける
--  ・お客さんは、会場に貼った写真の横のQRをスマホのカメラで読むと、その番号に1票
--  ・1人1票。別の番号のQRを読むと、そちらに入れ直し（締め切りまで）
--  ・なまえの登録は要らない（認識番号で数える）
--  ・本部は「何番に何票」を見るだけ。表彰はアナログ
-- 【消すもの】ありません。2回以上 Run しても大丈夫です
-- ★まだ fq_smile.sql を流していなくても、これだけで動くように入れものも作ります

create table if not exists fq_smiles (
  id         bigint generated always as identity primary key,
  no         integer not null unique,
  title      text    not null default '',
  img_url    text    not null default '',
  active     boolean not null default true,
  sort       integer not null default 0,
  created_at timestamptz not null default now()
);
alter table fq_smiles enable row level security;
create table if not exists fq_smile_votes (
  recog_no  text   primary key,
  smile_id  bigint not null references fq_smiles(id) on delete cascade,
  voted_at  timestamptz not null default now()
);
alter table fq_smile_votes enable row level security;
create index if not exists fq_smile_votes_smile_idx on fq_smile_votes (smile_id);
insert into fq_settings (key, value) values ('smile_open', 0) on conflict (key) do nothing;

-- 番号ごとの読み取り用の記号（家から打ちこめないように、うしろにランダムな6文字）
alter table fq_smiles add column if not exists code text;
update fq_smiles set code = no || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6) where code is null;
create unique index if not exists fq_smiles_code_uniq on fq_smiles (code);

-- ------------------------------------------------------------
-- 本部：応募の数を決める（1〜n番をそろえる。n より大きい番号は投票の対象から外す）
-- ------------------------------------------------------------
create or replace function fq_admin_smile_setup(p_pass text, p_count integer)
returns json
language plpgsql security definer set search_path = public as $$
declare i integer;
begin
  if not fq_admin_ok(p_pass) then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  if p_count is null or p_count < 1 or p_count > 300 then
    return json_build_object('ok', false, 'message', '応募の数は 1〜300 で入れてください');
  end if;
  for i in 1..p_count loop
    if not exists (select 1 from fq_smiles where no = i) then
      insert into fq_smiles (no, title, img_url, active, sort, code)
           values (i, '', '', true, i, i || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    end if;
  end loop;
  update fq_smiles set active = (no <= p_count) where active is distinct from (no <= p_count);
  return json_build_object('ok', true, 'count', p_count);
end; $$;

-- ------------------------------------------------------------
-- 本部：集計（何番に何票）。同じ票数は同じ順位
-- ------------------------------------------------------------
create or replace function fq_admin_smile_list(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  return json_build_object(
    'ok', true,
    'open', (fq_setting('smile_open', 0) = 1),
    'count', (select count(*) from fq_smiles where active),
    'total_votes', (select count(*) from fq_smile_votes v join fq_smiles s on s.id = v.smile_id where s.active),
    'voters',      (select count(distinct v.recog_no) from fq_smile_votes v join fq_smiles s on s.id = v.smile_id where s.active),
    'rows', coalesce((
      select json_agg(json_build_object(
               'id', t.id, 'no', t.no, 'code', t.code, 'title', t.title, 'img', t.img_url,
               'active', t.active, 'votes', t.votes, 'rank', t.rnk, 'tie', t.tie)
             order by t.no)
      from (
        select s.id, s.no, s.code, s.title, s.img_url, s.active,
               count(v.recog_no)::int as votes,
               rank() over (order by count(v.recog_no) desc)::int as rnk,
               (count(*) over (partition by count(v.recog_no)) > 1) as tie
          from fq_smiles s
          left join fq_smile_votes v on v.smile_id = s.id
         where s.active
         group by s.id, s.no, s.code, s.title, s.img_url, s.active
      ) t), '[]'::json));
end; $$;

-- ------------------------------------------------------------
-- アプリ：いまの状態（票数は返さない）
-- ------------------------------------------------------------
create or replace function fq_smile_list(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_mine integer;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  select s.no into v_mine from fq_smile_votes v join fq_smiles s on s.id = v.smile_id
   where v.recog_no = p_recog and s.active;
  return json_build_object(
    'ok', true,
    'open', (fq_setting('smile_open', 0) = 1),
    'count', (select count(*) from fq_smiles where active),
    'mine_no', v_mine,
    'photos', '[]'::json);
end; $$;

-- ------------------------------------------------------------
-- アプリ：番号のQRを読んで投票する
-- ------------------------------------------------------------
create or replace function fq_smile_vote_code(p_recog text, p_secret text, p_code text)
returns json
language plpgsql security definer set search_path = public as $$
declare s fq_smiles; v_prev integer;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  select * into s from fq_smiles where code = btrim(coalesce(p_code, '')) and active;
  if s.id is null then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'not_found');
  end if;
  if fq_setting('smile_open', 0) <> 1 then
    return json_build_object('ok', false, 'reason', 'closed', 'no', s.no);
  end if;
  select x.no into v_prev from fq_smile_votes v join fq_smiles x on x.id = v.smile_id where v.recog_no = p_recog;
  insert into fq_smile_votes (recog_no, smile_id) values (p_recog, s.id)
    on conflict (recog_no) do update set smile_id = excluded.smile_id, voted_at = now();
  return json_build_object('ok', true, 'no', s.no, 'prev_no', v_prev);
end; $$;

revoke all on function fq_admin_smile_setup(text, integer) from public;
grant execute on function fq_admin_smile_setup(text, integer) to anon, authenticated;
revoke all on function fq_admin_smile_list(text) from public;
grant execute on function fq_admin_smile_list(text) to anon, authenticated;
revoke all on function fq_smile_list(text, text) from public;
grant execute on function fq_smile_list(text, text) to anon, authenticated;
revoke all on function fq_smile_vote_code(text, text, text) from public;
grant execute on function fq_smile_vote_code(text, text, text) to anon, authenticated;

-- 確かめ（Run のあと、下の1行だけ貼って Run）
-- select count(*) as 関数の数 from pg_proc where proname in ('fq_admin_smile_setup','fq_smile_vote_code');   → 2
