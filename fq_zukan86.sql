-- fq_zukan86.sql ［SupabaseのSQL・福祉クエスト］
-- 図鑑を86体にする ＋ 8か所ゴールのごほうびを「あなたのモンスター（診断のキャラ）」にする
--  1. 図鑑の体数 69 → 86、ゴールの子（goal_char）30 → 0（ふつうのなかまにする）
--  2. zukan_scan を作り直す：ゴールの子がいなくても「8か所ゴール」を記録して、お祝いを出す
--     （引数も戻り値の形も同じ。ちがうのは、ゴールの子を渡すのが goal_char > 0 のときだけになったこと）
--  3. いま持っている子の番号を、86体の番号に付け替える（2〜3体で写っていた子は、分けた1体目へ）
--     ★灰色の箱の子（前の No.54）は図鑑からなくなるので、持っている記録も消える
--  ★何度 Run しても同じになるように、付け替えは1回だけ（zukan_config の zk86_done で見張る）
-- 【消すもの】前の No.54 を持っている記録だけ

-- 1.
insert into zukan_config (key, value) values ('char_count', 86) on conflict (key) do update set value = 86;
insert into zukan_config (key, value) values ('goal_char', 0)   on conflict (key) do update set value = 0;

-- 2.
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

  insert into zukan_scans (recog_no, spot, scanned_at, hits)
       values (p_recog, p_spot, coalesce(v_last, now()), 1)
  on conflict (recog_no, spot) do update
     set hits = zukan_scans.hits + 1,
         scanned_at = case when v_last is null
                            or now() >= v_last + make_interval(secs => v_cool)
                           then now() else zukan_scans.scanned_at end;

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

  if v_last is not null and now() < v_last + make_interval(secs => v_cool) then
    v_wait := ceil(extract(epoch from (v_last + make_interval(secs => v_cool)) - now()))::int;
    select count(*) into v_owned from zukan_owned where recog_no = p_recog;
    return json_build_object('ok', false, 'reason', 'cooldown', 'wait', v_wait,
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

-- 3. 番号の付け替え（1回だけ）
do $$
begin
  if exists (select 1 from zukan_config where key = 'zk86_done') then
    raise notice '付け替えは済んでいます';
    return;
  end if;
  create temp table zk86_map (o smallint primary key, n smallint not null) on commit drop;
  insert into zk86_map (o, n) values
  (1,1),
  (2,2),
  (3,6),
  (4,7),
  (5,8),
  (6,9),
  (7,10),
  (8,11),
  (9,12),
  (10,13),
  (11,14),
  (12,15),
  (13,16),
  (14,17),
  (15,18),
  (16,19),
  (17,20),
  (18,21),
  (19,22),
  (20,23),
  (21,24),
  (22,25),
  (23,27),
  (24,28),
  (25,29),
  (26,30),
  (27,31),
  (28,32),
  (29,33),
  (30,34),
  (31,35),
  (32,82),
  (33,36),
  (34,37),
  (35,38),
  (36,39),
  (37,40),
  (38,41),
  (39,42),
  (40,43),
  (41,44),
  (42,45),
  (43,46),
  (44,47),
  (45,48),
  (46,49),
  (47,50),
  (48,53),
  (49,54),
  (50,55),
  (51,56),
  (52,59),
  (53,60),
  (55,61),
  (56,62),
  (57,63),
  (58,64),
  (59,65),
  (60,66),
  (61,67),
  (62,68),
  (63,70),
  (64,71),
  (65,73),
  (66,75),
  (67,78),
  (68,79),
  (69,80);
  create temp table zk86_tmp on commit drop as
    select o.recog_no, m.n as char_id, o.got_at
      from zukan_owned o join zk86_map m on m.o = o.char_id;
  delete from zukan_owned where true;
  insert into zukan_owned (recog_no, char_id, got_at)
    select recog_no, char_id, got_at from zk86_tmp
  on conflict (recog_no, char_id) do nothing;
  insert into zukan_config (key, value) values ('zk86_done', 1);
end $$;

-- 確かめ（Run のあと、下の1行だけ選んで Run）
-- select key, value from zukan_config order by key;   → char_count 86 / goal_char 0 / zk86_done 1
