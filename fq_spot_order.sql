-- ============================================================
-- fq_spot_order.sql ［SupabaseのSQL・福祉クエスト］
-- fq-spot-order-v1 — 図鑑の8か所は「ログポースが指した場所」しか読めないようにする（2026-11-27）
--
--  前：ヒントに出ていない場所のQRを読んでも、なかまが増えた（順番を無視して集められた）
--  後：まだ行っていない場所を読んだとき、それが「つぎの ぼうけん」の場所でなければ受け付けない
--      → お客さんの画面に「ここは ちがう場所みたい。ヒントの場所をさがしてね」とヒントを出す
--  ・もう読んだ場所をもう一度読んだときは、今までどおり「もう読んだよ」
--  ・チームでまわる人は、チームで同じ行き先（今までどおり）
--  ・中身は fq_zukan2.sql の zukan_scan2 のまま。足したのは「つぎの場所か」の確かめだけ
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません。2回流しても大丈夫です
-- 【元に戻すとき】fq_zukan2.sql の「2. 場所のQR」の zukan_scan2 だけを流し直す
-- ============================================================

create or replace function zukan_scan2(p_recog text, p_secret text, p_spot text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_spot text := btrim(coalesce(p_spot, '')); v_lp json; v_next text;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  if not exists (select 1 from logpose_spots where spot = v_spot and enabled) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'bad_spot');
  end if;
  -- fq-spot-order-v1: まだ行っていない場所なら、ログポースが指している場所かを確かめる
  if not exists (select 1 from zukan_scans where recog_no = p_recog and spot = v_spot) then
    v_lp := logpose_state(p_recog);
    v_next := v_lp->'next'->>'spot';
    if v_next is not null and v_next <> v_spot then
      return json_build_object('ok', false, 'reason', 'wrong_spot', 'logpose', v_lp);
    end if;
  end if;
  return zukan_scan(p_recog, v_spot);
end; $$;

revoke all on function zukan_scan2(text, text, text) from public;
grant execute on function zukan_scan2(text, text, text) to anon, authenticated;
