-- fq_spot_once.sql ［SupabaseのSQL・福祉クエスト］
-- 会場の8か所のQR
--  1. 1か所1回にする（いままでは 5分たつと また読めて、キャラがもう1体もらえた）
--     2回目からは「ここはもう読んだよ」と返す。キャラは渡さない
--  2. チームの人は、つぎの行き先の順番を チームで同じにする（いままでは1人ずつちがっていた）
--     ★チームに入っていない人（ひとりでまわる人）は、これまでどおり1人ずつちがう順番
-- 【消すもの】ありません（関数を2つ作り直すだけ。引数と戻り値の形は同じ。'cooldown' のかわりに 'already' を返す）

create or replace function logpose_state(p_recog text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_total   int;
  v_visited int;
  v_next    logpose_spots;
  v_done    boolean;
  v_key     text;
begin
  select count(*) into v_total from logpose_spots where enabled;
  if p_recog is null or length(btrim(p_recog)) = 0 or v_total = 0 then
    return json_build_object('ok', true, 'total', coalesce(v_total,0),
                             'visited', 0, 'done', false, 'next', null);
  end if;

  select count(*) into v_visited
    from logpose_spots s
   where s.enabled
     and exists (select 1 from zukan_scans z
                  where z.recog_no = p_recog and z.spot = s.spot);

  v_done := (v_visited >= v_total);

  if not v_done then
    -- ★順番の元：チームに入っていればチーム、いなければその人（fq-spot-once-v1）
    select 'team:' || team_id::text into v_key from fq_team_members where recog_no = p_recog;
    v_key := coalesce(v_key, p_recog);
    select s.* into v_next
      from logpose_spots s
     where s.enabled
       and not exists (select 1 from zukan_scans z
                        where z.recog_no = p_recog and z.spot = s.spot)
     order by md5(v_key || '#' || s.spot)
     limit 1;
  end if;

  return json_build_object(
    'ok', true, 'total', v_total, 'visited', v_visited, 'done', v_done,
    'next', case when v_next.spot is null then null else
      json_build_object('spot', v_next.spot, 'ord', v_next.ord,
                        'name', v_next.name, 'hint', v_next.hint) end
  );
end; $$;

create or replace function zukan_scan(p_recog text, p_spot text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_cool int; v_total int; v_goal int;
  v_last timestamptz; v_wait int;
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

  select value into v_cool  from zukan_config where key = 'cooldown_sec';
  select value into v_total from zukan_config where key = 'char_count';
  select value into v_goal  from zukan_config where key = 'goal_char';
  v_cool  := coalesce(v_cool, 300);
  v_total := coalesce(v_total, 86);
  v_goal  := coalesce(v_goal, 0);

  select scanned_at into v_last
    from zukan_scans where recog_no = p_recog and spot = p_spot;

  -- fq-spot-once-v1: 1か所1回。2回目からは「来た回数」だけ数えて、キャラは渡さない
  insert into zukan_scans (recog_no, spot, scanned_at, hits)
       values (p_recog, p_spot, now(), 1)
  on conflict (recog_no, spot) do update set hits = zukan_scans.hits + 1;

  -- ゴール判定（fq-zukan86-v1: ゴールの子がいなくても、ゴールは記録してお祝いを出す）
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
        v_just_goal := true;
      end if;
    end if;
  end if;

  v_lp := logpose_state(p_recog);

  -- fq-spot-once-v1: もう読んだ場所 → キャラは渡さない（ルートとゴールは上で済んでいる）
  if v_last is not null then
    select count(*) into v_owned from zukan_owned where recog_no = p_recog;
    return json_build_object('ok', false, 'reason', 'already',
                             'owned', v_owned, 'total', v_total,
                             'logpose', v_lp, 'just_goal', v_just_goal);
  end if;

  select g.n into v_char
    from generate_series(1, v_total) as g(n)
   where g.n <> v_goal
     and not exists (select 1 from zukan_owned o
                      where o.recog_no = p_recog and o.char_id = g.n)
   order by random()
   limit 1;

  if v_char is null then
    select g.n into v_char from generate_series(1, v_total) as g(n)
     where g.n <> v_goal order by random() limit 1;
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
-- select pg_get_functiondef('zukan_scan(text,text)'::regprocedure) like '%already%' as 一回だけ;   → true
