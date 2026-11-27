-- ============================================================
-- fq_rewards.sql ［SupabaseのSQL・福祉クエスト］
-- fq-rewards-v1 — 8か所ゴールのステッカー／図鑑コンプリートの「326さんの似顔絵」の権利（2026-11-27）
--
--  ・8か所ぜんぶ まわった人 → 「ステッカー プレゼント」。景品交換所（受付）で見せるQRを出す
--  ・図鑑コンプリート（なかま86体＋福祉モンスター7体）→ 「326さんに似顔絵を描いてもらえる権利」。先着10名（管理画面で変えられる）
--  ・どちらも、受付でQRを読んで「渡しました」を押す。交換しなくても、おたのしみガチャは遊べる
--  ・コンプリートをサーバーで確かめられるように、おたのしみガチャの結果をサーバーに記録する
--    （前は、おたのしみガチャで出た子はスマホの中だけだった）
--    福祉モンスターは「診断で出た自分の子」（タイプの番号だけ。生年月日は送らない）と、おたのしみガチャで出た子
--  ・大会リセットで、ステッカー・似顔絵の権利・福祉モンスターの記録も消す
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません（表を2つ作って、関数を足す。fq_reset は消すものに2つ足しただけ）
-- 【2回流しても】大丈夫です
-- ============================================================

-- 0. 表
create table if not exists fq_mon_owned (
  recog_no text not null,
  mon      int  not null check (mon between 1 and 7),
  src      text not null default 'free',            -- self＝診断の自分の子 ／ free＝おたのしみガチャ
  got_at   timestamptz not null default now(),
  primary key (recog_no, mon)
);
create table if not exists fq_rewards (
  recog_no   text not null,
  kind       text not null check (kind in ('sticker', 'portrait')),
  token      text not null unique,
  created_at timestamptz not null default now(),
  handed_at  timestamptz,
  handed_by  text,
  primary key (recog_no, kind)
);
alter table fq_mon_owned enable row level security;   -- アプリからは下の関数だけで読み書きする
alter table fq_rewards   enable row level security;
insert into fq_settings (key, value) values ('portrait_limit', 10) on conflict (key) do nothing;   -- 似顔絵は先着10名
insert into fq_settings (key, value) values ('free_lose', 30)      on conflict (key) do nothing;   -- おたのしみガチャのハズレ（%）

-- 1. コンプリートしたか（なかま全部＋福祉モンスター7体）
create or replace function fq_is_complete(p_recog text)
returns boolean
language sql stable security definer set search_path = public as $$
  select (select count(distinct char_id) from zukan_owned
           where recog_no = p_recog
             and char_id between 1 and coalesce((select value from zukan_config where key = 'char_count'), 86))
         >= coalesce((select value from zukan_config where key = 'char_count'), 86)
     and (select count(*) from fq_mon_owned where recog_no = p_recog) >= 7;
$$;
revoke all on function fq_is_complete(text) from public, anon, authenticated;

-- 2. 診断で出た自分のモンスター（番号だけ）
create or replace function fq_mon_self(p_recog text, p_secret text, p_mon int)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_auth(p_recog, p_secret) then return json_build_object('ok', false, 'reason', 'auth'); end if;
  if p_mon is null or p_mon < 1 or p_mon > 7 then return json_build_object('ok', false, 'reason', 'bad'); end if;
  insert into fq_mon_owned (recog_no, mon, src) values (p_recog, p_mon, 'self') on conflict do nothing;
  return json_build_object('ok', true);
end; $$;

-- 3. おたのしみガチャ（8か所ゴールした人だけ。まだ持っていない子だけ出る。ハズレあり）
create or replace function fq_free_draw(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_total int; v_char int; v_mon int; v_n int; v_pick int; v_owned int;
begin
  if not fq_auth(p_recog, p_secret) then return json_build_object('ok', false, 'reason', 'auth'); end if;
  if not exists (select 1 from logpose_goal where recog_no = p_recog) then
    return json_build_object('ok', false, 'reason', 'not_goal');
  end if;
  v_total := coalesce((select value from zukan_config where key = 'char_count'), 86);
  -- まだ持っていない子の数
  select count(*) into v_n from (
    select g.n from generate_series(1, v_total) g(n)
     where not exists (select 1 from zukan_owned o where o.recog_no = p_recog and o.char_id = g.n)
    union all
    select 100 + m.n from generate_series(1, 7) m(n)
     where not exists (select 1 from fq_mon_owned o where o.recog_no = p_recog and o.mon = m.n)) x;
  if v_n = 0 then return json_build_object('ok', true, 'done', true); end if;
  if random() * 100 < fq_setting('free_lose', 30) then
    return json_build_object('ok', true, 'lose', true);
  end if;
  select x.n into v_pick from (
    select g.n from generate_series(1, v_total) g(n)
     where not exists (select 1 from zukan_owned o where o.recog_no = p_recog and o.char_id = g.n)
    union all
    select 100 + m.n from generate_series(1, 7) m(n)
     where not exists (select 1 from fq_mon_owned o where o.recog_no = p_recog and o.mon = m.n)) x
   order by random() limit 1;
  if v_pick > 100 then
    v_mon := v_pick - 100;
    insert into fq_mon_owned (recog_no, mon, src) values (p_recog, v_mon, 'free') on conflict do nothing;
    return json_build_object('ok', true, 'mon', v_mon, 'is_new', true, 'complete', fq_is_complete(p_recog));
  end if;
  v_char := v_pick;
  insert into zukan_owned (recog_no, char_id) values (p_recog, v_char) on conflict do nothing;
  select count(*) into v_owned from zukan_owned where recog_no = p_recog;
  return json_build_object('ok', true, 'char', v_char, 'is_new', true, 'owned', v_owned, 'total', v_total,
                           'complete', fq_is_complete(p_recog));
end; $$;

-- 4. ごほうびの様子（ステッカー・似顔絵）。もらえる条件を満たしていれば、ここでQRを作る
create or replace function fq_reward_state(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_goal boolean; v_comp boolean; v_lim int; v_cnt int; st fq_rewards; pt fq_rewards; v_full boolean := false;
begin
  if not fq_auth(p_recog, p_secret) then return json_build_object('ok', false, 'reason', 'auth'); end if;
  v_goal := exists (select 1 from logpose_goal where recog_no = p_recog);
  v_comp := fq_is_complete(p_recog);
  v_lim  := fq_setting('portrait_limit', 10);
  if v_goal then
    insert into fq_rewards (recog_no, kind, token)
         values (p_recog, 'sticker', 'st.' || encode(gen_random_bytes(9), 'hex')) on conflict do nothing;
  end if;
  if v_comp and not exists (select 1 from fq_rewards where recog_no = p_recog and kind = 'portrait') then
    lock table fq_rewards in share row exclusive mode;   -- 先着の数えまちがいを防ぐ
    select count(*) into v_cnt from fq_rewards where kind = 'portrait';
    if v_cnt < v_lim then
      insert into fq_rewards (recog_no, kind, token)
           values (p_recog, 'portrait', 'pt.' || encode(gen_random_bytes(9), 'hex')) on conflict do nothing;
    else
      v_full := true;
    end if;
  end if;
  select * into st from fq_rewards where recog_no = p_recog and kind = 'sticker';
  select * into pt from fq_rewards where recog_no = p_recog and kind = 'portrait';
  select count(*) into v_cnt from fq_rewards where kind = 'portrait';
  return json_build_object('ok', true, 'goal', v_goal, 'complete', v_comp,
    'sticker',  case when st.token is null then null else json_build_object('token', st.token, 'handed', st.handed_at is not null) end,
    'portrait', case when pt.token is null then null else json_build_object('token', pt.token, 'handed', pt.handed_at is not null) end,
    'portrait_full', (pt.token is null and v_cnt >= v_lim),
    'portrait_limit', v_lim, 'portrait_left', greatest(0, v_lim - v_cnt),
    'mons', coalesce((select json_agg(mon order by mon) from fq_mon_owned where recog_no = p_recog), '[]'::json));
end; $$;

-- 5. 受付：QRを読んだとき／渡したとき／取り消し
create or replace function fq_reward_watch(p_staff text, p_token text)
returns json
language plpgsql security definer set search_path = public as $$
declare r fq_rewards;
begin
  if fq_staff_ok(p_staff) is null then perform pg_sleep(0.5); return json_build_object('ok', false, 'reason', 'staff'); end if;
  select * into r from fq_rewards where token = btrim(coalesce(p_token, ''));
  if r.token is null then return json_build_object('ok', false, 'reason', 'not_found'); end if;
  return json_build_object('ok', true, 'reward', json_build_object('kind', r.kind, 'recog_no', r.recog_no,
    'nickname', coalesce((select nickname from participants where recog_no = r.recog_no), ''),
    'handed', r.handed_at is not null,
    'handed_at', to_char(r.handed_at at time zone 'Asia/Tokyo', 'HH24:MI'), 'handed_by', r.handed_by));
end; $$;

create or replace function fq_reward_hand(p_staff text, p_token text, p_undo boolean default false)
returns json
language plpgsql security definer set search_path = public as $$
declare v_who text;
begin
  v_who := fq_staff_ok(p_staff);
  if v_who is null then perform pg_sleep(0.5); return json_build_object('ok', false, 'reason', 'staff'); end if;
  if coalesce(p_undo, false) then
    update fq_rewards set handed_at = null, handed_by = null where token = btrim(coalesce(p_token, ''));
  else
    update fq_rewards set handed_at = now(), handed_by = v_who where token = btrim(coalesce(p_token, '')) and handed_at is null;
  end if;
  return fq_reward_watch(p_staff, p_token);
end; $$;

-- 6. 管理画面：似顔絵の人数（p_limit を入れると保存）
create or replace function fq_admin_portrait(p_pass text, p_limit int default null)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  if p_limit is not null then
    insert into fq_settings (key, value) values ('portrait_limit', greatest(0, least(1000, p_limit)))
    on conflict (key) do update set value = excluded.value;
  end if;
  return json_build_object('ok', true, 'limit', fq_setting('portrait_limit', 10),
    'issued', (select count(*) from fq_rewards where kind = 'portrait'),
    'handed', (select count(*) from fq_rewards where kind = 'portrait' and handed_at is not null),
    'stickers', (select count(*) from fq_rewards where kind = 'sticker'),
    'stickers_handed', (select count(*) from fq_rewards where kind = 'sticker' and handed_at is not null));
end; $$;

-- 7. 大会リセット：ステッカー・似顔絵・福祉モンスターも消す（中身は fq_gacha2.sql のまま。足したのは2行）
create or replace function fq_reset(p_pass text)
returns json
language plpgsql security definer set search_path = public as $function$
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
  delete from fq_rewards where true;        -- fq-rewards-v1: ステッカー・似顔絵の権利
  delete from fq_mon_owned where true;      -- fq-rewards-v1: 福祉モンスター
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
end; $function$;

revoke all on function fq_mon_self(text, text, int)          from public;
revoke all on function fq_free_draw(text, text)              from public;
revoke all on function fq_reward_state(text, text)           from public;
revoke all on function fq_reward_watch(text, text)           from public;
revoke all on function fq_reward_hand(text, text, boolean)   from public;
revoke all on function fq_admin_portrait(text, int)          from public;
grant execute on function fq_mon_self(text, text, int)        to anon, authenticated;
grant execute on function fq_free_draw(text, text)            to anon, authenticated;
grant execute on function fq_reward_state(text, text)         to anon, authenticated;
grant execute on function fq_reward_watch(text, text)         to anon, authenticated;
grant execute on function fq_reward_hand(text, text, boolean) to anon, authenticated;
grant execute on function fq_admin_portrait(text, int)        to anon, authenticated;

-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select value from fq_settings where key = 'portrait_limit';   → 10
