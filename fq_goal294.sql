-- fq_goal294.sql ［SupabaseのSQL・福祉クエスト］
-- 8か所ぜんぶ まわったときの ごほうびを「294くん（No.85）と 294ちゃん（No.86）」にする
--  1. ゴールの子を2体にする（goal_char = 85、goal_char2 = 86）
--  2. ふだんの入口（会場の8か所・ブース・ガチャ）では、この2体は出さない
--  3. 8か所ぜんぶ まわった瞬間に、2体とも図鑑に入れる
-- 【消すもの】ありません（設定を2つ書いて、関数を2つ作り直すだけ。引数と戻り値の形は同じ）
--  ★大会リセット前に、ためしで294くん・294ちゃんを持っている人がいても、そのまま残る（リセットで消える）

insert into zukan_config (key, value) values ('goal_char', 85)  on conflict (key) do update set value = 85;
insert into zukan_config (key, value) values ('goal_char2', 86) on conflict (key) do update set value = 86;

-- 1体わたす（ブースのQR・ガチャ）：ゴールの2体は出さない
create or replace function zukan_give(p_recog text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_total int; v_goal int; v_goal2 int; v_char int; v_rows int; v_new boolean := false; v_owned int;
begin
  select value into v_total from zukan_config where key = 'char_count';
  select value into v_goal  from zukan_config where key = 'goal_char';
  select value into v_goal2 from zukan_config where key = 'goal_char2';
  v_total := coalesce(v_total, 86);
  v_goal  := coalesce(v_goal, 0);
  v_goal2 := coalesce(v_goal2, 0);

  select g.n into v_char
    from generate_series(1, v_total) as g(n)
   where g.n not in (v_goal, v_goal2)
     and not exists (select 1 from zukan_owned o where o.recog_no = p_recog and o.char_id = g.n)
   order by random() limit 1;

  if v_char is null then
    select g.n into v_char from generate_series(1, v_total) as g(n)
     where g.n not in (v_goal, v_goal2) order by random() limit 1;
  else
    insert into zukan_owned (recog_no, char_id) values (p_recog, v_char)
    on conflict (recog_no, char_id) do nothing;
    get diagnostics v_rows = row_count;
    v_new := (v_rows > 0);
  end if;

  select count(*) into v_owned from zukan_owned where recog_no = p_recog;
  return json_build_object('char', v_char, 'is_new', v_new, 'owned', v_owned, 'total', v_total);
end; $$;
revoke all on function zukan_give(text) from public, anon, authenticated;

-- 会場の8か所のQR：1か所1回（fq_spot_once のまま）＋ゴールで2体わたす
create or replace function zukan_scan(p_recog text, p_spot text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_cool int; v_total int; v_goal int; v_goal2 int;
  v_last timestamptz;
  v_char int; v_rows int; v_new boolean; v_owned int;
  v_lp json; v_just_goal boolean := false;
  v_lp_total int; v_lp_visited int;
begin
  if p_recog is null or length(btrim(p_recog)) = 0 then
    return json_build_object('ok', false, 'reason', 'no_recog');
  end if;
  if p_spot is null or length(btrim(p_spot)) = 0 then
    return json_build_object('ok', false, 'reason', 'no_spot');
  end if;

  select value into v_total from zukan_config where key = 'char_count';
  select value into v_goal  from zukan_config where key = 'goal_char';
  select value into v_goal2 from zukan_config where key = 'goal_char2';
  v_total := coalesce(v_total, 86);
  v_goal  := coalesce(v_goal, 0);
  v_goal2 := coalesce(v_goal2, 0);

  select scanned_at into v_last
    from zukan_scans where recog_no = p_recog and spot = p_spot;

  insert into zukan_scans (recog_no, spot, scanned_at, hits)
       values (p_recog, p_spot, now(), 1)
  on conflict (recog_no, spot) do update set hits = zukan_scans.hits + 1;

  -- ゴール判定：8か所ぜんぶ → ゴールの2体を図鑑に入れる（fq-goal294-v1）
  select count(*) into v_lp_total from logpose_spots where enabled;
  if v_lp_total > 0 then
    select count(*) into v_lp_visited
      from logpose_spots s
     where s.enabled
       and exists (select 1 from zukan_scans z
                    where z.recog_no = p_recog and z.spot = s.spot);
    if v_lp_visited >= v_lp_total then
      insert into logpose_goal (recog_no) values (p_recog)
      on conflict (recog_no) do nothing;
      get diagnostics v_rows = row_count;
      if v_rows > 0 then
        if v_goal > 0 then
          insert into zukan_owned (recog_no, char_id) values (p_recog, v_goal)
          on conflict (recog_no, char_id) do nothing;
        end if;
        if v_goal2 > 0 then
          insert into zukan_owned (recog_no, char_id) values (p_recog, v_goal2)
          on conflict (recog_no, char_id) do nothing;
        end if;
        v_just_goal := true;
      end if;
    end if;
  end if;

  v_lp := logpose_state(p_recog);

  if v_last is not null then
    select count(*) into v_owned from zukan_owned where recog_no = p_recog;
    return json_build_object('ok', false, 'reason', 'already',
                             'owned', v_owned, 'total', v_total,
                             'logpose', v_lp, 'just_goal', v_just_goal);
  end if;

  select g.n into v_char
    from generate_series(1, v_total) as g(n)
   where g.n not in (v_goal, v_goal2)
     and not exists (select 1 from zukan_owned o
                      where o.recog_no = p_recog and o.char_id = g.n)
   order by random()
   limit 1;

  if v_char is null then
    select g.n into v_char from generate_series(1, v_total) as g(n)
     where g.n not in (v_goal, v_goal2) order by random() limit 1;
    v_new := false;
  else
    insert into zukan_owned (recog_no, char_id) values (p_recog, v_char)
    on conflict (recog_no, char_id) do nothing;
    get diagnostics v_rows = row_count;
    v_new := (v_rows > 0);
  end if;

  select count(*) into v_owned from zukan_owned where recog_no = p_recog;

  return json_build_object('ok', true, 'char', v_char, 'is_new', v_new,
                           'owned', v_owned, 'total', v_total,
                           'logpose', v_lp, 'just_goal', v_just_goal,
                           'goal_char', v_goal);
end; $$;
revoke all on function zukan_scan(text, text) from public, anon, authenticated;

-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select key, value from zukan_config where key like 'goal_char%' order by key;   → goal_char 85 / goal_char2 86
