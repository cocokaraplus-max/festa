-- ============================================================
-- FUKUSHI QUEST — 新しいガチャ（fq-gacha2-v1 / 2026-11-04）
--
-- 決まりごと
--   ・3階・4階 ×「体験」「話を聞く」「見る」の 6 種類の QR（ブースの方が、終わった人に見せる）
--   ・体験／話を聞く／見る を 1 つずつそろえると「ガチャ券」1 枚。2 枚目は、まだ読んでいない 3 つで
--     → 6 種類しかないので、ガチャは自然に 1 人 2 回まで
--   ・ガチャは 1F の受付で。お客さんがガチャ券の QR を見せ、受付のスタッフが読み取ると
--     お客さんのスマホに「ガチャをまわす」が出る（読み取られていない券では、まわせない）
--   ・当たったら、受付のスタッフが紙の引換券を渡す。景品には「番号」（prizes.sort）を付ける
--   ・チーム（10 人まで）は、全員に同じ行き先（ログポース）が出る
--   ・前の「ポイントでまわす fq_draw」と「アプリの引換券」は使わない（fq_draw は呼べなくする）
--
-- 使い方：福祉クエストの Supabase → SQL Editor → New query → 全部貼って Run。
--         2 回以上 Run しても壊れません（データは消えません）。
-- ★先に fq_voucher.sql ／ fq_grand.sql ／ fq_smile.sql が流れている前提です。
-- ★受付の暗証番号は、下の 2 の「ここに受付の暗証番号」を SQL Editor の中でだけ書き換えてから Run。
--   リポジトリのファイルには本物を書かないこと（公開リポジトリのため）。
-- ★where true を外さないこと（Supabase の safeupdate に弾かれる）
-- ============================================================

create extension if not exists pgcrypto with schema extensions;


-- ------------------------------------------------------------
-- 1. 表
-- ------------------------------------------------------------

-- 会場の QR に「階」と「カテゴリ」を持たせる（カテゴリの無い QR はガチャ券に数えない）
alter table fq_codes add column if not exists floor smallint;
alter table fq_codes add column if not exists cat   text;     -- 'exp'＝体験 'talk'＝話を聞く 'see'＝見る

-- 6 種類の QR（はじめの 1 回だけ作る。印刷する URL は本部の画面「会場のQRに入れるURL」に出る）
insert into fq_codes (code, base, label, points, sort, floor, cat)
select b.base || '.' || substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 10), b.base, b.label, 1, b.sort, b.fl, b.cat
  from (values ('f3_exp',  '3階 体験',     101, 3, 'exp'),
               ('f3_talk', '3階 話を聞く', 102, 3, 'talk'),
               ('f3_see',  '3階 見る',     103, 3, 'see'),
               ('f4_exp',  '4階 体験',     104, 4, 'exp'),
               ('f4_talk', '4階 話を聞く', 105, 4, 'talk'),
               ('f4_see',  '4階 見る',     106, 4, 'see')) as b(base, label, sort, fl, cat)
 where not exists (select 1 from fq_codes c where c.base = b.base);
-- 2 回目の Run でも、階とカテゴリは必ず合わせ直す
update fq_codes set floor = 3, cat = 'exp'  where base = 'f3_exp'  and (floor is distinct from 3 or cat is distinct from 'exp');
update fq_codes set floor = 3, cat = 'talk' where base = 'f3_talk' and (floor is distinct from 3 or cat is distinct from 'talk');
update fq_codes set floor = 3, cat = 'see'  where base = 'f3_see'  and (floor is distinct from 3 or cat is distinct from 'see');
update fq_codes set floor = 4, cat = 'exp'  where base = 'f4_exp'  and (floor is distinct from 4 or cat is distinct from 'exp');
update fq_codes set floor = 4, cat = 'talk' where base = 'f4_talk' and (floor is distinct from 4 or cat is distinct from 'talk');
update fq_codes set floor = 4, cat = 'see'  where base = 'f4_see'  and (floor is distinct from 4 or cat is distinct from 'see');

-- チーム
create table if not exists fq_teams (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,          -- チームの QR の中身（?team= のうしろ）
  owner      text not null,
  created_at timestamptz not null default now()
);
create table if not exists fq_team_members (
  recog_no  text primary key,               -- 1 人は 1 チームだけ
  team_id   uuid not null references fq_teams(id) on delete cascade,
  joined_at timestamptz not null default now()
);
create index if not exists fq_team_members_team_idx on fq_team_members (team_id);

-- ガチャ券。1 人 1 回目・2 回目でそれぞれ 1 枚
--   status: issued（出した）→ unlocked（受付が読んだ）→ drawn（まわした）
create table if not exists fq_tickets (
  token       text primary key,             -- 推測できない番号（QR の中身）
  recog_no    text not null,
  round       smallint not null,
  status      text not null default 'issued',
  issued_at   timestamptz not null default now(),
  unlocked_at timestamptz,
  unlocked_by text,
  drawn_at    timestamptz,
  is_win      boolean,
  prize_id    uuid,
  prize_no    integer,
  prize_name  text,
  rarity      integer,
  handed_at   timestamptz,                  -- 紙の引換券を渡した
  handed_by   text,
  unique (recog_no, round)
);
create index if not exists fq_tickets_pending_idx on fq_tickets (is_win, handed_at);

-- 受付の端末（暗証番号を入れた端末に「受付の鍵」を渡す。鍵そのものは保存しない）
create table if not exists fq_staff_tokens (
  token_hash text primary key,
  label      text not null default '',
  created_at timestamptz not null default now()
);
-- 暗証番号の打ちまちがい（5 回で 10 分止める）
create table if not exists fq_staff_guard (
  id           integer primary key,
  fails        integer not null default 0,
  locked_until timestamptz
);
insert into fq_staff_guard (id) values (1) on conflict (id) do nothing;

-- ★どの表にもポリシーを作らない＝アプリから直接は読めない。すべて下の関数を通す
alter table fq_teams        enable row level security;
alter table fq_team_members enable row level security;
alter table fq_tickets      enable row level security;
alter table fq_staff_tokens enable row level security;
alter table fq_staff_guard  enable row level security;


-- ------------------------------------------------------------
-- 2. 受付の暗証番号（★ここだけ SQL Editor の中で書き換えてから Run）
--    すでに入っていれば上書きしない。変えたいときは下の update を使う
-- ------------------------------------------------------------
insert into fq_admin (key, value) values ('uketsuke_pass', 'ここに受付の暗証番号')
on conflict (key) do nothing;
-- 変えるとき：update fq_admin set value = '新しい暗証番号', updated_at = now() where key = 'uketsuke_pass';
-- 長さだけ確かめる（中身は出ない）：select key, length(value) from fq_admin order by key;


-- ------------------------------------------------------------
-- 3. 中で使う道具（アプリからは呼べない）
-- ------------------------------------------------------------

-- その人の、カテゴリごとの読んだ数と階
create or replace function fq_g2_member(p_recog text)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  n_exp int; n_talk int; n_see int; v_earned int; v_drawn int;
  f_exp int[]; f_talk int[]; f_see int[];
begin
  select count(*) filter (where c.cat = 'exp'),  count(*) filter (where c.cat = 'talk'), count(*) filter (where c.cat = 'see'),
         coalesce(array_agg(c.floor::int) filter (where c.cat = 'exp'),  '{}'),
         coalesce(array_agg(c.floor::int) filter (where c.cat = 'talk'), '{}'),
         coalesce(array_agg(c.floor::int) filter (where c.cat = 'see'),  '{}')
    into n_exp, n_talk, n_see, f_exp, f_talk, f_see
    from fq_earned e join fq_codes c on c.code = e.code
   where e.recog_no = p_recog and c.cat is not null;
  v_earned := least(2, least(n_exp, n_talk, n_see));
  select count(*) into v_drawn from fq_tickets where recog_no = p_recog and status = 'drawn';
  return json_build_object(
    'recog', p_recog, 'earned', v_earned, 'drawn', v_drawn,
    'n', json_build_object('exp', n_exp, 'talk', n_talk, 'see', n_see),
    'floors', json_build_object('exp', f_exp, 'talk', f_talk, 'see', f_see));
end; $$;

-- ログポースの行き先。チームなら全員を見て、全員に同じ行き先を返す
--   ・まだそろっていない人がいる → その人たちに必要なカテゴリ（多くの人が必要なもの）と、行ける階
--   ・全員そろって、まわしていない券がある人がいる → 1F の受付
--   ・全員 2 回まわした → 図鑑
create or replace function fq_g2_nav(p_recog text)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_team uuid; v_seed text; m json; v_drawn int; v_earned int;
  cats text[] := array['exp','talk','see'];
  need_cnt int[] := array[0,0,0];
  fl_cnt int[] := array[0,0,0,0,0,0];      -- [cat1-3階, cat1-4階, cat2-3階, ...]
  any_ticket boolean := false; all_done boolean := true;
  i int; f int; best int := 0; best_i int := 0; best_f int := 0; k int; sc text; bsc text;
  members text[];
  lbl text;
begin
  select team_id into v_team from fq_team_members where recog_no = p_recog;
  if v_team is null then
    members := array[p_recog];
    v_seed := p_recog;
  else
    select array_agg(recog_no order by joined_at) into members from fq_team_members where team_id = v_team;
    v_seed := v_team::text;
  end if;

  foreach sc in array members loop
    m := fq_g2_member(sc);
    v_drawn := (m->>'drawn')::int; v_earned := (m->>'earned')::int;
    if v_drawn >= 2 then continue; end if;
    all_done := false;
    if v_earned > v_drawn then any_ticket := true; continue; end if;
    for i in 1..3 loop
      if ((m->'n'->>cats[i])::int) <= v_drawn then          -- このカテゴリが、いまの回でまだ
        need_cnt[i] := need_cnt[i] + 1;
        for f in 3..4 loop
          if not exists (select 1 from json_array_elements_text(m->'floors'->cats[i]) x where x::int = f) then
            fl_cnt[(i-1)*2 + (f-2)] := fl_cnt[(i-1)*2 + (f-2)] + 1;
          end if;
        end loop;
      end if;
    end loop;
  end loop;

  if all_done then return json_build_object('kind', 'zukan'); end if;

  -- 必要な人がいちばん多いカテゴリ。同じなら、人（チーム）ごとに決まった順番
  for i in 1..3 loop
    if need_cnt[i] > 0 then
      k := need_cnt[i] * 100 + (('x' || substr(md5(v_seed || ':' || cats[i]), 1, 2))::bit(8)::int % 100);
      if k > best then best := k; best_i := i; end if;
    end if;
  end loop;

  if best_i = 0 then
    if any_ticket then return json_build_object('kind', 'uketsuke'); end if;
    return json_build_object('kind', 'zukan');
  end if;

  -- 階：行ける人がいちばん多い階。同じなら人（チーム）ごとにばらける
  best := -1;
  for f in 3..4 loop
    k := fl_cnt[(best_i-1)*2 + (f-2)] * 100 + (('x' || substr(md5(v_seed || ':' || cats[best_i] || ':' || f), 1, 2))::bit(8)::int % 100);
    if k > best then best := k; best_f := f; end if;
  end loop;
  lbl := case cats[best_i] when 'exp' then '体験' when 'talk' then '話を聞く' else '見る' end;
  return json_build_object('kind', 'booth', 'floor', best_f, 'cat', cats[best_i], 'label', lbl,
                           'need', need_cnt[best_i], 'ticket_waiting', any_ticket);
end; $$;

-- 受付の鍵が正しいか
create or replace function fq_staff_ok(p_staff text)
returns text
language sql stable security definer set search_path = public, extensions as $$
  select label from fq_staff_tokens
   where token_hash = encode(extensions.digest(coalesce(p_staff,''), 'sha256'), 'hex');
$$;

create or replace function fq_ticket_json(t fq_tickets)
returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('round', t.round, 'status', t.status, 'recog_no', t.recog_no,
                           'nickname', coalesce((select nickname from participants p where p.recog_no = t.recog_no), ''),
                           'unlocked_at', t.unlocked_at, 'drawn_at', t.drawn_at,
                           'is_win', t.is_win, 'prize_no', t.prize_no, 'prize_name', t.prize_name, 'rarity', t.rarity,
                           'handed', t.handed_at is not null, 'handed_at', t.handed_at);
$$;

revoke all on function fq_g2_member(text)       from public, anon, authenticated;
revoke all on function fq_g2_nav(text)          from public, anon, authenticated;
revoke all on function fq_staff_ok(text)        from public, anon, authenticated;
revoke all on function fq_ticket_json(fq_tickets) from public, anon, authenticated;


-- ------------------------------------------------------------
-- 4. アプリ（参加者）から呼ぶ関数
-- ------------------------------------------------------------

-- いまの状態（そろったカテゴリ・ガチャ券・結果・チーム・行き先）
--   ★券がもらえる状態なら、ここで券を出す（1 回目・2 回目それぞれ 1 枚だけ）
create or replace function fq_g2_state(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare m json; v_drawn int; v_earned int; t fq_tickets; v_team fq_teams; v_cnt int; v_tok text;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  m := fq_g2_member(p_recog);
  v_drawn := (m->>'drawn')::int; v_earned := (m->>'earned')::int;

  if v_earned > v_drawn and v_drawn < 2 then
    select * into t from fq_tickets where recog_no = p_recog and round = v_drawn + 1;
    if t.token is null then
      v_tok := encode(extensions.gen_random_bytes(18), 'hex');
      insert into fq_tickets (token, recog_no, round) values (v_tok, p_recog, v_drawn + 1)
      on conflict (recog_no, round) do nothing;
      select * into t from fq_tickets where recog_no = p_recog and round = v_drawn + 1;
    end if;
  end if;

  select tm.* into v_team from fq_team_members mm join fq_teams tm on tm.id = mm.team_id where mm.recog_no = p_recog;
  if v_team.id is not null then select count(*) into v_cnt from fq_team_members where team_id = v_team.id; end if;

  return json_build_object(
    'ok', true,
    'member', m,
    'ticket', case when t.token is null then null
                   else json_build_object('token', t.token, 'round', t.round, 'status', t.status) end,
    'results', coalesce((select json_agg(json_build_object('round', x.round, 'is_win', x.is_win, 'prize_no', x.prize_no,
                           'prize_name', x.prize_name, 'rarity', x.rarity, 'handed', x.handed_at is not null)
                           order by x.round)
                          from fq_tickets x where x.recog_no = p_recog and x.status = 'drawn'), '[]'::json),
    'team', case when v_team.id is null then null
                 else json_build_object('code', v_team.code, 'count', v_cnt, 'owner', v_team.owner = p_recog) end,
    'nav', fq_g2_nav(p_recog),
    'grand', exists (select 1 from fq_draw_log where recog_no = p_recog));
end; $$;

-- ガチャをまわす。受付が読み取った（unlocked）券がないと、まわせない
create or replace function fq_g2_draw(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public as $$
declare t fq_tickets; v_lose int; v_stock int; v_r double precision; v_acc int := 0; p record; won prizes;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  perform pg_advisory_xact_lock(hashtext('fq_g2_draw:' || p_recog));
  select * into t from fq_tickets where recog_no = p_recog and status <> 'drawn' order by round limit 1 for update;
  if t.token is null then return json_build_object('ok', false, 'reason', 'no_ticket'); end if;
  if t.status <> 'unlocked' then return json_build_object('ok', false, 'reason', 'not_unlocked'); end if;

  perform 1 from prizes where stock > 0 for update;
  select coalesce(sum(stock), 0) into v_stock from prizes where stock > 0;
  v_lose := greatest(0, fq_setting('lose_weight', 3000));
  v_r := random() * (v_stock + v_lose);

  if v_stock > 0 and v_r < v_stock then
    for p in select * from prizes where stock > 0 order by sort asc, created_at asc loop
      v_acc := v_acc + p.stock;
      if v_r < v_acc then
        update prizes set stock = stock - 1 where id = p.id returning * into won;
        exit;
      end if;
    end loop;
  end if;

  update fq_tickets set status = 'drawn', drawn_at = now(), is_win = (won.id is not null),
                        prize_id = won.id, prize_no = won.sort, prize_name = won.name, rarity = won.rarity
   where token = t.token returning * into t;
  insert into fq_draw_log (recog_no, cost, is_win, token) values (p_recog, 0, t.is_win, t.token);   -- 大抽選会の対象に
  insert into draws (recog_no, rarity, is_win, prize_id, prize_name)
       values (p_recog, coalesce(won.rarity, 0), t.is_win, won.id, won.name);                     -- 本部モニター用

  return json_build_object('ok', true, 'win', t.is_win, 'round', t.round,
                           'prize_no', t.prize_no, 'prize_name', t.prize_name, 'rarity', coalesce(t.rarity, 0));
end; $$;

-- チームをつくる（もう入っていれば、そのチームを返す）
create or replace function fq_team_create(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_team fq_teams; v_code text; v_try int := 0; v_cnt int;
  ABC constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
begin
  if not fq_auth(p_recog, p_secret) then perform pg_sleep(0.3); return json_build_object('ok', false, 'reason', 'auth'); end if;
  select tm.* into v_team from fq_team_members mm join fq_teams tm on tm.id = mm.team_id where mm.recog_no = p_recog;
  if v_team.id is null then
    loop
      v_code := '';
      for i in 1..8 loop
        v_code := v_code || substr(ABC, 1 + (get_byte(extensions.gen_random_bytes(1), 0) % 32), 1);
      end loop;
      exit when not exists (select 1 from fq_teams where code = v_code);
      v_try := v_try + 1; if v_try > 20 then raise exception 'team code collision'; end if;
    end loop;
    insert into fq_teams (code, owner) values (v_code, p_recog) returning * into v_team;
    insert into fq_team_members (recog_no, team_id) values (p_recog, v_team.id);
  end if;
  select count(*) into v_cnt from fq_team_members where team_id = v_team.id;
  return json_build_object('ok', true, 'code', v_team.code, 'count', v_cnt);
end; $$;

-- チームに入る（10 人まで）。ほかのチームに入っていたら、そこからぬける
create or replace function fq_team_join(p_recog text, p_secret text, p_code text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_team fq_teams; v_cnt int;
begin
  if not fq_auth(p_recog, p_secret) then perform pg_sleep(0.3); return json_build_object('ok', false, 'reason', 'auth'); end if;
  select * into v_team from fq_teams where code = upper(btrim(coalesce(p_code,'')));
  if v_team.id is null then perform pg_sleep(0.3); return json_build_object('ok', false, 'reason', 'not_found'); end if;
  perform pg_advisory_xact_lock(hashtext('fq_team:' || v_team.id::text));
  if exists (select 1 from fq_team_members where recog_no = p_recog and team_id = v_team.id) then
    select count(*) into v_cnt from fq_team_members where team_id = v_team.id;
    return json_build_object('ok', true, 'code', v_team.code, 'count', v_cnt, 'already', true);
  end if;
  select count(*) into v_cnt from fq_team_members where team_id = v_team.id;
  if v_cnt >= 10 then return json_build_object('ok', false, 'reason', 'full'); end if;
  delete from fq_team_members where recog_no = p_recog;
  insert into fq_team_members (recog_no, team_id) values (p_recog, v_team.id);
  return json_build_object('ok', true, 'code', v_team.code, 'count', v_cnt + 1);
end; $$;

-- チームをぬける（ひとりでまわる）
create or replace function fq_team_leave(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_auth(p_recog, p_secret) then perform pg_sleep(0.3); return json_build_object('ok', false, 'reason', 'auth'); end if;
  delete from fq_team_members where recog_no = p_recog;
  return json_build_object('ok', true);
end; $$;


-- ------------------------------------------------------------
-- 5. 受付の画面（uketsuke.html）から呼ぶ関数
-- ------------------------------------------------------------

-- 暗証番号を入れて、この端末に「受付の鍵」をもらう
create or replace function fq_staff_login(p_pass text, p_label text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g fq_staff_guard; v_ok boolean; v_tok text;
begin
  select * into g from fq_staff_guard where id = 1 for update;
  if g.locked_until is not null and g.locked_until > now() then
    return json_build_object('ok', false, 'reason', 'locked', 'until', g.locked_until);
  end if;
  select (value = coalesce(p_pass,'') and value <> 'ここに受付の暗証番号') into v_ok from fq_admin where key = 'uketsuke_pass';
  if coalesce(v_ok, false) is not true then
    update fq_staff_guard set fails = fails + 1,
                              locked_until = case when fails + 1 >= 5 then now() + interval '10 minutes' else null end
     where id = 1;
    update fq_staff_guard set fails = 0 where id = 1 and locked_until is not null;
    perform pg_sleep(1);
    return json_build_object('ok', false, 'reason', 'bad_pass');
  end if;
  update fq_staff_guard set fails = 0, locked_until = null where id = 1;
  v_tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into fq_staff_tokens (token_hash, label)
       values (encode(extensions.digest(v_tok, 'sha256'), 'hex'), left(coalesce(btrim(p_label),''), 20));
  return json_build_object('ok', true, 'staff', v_tok);
end; $$;

-- ガチャ券を読み取った → お客さんのスマホに「ガチャをまわす」が出る
create or replace function fq_ticket_unlock(p_staff text, p_token text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_who text; t fq_tickets;
begin
  v_who := fq_staff_ok(p_staff);
  if v_who is null then perform pg_sleep(0.5); return json_build_object('ok', false, 'reason', 'staff'); end if;
  select * into t from fq_tickets where token = btrim(coalesce(p_token,'')) for update;
  if t.token is null then return json_build_object('ok', false, 'reason', 'not_found'); end if;
  if t.status = 'issued' then
    update fq_tickets set status = 'unlocked', unlocked_at = now(), unlocked_by = v_who
     where token = t.token returning * into t;
    return json_build_object('ok', true, 'first', true, 'ticket', fq_ticket_json(t));
  end if;
  return json_build_object('ok', true, 'first', false, 'ticket', fq_ticket_json(t));
end; $$;

-- 読み取ったあとの様子（まわしたか・何が当たったか）
create or replace function fq_ticket_watch(p_staff text, p_token text)
returns json
language plpgsql security definer set search_path = public as $$
declare t fq_tickets;
begin
  if fq_staff_ok(p_staff) is null then perform pg_sleep(0.5); return json_build_object('ok', false, 'reason', 'staff'); end if;
  select * into t from fq_tickets where token = btrim(coalesce(p_token,''));
  if t.token is null then return json_build_object('ok', false, 'reason', 'not_found'); end if;
  return json_build_object('ok', true, 'ticket', fq_ticket_json(t));
end; $$;

-- 紙の引換券を渡した
create or replace function fq_ticket_hand(p_staff text, p_token text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_who text; t fq_tickets;
begin
  v_who := fq_staff_ok(p_staff);
  if v_who is null then perform pg_sleep(0.5); return json_build_object('ok', false, 'reason', 'staff'); end if;
  update fq_tickets set handed_at = now(), handed_by = v_who
   where token = btrim(coalesce(p_token,'')) and is_win and handed_at is null
  returning * into t;
  if t.token is null then select * into t from fq_tickets where token = btrim(coalesce(p_token,'')); end if;
  if t.token is null then return json_build_object('ok', false, 'reason', 'not_found'); end if;
  return json_build_object('ok', true, 'ticket', fq_ticket_json(t));
end; $$;

-- まだ渡していない当たり（受付の画面の一覧）
create or replace function fq_staff_pending(p_staff text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if fq_staff_ok(p_staff) is null then perform pg_sleep(0.5); return json_build_object('ok', false, 'reason', 'staff'); end if;
  return json_build_object('ok', true, 'list', coalesce((
    select json_agg(json_build_object('token', t.token, 'ticket', fq_ticket_json(t)) order by t.drawn_at desc)
      from (select * from fq_tickets where is_win and handed_at is null order by drawn_at desc limit 50) t), '[]'::json));
end; $$;


-- ------------------------------------------------------------
-- 6. 本部の画面から呼ぶ関数（合言葉つき）
-- ------------------------------------------------------------
create or replace function fq_admin_g2_data(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  return json_build_object('ok', true,
    'booths', coalesce((select json_agg(json_build_object('base', c.base, 'label', c.label, 'code', c.code,
                 'scans', (select count(*) from fq_earned e where e.code = c.code)) order by c.sort)
                 from fq_codes c where c.cat is not null), '[]'::json),
    'tickets', json_build_object(
                 'issued',   (select count(*) from fq_tickets),
                 'unlocked', (select count(*) from fq_tickets where status = 'unlocked'),
                 'drawn',    (select count(*) from fq_tickets where status = 'drawn'),
                 'wins',     (select count(*) from fq_tickets where is_win),
                 'handed',   (select count(*) from fq_tickets where handed_at is not null)),
    'teams', (select count(*) from fq_teams),
    'staff', (select count(*) from fq_staff_tokens));
end; $$;


-- ------------------------------------------------------------
-- 7. 前の仕組みを止める
--    ★ポイントでまわす fq_draw と、アプリの引換券を、アプリから呼べなくする（表は消さない）
-- ------------------------------------------------------------
revoke execute on function fq_draw(text,text) from public, anon, authenticated;


-- ------------------------------------------------------------
-- 8. 大会リセットに、チーム・ガチャ券・受付の端末も含める
--    ★where true を外さないこと
-- ------------------------------------------------------------
create or replace function fq_reset(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
declare ok boolean; np integer; nd integer; nz integer; ng integer; nv integer; ns integer; nt integer;
begin
  select (value = p_pass) into ok from fq_admin where key = 'reset_pass';
  if coalesce(ok, false) is not true then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;

  select count(*) into np from participants;
  select count(*) into nd from draws;
  select count(*) into nz from zukan_owned;
  select count(*) into ng from logpose_goal;
  select count(*) into nv from fq_vouchers;
  select count(*) into ns from fq_smile_votes;
  select count(*) into nt from fq_tickets;          -- fq-gacha2-v1

  delete from draws where true;
  delete from participants where true;
  delete from zukan_owned where true;
  delete from zukan_scans where true;
  delete from logpose_goal where true;
  delete from fq_vouchers where true;
  delete from fq_draw_log where true;
  delete from fq_earned where true;
  delete from fq_devices where true;
  delete from fq_grand_winners where true;
  delete from fq_smile_votes where true;
  delete from fq_tickets where true;        -- fq-gacha2-v1
  delete from fq_team_members where true;   -- fq-gacha2-v1
  delete from fq_teams where true;          -- fq-gacha2-v1
  -- ★受付の端末（fq_staff_tokens）は消さない。前日に準備した端末を当日もそのまま使うため
  execute 'alter sequence recog_seq restart with 1';
  update prizes set stock = initial_stock
   where stock is distinct from initial_stock;
  update fq_shops set pin_fails = 0, locked_until = null where pin_fails <> 0 or locked_until is not null;
  update fq_staff_guard set fails = 0, locked_until = null where id = 1;

  insert into fq_reset_log (participants_deleted, draws_deleted, note)
    values (np, nd, 'fq_reset (図鑑 ' || nz || ' / ゴール ' || ng || ' / 引換券 ' || nv
                    || ' / 大抽選会 / 笑顔の投票 ' || ns || ' / ガチャ券 ' || nt || ' も削除)');

  return json_build_object('ok', true, 'participants', np, 'draws', nd,
                           'zukan', nz, 'goal', ng, 'vouchers', nv, 'smile_votes', ns, 'tickets', nt);
end; $$;


-- ------------------------------------------------------------
-- 9. アプリから呼べるようにする
-- ------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'fq_g2_state(text,text)', 'fq_g2_draw(text,text)',
    'fq_team_create(text,text)', 'fq_team_join(text,text,text)', 'fq_team_leave(text,text)',
    'fq_staff_login(text,text)', 'fq_ticket_unlock(text,text)', 'fq_ticket_watch(text,text)',
    'fq_ticket_hand(text,text)', 'fq_staff_pending(text)', 'fq_admin_g2_data(text)', 'fq_reset(text)']
  loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;
