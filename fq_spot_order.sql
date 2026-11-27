-- ============================================================
-- fq_spot_order.sql ［SupabaseのSQL・福祉クエスト］
-- fq-spot-order-v1 — 図鑑の8か所は「ログポースが指した場所」しか読めないようにする（2026-11-27）
--
--  前：ヒントに出ていない場所のQRを読んでも、なかまが増えた（順番を無視して集められた）
--  後：まだ行っていない場所を読んだとき、それが「つぎの ぼうけん」の場所でなければ受け付けない
--      → お客さんの画面に「ここは ちがう場所みたい。ヒントの場所をさがしてね」とヒントを出す
--  ・もう読んだ場所をもう一度読んだときは、今までどおり「もう読んだよ」
--  ・チームでまわる人は、チーム全員に同じ行き先を出す（あとから入った人がいても、そろうまで同じ場所）
--  ・中身は fq_zukan2.sql の zukan_scan2 のまま。足したのは「つぎの場所か」の確かめだけ
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません。2回流しても大丈夫です
-- 【元に戻すとき】fq_zukan2.sql の「2. 場所のQR」の zukan_scan2 だけを流し直す
-- ============================================================

-- 0. ログポースの「つぎの ぼうけん」：チームのときは、チーム全員で同じ場所を指す（fq-spot-order-v1）
--    前：一人ずつ「自分がまだ行っていない場所」から選んでいたので、
--        あとからチームに入った人や、先に1か所読んだ人がいると、行き先がバラバラになった
--    後：チームのときは「チームの順番で、まだ誰かが行っていない最初の場所」を全員に出す
--        （自分はもう行った場所でも、仲間がまだならそこへ一緒に行く。読むと「もう読んだよ」）
create or replace function logpose_state(p_recog text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_total int; v_visited int; v_next logpose_spots; v_done boolean; v_key text; v_team uuid;
begin
  select count(*) into v_total from logpose_spots where enabled;
  if p_recog is null or length(btrim(p_recog)) = 0 or v_total = 0 then
    return json_build_object('ok', true, 'total', coalesce(v_total,0), 'visited', 0, 'done', false, 'next', null);
  end if;

  select count(*) into v_visited
    from logpose_spots s
   where s.enabled and exists (select 1 from zukan_scans z where z.recog_no = p_recog and z.spot = s.spot);
  v_done := (v_visited >= v_total);

  if not v_done then
    select team_id into v_team from fq_team_members where recog_no = p_recog;
    if v_team is null then
      v_key := p_recog;
      select s.* into v_next from logpose_spots s
       where s.enabled and not exists (select 1 from zukan_scans z where z.recog_no = p_recog and z.spot = s.spot)
       order by md5(v_key || '#' || s.spot) limit 1;
    else
      v_key := 'team:' || v_team::text;
      -- チームの順番で、まだ「誰か」が行っていない最初の場所（8か所を終えた人は数に入れない）
      select s.* into v_next from logpose_spots s
       where s.enabled
         and exists (select 1 from fq_team_members tm
                      where tm.team_id = v_team
                        and (select count(*) from logpose_spots s2
                              where s2.enabled and exists (select 1 from zukan_scans z2 where z2.recog_no = tm.recog_no and z2.spot = s2.spot)) < v_total
                        and not exists (select 1 from zukan_scans z where z.recog_no = tm.recog_no and z.spot = s.spot))
       order by md5(v_key || '#' || s.spot) limit 1;
      if v_next.spot is null then   -- 念のため：見つからなければ自分の分から
        select s.* into v_next from logpose_spots s
         where s.enabled and not exists (select 1 from zukan_scans z where z.recog_no = p_recog and z.spot = s.spot)
         order by md5(v_key || '#' || s.spot) limit 1;
      end if;
    end if;
  end if;

  return json_build_object(
    'ok', true, 'total', v_total, 'visited', v_visited, 'done', v_done,
    'next', case when v_next.spot is null then null else
      json_build_object('spot', v_next.spot, 'ord', v_next.ord, 'name', v_next.name, 'hint', v_next.hint) end);
end; $$;

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
