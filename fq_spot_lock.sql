-- ============================================================
-- fq_spot_lock.sql ［SupabaseのSQL・福祉クエスト］
-- fq-spot-lock-v1 — 図鑑の8か所めぐりは、ガチャを2回まわしてから（2026-11-27）
--
--  前：図鑑の8か所のQRを、ブースより先に読んでも なかまが増えた（8か所からクエストが始まってしまう）
--  後：ガチャを2回まわすまでは、8か所のQRを読んでも受け付けない
--      → お客さんの画面に「8か所めぐりは、ガチャを2回まわしてから。まずはブースをまわろう」
--      → 図鑑の「つぎの ぼうけん」も、それまでは「ロック中」と出す
--  ・もう8か所を終えた人（ゴール済み）は、今までどおり
--  ・ガチャのときに図鑑へ1体ふえるのは、今までどおり
--  ・中身は fq_spot_order.sql の2つの関数のまま。ロックの確かめを足しただけ
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【先に流しておくもの】fq_spot_order.sql
-- 【消すもの】ありません。2回流しても大丈夫です
-- 【元に戻すとき】fq_spot_order.sql を流し直す
-- ============================================================

create or replace function logpose_state(p_recog text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_total int; v_visited int; v_next logpose_spots; v_done boolean; v_key text; v_team uuid; v_drawn int;
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

  v_drawn := coalesce((fq_g2_member(p_recog)->>'drawn')::int, 0);   -- fq-spot-lock-v1
  return json_build_object(
    'ok', true, 'total', v_total, 'visited', v_visited, 'done', v_done,
    'locked', (v_drawn < 2 and not v_done), 'drawn', v_drawn,          -- fq-spot-lock-v1: ガチャを2回まわすまでロック
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
  -- fq-spot-lock-v1: 8か所めぐりは、ガチャを2回まわしてから（それまでは なかまを増やさない）
  if coalesce((fq_g2_member(p_recog)->>'drawn')::int, 0) < 2
     and not exists (select 1 from logpose_goal where recog_no = p_recog) then
    return json_build_object('ok', false, 'reason', 'locked',
                             'drawn', coalesce((fq_g2_member(p_recog)->>'drawn')::int, 0));
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
