-- ============================================================
-- fq_self_draw.sql ［SupabaseのSQL・福祉クエスト］
-- fq-self-draw-v1 — ガチャはお客さんのスマホだけでまわせる。受付は「当たりの受け取り」だけ（2026-11-27）
--
--  前：ガチャ券のQRを受付が読む → お客さんのスマホに「ガチャをまわす」が出る
--  後：「体験」「話を聞く」「見る」がそろったら、その場で「ガチャをまわす」が押せる
--      当たったら、画面に「受け取りのQR」が出る → 1Fの受付で読んでもらい、景品を受け取る
--  ★受け取りのQRは、その人の当たりにしか使えない、推測できない記号。1回渡すと「渡し済み」になる
--  ★当たったら、受付で「景品を渡しました」が押されるまで、つぎのガチャ券は出ない（1回ごとに景品と交換）
--    はずれのときは、そのまま次へ進める
--  ★受付で「景品を渡しました」をまちがえて押したときは、受付の画面から取り消せる（記録は残る）
--  ★元に戻すときは、下の「戻し方」の1行を流す（受付で読む形に戻る）
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません。関数を2つ作り直し（引数と戻り値の形は同じ。返す中身を少し足した）、
--   取り消し用の関数と、取り消しの記録の表を1つずつ足す
-- 【2回流しても】大丈夫です
-- ============================================================

-- 0. 切りかえスイッチ（1 ＝ 自分のスマホでまわす ／ 0 ＝ 受付で読む）
insert into fq_settings (key, value) values ('self_draw', 1) on conflict (key) do nothing;

-- 1. いまの状態：返す中身に「self_draw」と、当たりの「受け取りの記号（token）」を足した
--    ★token は本人（合言葉が合う人）にしか返さない
create or replace function fq_g2_state(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare m json; v_drawn int; v_earned int; t fq_tickets; v_team fq_teams; v_cnt int; v_tok text; v_wait boolean;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  m := fq_g2_member(p_recog);
  v_drawn := (m->>'drawn')::int; v_earned := (m->>'earned')::int;
  -- fq-self-draw-v1: まだ受け取っていない当たりがあるあいだは、つぎの券を出さない
  v_wait := exists (select 1 from fq_tickets where recog_no = p_recog and is_win and handed_at is null);

  if v_earned > v_drawn and v_drawn < 2 and not v_wait then
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
    'self_draw', fq_setting('self_draw', 1) = 1,   -- fq-self-draw-v1
    'claim_wait', v_wait,                          -- fq-self-draw-v1: 受付で景品を受け取るまで待ち
    'member', m,
    'ticket', case when t.token is null then null
                   else json_build_object('token', t.token, 'round', t.round, 'status', t.status) end,
    'results', coalesce((select json_agg(json_build_object('round', x.round, 'is_win', x.is_win, 'prize_no', x.prize_no,
                           'prize_name', x.prize_name, 'rarity', x.rarity, 'handed', x.handed_at is not null,
                           'token', case when x.is_win then x.token end)   -- fq-self-draw-v1: 受け取りのQR
                           order by x.round)
                          from fq_tickets x where x.recog_no = p_recog and x.status = 'drawn'), '[]'::json),
    'team', case when v_team.id is null then null
                 else json_build_object('code', v_team.code, 'count', v_cnt, 'owner', v_team.owner = p_recog) end,
    'nav', fq_g2_nav(p_recog),
    'grand', exists (select 1 from fq_draw_log where recog_no = p_recog));
end; $$;

-- 2. ガチャをまわす：self_draw = 1 なら、受付で読んでいない券でもまわせる
--    ★中身は fq_zukan2.sql のまま。変えたのは「受付で読んだか」の確かめの1か所だけ
create or replace function fq_g2_draw(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public as $$
declare t fq_tickets; v_lose int; v_stock int; v_r double precision; v_acc int := 0; p record; won prizes; v_z json;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  perform pg_advisory_xact_lock(hashtext('fq_g2_draw:' || p_recog));
  -- fq-self-draw-v1: 受け取っていない当たりがあれば、まわせない（1回ごとに景品と交換）
  if exists (select 1 from fq_tickets where recog_no = p_recog and is_win and handed_at is null) then
    return json_build_object('ok', false, 'reason', 'claim_first');
  end if;
  select * into t from fq_tickets where recog_no = p_recog and status <> 'drawn' order by round limit 1 for update;
  if t.token is null then return json_build_object('ok', false, 'reason', 'no_ticket'); end if;
  if t.status <> 'unlocked' then
    if fq_setting('self_draw', 1) <> 1 then
      return json_build_object('ok', false, 'reason', 'not_unlocked');
    end if;
    update fq_tickets set status = 'unlocked', unlocked_at = now(), unlocked_by = '自分のスマホ'   -- fq-self-draw-v1
     where token = t.token returning * into t;
  end if;

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
  insert into fq_draw_log (recog_no, cost, is_win, token) values (p_recog, 0, t.is_win, t.token);
  insert into draws (recog_no, rarity, is_win, prize_id, prize_name)
       values (p_recog, coalesce(won.rarity, 0), t.is_win, won.id, won.name);

  v_z := zukan_give(p_recog);

  return json_build_object('ok', true, 'win', t.is_win, 'round', t.round,
                           'prize_no', t.prize_no, 'prize_name', t.prize_name, 'rarity', coalesce(t.rarity, 0),
                           'zukan', v_z, 'token', case when t.is_win then t.token end);
end; $$;

-- 3. 受付：「景品を渡しました」を取り消す（まちがえて押したとき）。取り消した記録は残す
create table if not exists fq_hand_undo_log (
  id         bigint generated always as identity primary key,
  token      text not null,
  recog_no   text not null,
  prize_name text,
  handed_at  timestamptz,
  handed_by  text,
  undone_by  text,
  undone_at  timestamptz not null default now()
);
alter table fq_hand_undo_log enable row level security;   -- アプリからは読めない（記録だけ）

create or replace function fq_ticket_unhand(p_staff text, p_token text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_who text; t fq_tickets;
begin
  v_who := fq_staff_ok(p_staff);
  if v_who is null then perform pg_sleep(0.5); return json_build_object('ok', false, 'reason', 'staff'); end if;
  select * into t from fq_tickets where token = btrim(coalesce(p_token,'')) for update;
  if t.token is null then return json_build_object('ok', false, 'reason', 'not_found'); end if;
  if not coalesce(t.is_win, false) or t.handed_at is null then
    return json_build_object('ok', true, 'ticket', fq_ticket_json(t));   -- もともと渡していない
  end if;
  insert into fq_hand_undo_log (token, recog_no, prize_name, handed_at, handed_by, undone_by)
       values (t.token, t.recog_no, t.prize_name, t.handed_at, t.handed_by, v_who);
  update fq_tickets set handed_at = null, handed_by = null where token = t.token returning * into t;
  return json_build_object('ok', true, 'ticket', fq_ticket_json(t));
end; $$;
revoke all on function fq_ticket_unhand(text, text) from public;
grant execute on function fq_ticket_unhand(text, text) to anon, authenticated;

revoke all on function fq_g2_state(text, text) from public;
revoke all on function fq_g2_draw(text, text)  from public;
grant execute on function fq_g2_state(text, text) to anon, authenticated;
grant execute on function fq_g2_draw(text, text)  to anon, authenticated;

-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select key, value from fq_settings where key = 'self_draw';   → self_draw / 1
--
-- 戻し方（受付でガチャ券を読む形に戻すとき。この1行だけ流す）
-- update fq_settings set value = 0 where key = 'self_draw';

