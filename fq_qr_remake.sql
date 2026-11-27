-- ============================================================
-- fq_qr_remake.sql ［SupabaseのSQL・福祉クエスト］
-- fq-qr-remake-v1 — 会場のQRを「テスト用」と「本番用」で分ける（2026-11-27）
--   （直し 2026-11-27 17:10：WHERE のない UPDATE が Supabase に止められていたので where true を足した）
--
--  困りごと：学生さんたちとのテストで使ったQRを写真に撮られると、
--            同じQRのまま当日をむかえたら、家からでもポイントや図鑑が取れてしまう
--  やること：管理画面の「QRコード」に、QRの中身を全部作り直すボタンを足す
--            ・「テスト用のQRを作る」… 作り直して、カードに「テスト用」と大きく出す
--            ・「本番用のQRを作る」 … もう一度作り直す。テスト用のQRは全部使えなくなる
--  作り直すもの：スタート・3階/4階のブース・福祉タイプ診断（?q=）
--                図鑑の8か所（?z=）
--                笑顔コンテストの番号（?v=）
--  ★作り直せるのは「大会リセットの直後（お客さんの記録が0件）」だけ。
--    当日まちがえて押しても、お客さんがいれば断るので、印刷したQRは守られる
--  ★場所の名前・ヒント・並び順・使う/使わない、景品、番号の数は変えない
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません。この SQL を流しただけでは、QRは変わりません（ボタンを押したときだけ）
-- 【2回流しても】大丈夫です
-- ============================================================

-- 0. いまのQRが「テスト用」か「本番用」かを覚えておく（はじめは空＝まだ分けていない）
insert into fq_admin (key, value) values ('qr_mode', '')    on conflict (key) do nothing;
insert into fq_admin (key, value) values ('qr_made_at', '') on conflict (key) do nothing;

-- 1. いまの様子（管理画面の「QRコード」を開いたときに呼ぶ）
create or replace function fq_admin_qr_info(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  return json_build_object(
    'ok', true,
    'mode',    coalesce((select value from fq_admin where key = 'qr_mode'), ''),
    'made_at', coalesce((select value from fq_admin where key = 'qr_made_at'), ''),
    'people',  (select count(*) from fq_devices));
end; $$;

-- 2. QRを作り直す（p_mode は 'test' か 'live'）
create or replace function fq_admin_qr_remake(p_pass text, p_mode text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r record; v_new text; v_people int; v_at text;
begin
  if not fq_admin_ok(p_pass) then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  if p_mode is null or p_mode not in ('test', 'live') then
    return json_build_object('ok', false, 'message', 'テスト用か本番用かが分かりません');
  end if;

  -- お客さんの記録が1件でもあれば作り直さない（当日の押しまちがいで、印刷したQRがだめになるのを防ぐ）
  lock table fq_devices in share row exclusive mode;
  select count(*) into v_people from fq_devices;
  if v_people > 0
     or exists (select 1 from fq_earned)
     or exists (select 1 from zukan_scans)
     or exists (select 1 from fq_smile_votes) then
    return json_build_object('ok', false, 'reason', 'people',
      'message', 'お客さんの記録が ' || v_people || ' 人分あるので、作り直せません。先に「大会リセット」をしてから押してください。');
  end if;

  -- スタート・ブース・診断（?q=）：記号の前（start. f3_exp. など）は同じ。うしろの10文字だけ変える
  update fq_codes
     set code = base || '.' || substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 10)
   where true;   -- Supabase は WHERE のない UPDATE を止めるので「全部」と書く

  -- 図鑑の8か所（?z=）：うしろの5文字だけ変える
  for r in select spot from logpose_spots loop
    loop
      v_new := regexp_replace(r.spot, '-[2-9a-z]{5}$', '') || '-' || fq_rand5();
      exit when not exists (select 1 from logpose_spots where spot = v_new);
    end loop;
    update logpose_spots set spot = v_new, updated_at = now() where spot = r.spot;
  end loop;

  -- 笑顔コンテストの番号（?v=）：うしろの6文字だけ変える
  update fq_smiles
     set code = no || '-' || substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6)
   where true;

  v_at := to_char(now() at time zone 'Asia/Tokyo', 'MM/DD HH24:MI');
  update fq_admin set value = p_mode, updated_at = now() where key = 'qr_mode';
  update fq_admin set value = v_at,   updated_at = now() where key = 'qr_made_at';

  return json_build_object('ok', true, 'mode', p_mode, 'made_at', v_at);
end; $$;

revoke all on function fq_admin_qr_info(text)         from public;
revoke all on function fq_admin_qr_remake(text, text) from public;
grant execute on function fq_admin_qr_info(text)         to anon, authenticated;
grant execute on function fq_admin_qr_remake(text, text) to anon, authenticated;

-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select key from fq_admin where key like 'qr_%' order by key;   → qr_made_at / qr_mode の2行
