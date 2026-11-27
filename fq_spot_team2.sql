-- ============================================================
-- fq_spot_team2.sql ［SupabaseのSQL・福祉クエスト］
-- fq-spot-team2-v1 — 図鑑の8か所：チームで回っていると、自分が読んだ場所をずっと指して進めない、を直す（2026-11-27）
--
--  困りごと：チームの仲間がまだガチャ2回を終えていない（または遅れている）と、
--            「つぎの ぼうけん」が 自分はもう読んだ場所 を指したままになり、読んでも「もう読んだよ」で進めない
--            （前は「チームの誰かが まだ行っていない場所」を出していたため）
--  やること：チーム全員に同じ並び順を使うのはそのまま。そのなかで「自分がまだ行っていない最初の場所」を出す
--            → 仲間と同じ順番で回るので、いっしょに動けば行き先はそろう。先に進んだ人も待たされない
--  ★中身は fq_spot_lock.sql の logpose_state のまま。変えたのはチームのときの選び方だけ
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません。2回流しても大丈夫です
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
      -- fq-spot-team2-v1: チームの順番（全員同じ並び）で、「自分」がまだ行っていない最初の場所。
      --   前は「誰かがまだ行っていない場所」だったので、仲間がガチャ2回を終えていない／遅れていると、
      --   自分はもう読んだ場所をずっと指して、先に進めなくなっていた
      select s.* into v_next from logpose_spots s
       where s.enabled and not exists (select 1 from zukan_scans z where z.recog_no = p_recog and z.spot = s.spot)
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


-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select position('fq-spot-team2-v1' in prosrc) > 0 from pg_proc where proname = 'logpose_state';   → true
