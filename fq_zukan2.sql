-- ============================================================
-- fq-zukan2-v1 — 図鑑のキャラが出る入口を増やす・ずるを防ぐ（2026-11-10）
--
--  ① 場所のQR（?z=）… 会場の8か所（logpose_spots の enabled）しか受け付けない
--                      （前は どんな名前でも受け付けたので、URLを書きかえると家から増やせた）
--                      端末の合言葉（fq_auth）も確かめる → zukan_scan2 を新しく作る
--  ② ブースのQR（3階・4階 × 体験／話を聞く／見る の6種類）… はじめて読んだときに 1体
--  ③ ガチャ … まわすたびに 1体（当たりでもハズレでも）
--  ★福祉タイプ診断のモンスターは端末の中だけで図鑑に出す（ここでは何もしない）
--  ★ゴール報酬の子（goal_char）は、これまでどおり 8か所ぜんぶ回ったときだけ
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【いつ流すか】patch_fq_zukan2_v1.py を push する「前」に1回
--   （先に push すると、図鑑のQRが「読み取れませんでした」になる）
-- 【消すもの】ありません。2回流しても同じ結果になります
-- ============================================================


-- ------------------------------------------------------------
-- 1. キャラを1体わたす（中で使うだけ。アプリからは直接呼べない）
--    まだ持っていない子から選ぶ。ゴール報酬の子は出さない。
--    全部そろっている人には、記念に1体（is_new = false）
-- ------------------------------------------------------------
create or replace function zukan_give(p_recog text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_total int; v_goal int; v_char int; v_rows int; v_new boolean := false; v_owned int;
begin
  select value into v_total from zukan_config where key = 'char_count';
  select value into v_goal  from zukan_config where key = 'goal_char';
  v_total := coalesce(v_total, 69);
  v_goal  := coalesce(v_goal, 0);

  select g.n into v_char
    from generate_series(1, v_total) as g(n)
   where g.n <> v_goal
     and not exists (select 1 from zukan_owned o where o.recog_no = p_recog and o.char_id = g.n)
   order by random() limit 1;

  if v_char is null then
    select g.n into v_char from generate_series(1, v_total) as g(n)
     where g.n <> v_goal order by random() limit 1;
  else
    insert into zukan_owned (recog_no, char_id) values (p_recog, v_char)
    on conflict (recog_no, char_id) do nothing;
    get diagnostics v_rows = row_count;
    v_new := (v_rows > 0);
  end if;

  select count(*) into v_owned from zukan_owned where recog_no = p_recog;
  return json_build_object('char', v_char, 'is_new', v_new, 'owned', v_owned, 'total', v_total);
end; $$;


-- ------------------------------------------------------------
-- 2. 場所のQR（新しい入口）。合言葉と「会場の8か所か」を確かめてから、
--    いままでの zukan_scan（5分待ち・ログポース・ゴール）にそのまま渡す
-- ------------------------------------------------------------
create or replace function zukan_scan2(p_recog text, p_secret text, p_spot text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  if not exists (select 1 from logpose_spots where spot = btrim(coalesce(p_spot, '')) and enabled) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'bad_spot');
  end if;
  return zukan_scan(p_recog, btrim(p_spot));
end; $$;


-- ------------------------------------------------------------
-- 3. ブースのQR（fq_scan）… 中身は fq_voucher.sql のまま。
--    ★足したのは「6種類のブースのQRを はじめて読んだら 1体」の2行と、返り値の zukan だけ
-- ------------------------------------------------------------
create or replace function fq_scan(p_recog text, p_secret text, p_code text, p_nick text)
returns json
language plpgsql security definer set search_path = public as $$
declare c fq_codes; v_rows int; v_total int; v_z json := null;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  select * into c from fq_codes where code = btrim(coalesce(p_code,'')) and enabled;
  if c.code is null then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'bad_code');
  end if;
  insert into fq_earned (recog_no, code) values (p_recog, c.code) on conflict do nothing;
  get diagnostics v_rows = row_count;
  -- fq-zukan2-v1: ブースのQR（f3_ / f4_）を はじめて読んだら、図鑑に1体
  if v_rows > 0 and c.base ~ '^f[34]_' then
    v_z := zukan_give(p_recog);
  end if;
  v_total := fq_earned_total(p_recog);
  -- ランキング（participants）は「もらったポイントの合計」をサーバーが書く
  insert into participants (recog_no, nickname, points)
       values (p_recog, left(coalesce(p_nick,''), 20), v_total)
  on conflict (recog_no) do update
     set points = v_total,
         nickname = case when coalesce(p_nick,'') <> '' then left(p_nick, 20) else participants.nickname end,
         updated_at = case when participants.points <> v_total then now() else participants.updated_at end;
  return json_build_object('ok', true, 'new', v_rows > 0, 'base', c.base, 'label', c.label,
                           'points', c.points, 'balance', fq_balance(p_recog), 'earned_total', v_total,
                           'zukan', v_z);
end; $$;


-- ------------------------------------------------------------
-- 4. ガチャ（fq_g2_draw）… 中身は fq_gacha2.sql のまま。
--    ★足したのは「まわしたら 1体」の1行と、返り値の zukan だけ
-- ------------------------------------------------------------
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

  v_z := zukan_give(p_recog);   -- fq-zukan2-v1: ガチャをまわしたら図鑑に1体（当たりでもハズレでも）

  return json_build_object('ok', true, 'win', t.is_win, 'round', t.round,
                           'prize_no', t.prize_no, 'prize_name', t.prize_name, 'rarity', coalesce(t.rarity, 0),
                           'zukan', v_z);
end; $$;


-- ------------------------------------------------------------
-- 5. 権限
--    ★zukan_give と 前の zukan_scan（合言葉なし）は、アプリから直接は呼べないようにする
-- ------------------------------------------------------------
revoke all on function zukan_give(text)                from public, anon, authenticated;
revoke all on function zukan_scan(text, text)          from public, anon, authenticated;
revoke all on function zukan_scan2(text, text, text)   from public;
grant execute on function zukan_scan2(text, text, text) to anon, authenticated;
revoke all on function fq_scan(text, text, text, text) from public;
grant execute on function fq_scan(text, text, text, text) to anon, authenticated;
revoke all on function fq_g2_draw(text, text)          from public;
grant execute on function fq_g2_draw(text, text)       to anon, authenticated;


-- ============================================================
-- 確認用（Run したあとに流すと様子が見えます）
-- ============================================================
-- 会場の8か所（?z= の値）。ここに無い名前のQRは「読み取れません」になる
-- select spot, ord, name, enabled from logpose_spots order by ord;
-- 入口ごとに何体わたったか、はあとから数えられない（どこから来たかは残していない）
-- select count(*) as 所持記録, count(distinct recog_no) as 人数 from zukan_owned;
