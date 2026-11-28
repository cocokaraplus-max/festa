-- ============================================================
-- fq_card.sql ［SupabaseのSQL・福祉クエスト］
-- fq-card-v1 — 紙のスタンプカード（スマホを使わない人もガチャ）（2026-11-28）
--
--  ・いま作ってあるスタンプラリーのカードを そのまま使う。QRは使わない。カードに番号を手書きする
--  ・ブースでスタンプ。3つそろったら1Fの受付へ。受付の端末でガチャをまわす
--     はじめて … 受付で「はじめての方」→ まわすと番号が出る → カードにその番号を手書き
--     2回目  … カードの番号を受付の端末に入れて まわす
--  ・景品はスマホの人と同じところから出る（在庫もいっしょに減る）。1枚2回まで
--  ・当たりは、いつもの当たりと同じ（景品モニターに出る・「渡しました」を押す）
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません。2回流しても大丈夫です
-- ============================================================

create table if not exists fq_cards (
  code      text primary key,               -- 中で使う印（推測できない文字列）
  no        int  not null unique,           -- カードに手書きする番号
  recog_no  text,                           -- はじめてガチャをまわしたときに付ける認識番号
  made_at   timestamptz not null default now()
);
alter table fq_cards enable row level security;   -- 直接は読めない（下の関数からだけ）

-- 管理画面：カードの数
create or replace function fq_admin_card_list(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(0.5); return json_build_object('ok', false, 'reason', 'pass'); end if;
  return json_build_object('ok', true, 'cards', (select count(*) from fq_cards),
    'draws', (select count(*) from fq_tickets t join fq_cards c on c.recog_no = t.recog_no where t.drawn_at is not null),
    'wins',  (select count(*) from fq_tickets t join fq_cards c on c.recog_no = t.recog_no where t.is_win));
end; $$;

-- 受付：カードの様子
create or replace function fq_card_state(p_staff text, p_no int)
returns json
language plpgsql security definer set search_path = public as $$
declare c fq_cards;
begin
  if fq_staff_ok(p_staff) is null then perform pg_sleep(0.5); return json_build_object('ok', false, 'reason', 'staff'); end if;
  select * into c from fq_cards where no = p_no;
  if c.code is null then perform pg_sleep(0.3); return json_build_object('ok', false, 'reason', 'bad_card'); end if;
  return json_build_object('ok', true, 'no', c.no, 'recog', c.recog_no, 'max', 2,
    'list', coalesce((select json_agg(json_build_object('token', t.token, 'round', t.round, 'is_win', t.is_win,
                        'prize_no', t.prize_no, 'prize_name', t.prize_name, 'drawn_at', t.drawn_at,
                        'handed_at', t.handed_at, 'handed_by', t.handed_by) order by t.round)
                        from fq_tickets t where t.recog_no = c.recog_no and t.drawn_at is not null
                          and exists (select 1 from fq_devices d where d.recog_no = c.recog_no)), '[]'::json));
end; $$;

-- 受付：カードでガチャをまわす（中身は fq_g2_draw と同じ選び方）
create or replace function fq_card_draw(p_staff text, p_no int)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_who text; c fq_cards; v_r text; v_round int; t fq_tickets;
        v_lose int; v_stock int; v_x double precision; v_acc int := 0; p record; won prizes;
begin
  v_who := fq_staff_ok(p_staff);
  if v_who is null then perform pg_sleep(0.5); return json_build_object('ok', false, 'reason', 'staff'); end if;
  if coalesce(p_no, 0) = 0 then
    -- はじめての方：新しい番号のカードを作る
    perform pg_advisory_xact_lock(hashtext('fq_card_new'));
    insert into fq_cards (code, no) values (encode(extensions.gen_random_bytes(8), 'hex'), (select coalesce(max(no), 0) + 1 from fq_cards))
    returning * into c;
  else
    select * into c from fq_cards where no = p_no for update;
    if c.code is null then perform pg_sleep(0.3); return json_build_object('ok', false, 'reason', 'bad_card'); end if;
  end if;

  -- はじめて（または大会リセットのあと）なら、このカードの認識番号を作る
  v_r := c.recog_no;
  if v_r is null or not exists (select 1 from fq_devices where recog_no = v_r) then
    v_r := lpad(nextval('recog_seq')::text, 4, '0');
    insert into fq_devices (recog_no, secret_hash) values (v_r, encode(extensions.gen_random_bytes(32), 'hex'));   -- 鍵は使わない（スマホでは開けない）
    update fq_cards set recog_no = v_r where code = c.code;
  end if;
  perform pg_advisory_xact_lock(hashtext('fq_g2_draw:' || v_r));

  if exists (select 1 from fq_tickets where recog_no = v_r and is_win and handed_at is null) then
    return json_build_object('ok', false, 'reason', 'claim_first');
  end if;
  select count(*) + 1 into v_round from fq_tickets where recog_no = v_r and drawn_at is not null;
  if v_round > 2 then return json_build_object('ok', false, 'reason', 'done'); end if;

  insert into fq_tickets (token, recog_no, round, status, unlocked_at, unlocked_by)
       values (encode(extensions.gen_random_bytes(16), 'hex'), v_r, v_round, 'unlocked', now(), v_who || '（カード）')
  returning * into t;

  perform 1 from prizes where stock > 0 for update;
  select coalesce(sum(stock), 0) into v_stock from prizes where stock > 0;
  v_lose := greatest(0, fq_setting('lose_weight', 3000));
  v_x := random() * (v_stock + v_lose);
  if v_stock > 0 and v_x < v_stock then
    for p in select * from prizes where stock > 0 order by sort asc, created_at asc loop
      v_acc := v_acc + p.stock;
      if v_x < v_acc then
        update prizes set stock = stock - 1 where id = p.id returning * into won;
        exit;
      end if;
    end loop;
  end if;

  update fq_tickets set status = 'drawn', drawn_at = now(), is_win = (won.id is not null),
                        prize_id = won.id, prize_no = won.sort, prize_name = won.name, rarity = won.rarity
   where token = t.token returning * into t;
  insert into fq_draw_log (recog_no, cost, is_win, token) values (v_r, 0, t.is_win, t.token);
  insert into draws (recog_no, rarity, is_win, prize_id, prize_name)
       values (v_r, coalesce(won.rarity, 0), t.is_win, won.id, won.name);

  return json_build_object('ok', true, 'no', c.no, 'recog', v_r, 'win', t.is_win, 'round', t.round,
                           'prize_no', t.prize_no, 'prize_name', t.prize_name, 'rarity', coalesce(t.rarity, 0),
                           'token', t.token);
end; $$;

revoke all on function fq_admin_card_list(text) from public;
revoke all on function fq_card_state(text, int) from public;
revoke all on function fq_card_draw(text, int) from public;
grant execute on function fq_admin_card_list(text) to anon, authenticated;
grant execute on function fq_card_state(text, int) to anon, authenticated;
grant execute on function fq_card_draw(text, int) to anon, authenticated;

-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select count(*) from pg_proc where proname in ('fq_admin_card_list', 'fq_card_state', 'fq_card_draw');   → 3
