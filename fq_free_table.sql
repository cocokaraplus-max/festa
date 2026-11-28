-- ============================================================
-- fq_free_table.sql ［SupabaseのSQL・福祉クエスト］
-- fq-free-table-v1 — おたのしみガチャに「台の設定」。人によって 揃いやすい人・揃いにくい人がいる（2026-11-28）
--
--  ・認識番号から、その人の台（設定1〜6）が決まる。何度遊んでも同じ台（あとから変わらない）
--  ・ハズレの割合 ＝ 本部の「free_lose」（いまは30%）＋ 台ごとの上げ下げ
--      設定1 +18%（48%） … 20人に4人    いちばん揃いにくい
--      設定2 +10%（40%） … 20人に4人
--      設定3  +4%（34%） … 20人に4人
--      設定4  -4%（26%） … 20人に4人
--      設定5 -12%（18%） … 20人に3人
--      設定6 -20%（10%） … 20人に1人    いちばん揃いやすい（レア台）
--    全体のハズレはおよそ33%。free_lose を変えると全部の台が同じだけ動く
--  ・おたのしみガチャ（景品なし）だけ。景品のガチャの当たりやすさは変えない
--  ・お客さんの画面には台は出さない
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません。2回流しても大丈夫です
-- ============================================================

create or replace function fq_free_table(p_recog text)
returns int
language sql immutable as $$
  select (array[1,1,1,1, 2,2,2,2, 3,3,3,3, 4,4,4,4, 5,5,5, 6])[1 + (abs(hashtext('fq-table:' || coalesce(p_recog,''))::bigint) % 20)::int];
$$;

create or replace function fq_free_lose_rate(p_recog text)
returns numeric
language sql stable security definer set search_path = public as $$
  select greatest(0, least(95, fq_setting('free_lose', 30)
         + (array[18, 10, 4, -4, -12, -20])[fq_free_table(p_recog)]));
$$;
revoke all on function fq_free_table(text) from public;
revoke all on function fq_free_lose_rate(text) from public;

create or replace function fq_free_draw(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_total int; v_char int; v_mon int; v_n int; v_pick int; v_owned int;
begin
  if not fq_auth(p_recog, p_secret) then return json_build_object('ok', false, 'reason', 'auth'); end if;
  if not exists (select 1 from logpose_goal where recog_no = p_recog) then
    return json_build_object('ok', false, 'reason', 'not_goal');
  end if;
  v_total := coalesce((select value from zukan_config where key = 'char_count'), 86);
  -- まだ持っていない子の数
  select count(*) into v_n from (
    select g.n from generate_series(1, v_total) g(n)
     where not exists (select 1 from zukan_owned o where o.recog_no = p_recog and o.char_id = g.n)
    union all
    select 100 + m.n from generate_series(1, 7) m(n)
     where not exists (select 1 from fq_mon_owned o where o.recog_no = p_recog and o.mon = m.n)) x;
  if v_n = 0 then return json_build_object('ok', true, 'done', true); end if;
  -- fq-free-table-v1: 人ごとの台（設定1〜6）で ハズレの割合を変える
  if random() * 100 < fq_free_lose_rate(p_recog) then
    return json_build_object('ok', true, 'lose', true);
  end if;
  select x.n into v_pick from (
    select g.n from generate_series(1, v_total) g(n)
     where not exists (select 1 from zukan_owned o where o.recog_no = p_recog and o.char_id = g.n)
    union all
    select 100 + m.n from generate_series(1, 7) m(n)
     where not exists (select 1 from fq_mon_owned o where o.recog_no = p_recog and o.mon = m.n)) x
   order by random() limit 1;
  if v_pick > 100 then
    v_mon := v_pick - 100;
    insert into fq_mon_owned (recog_no, mon, src) values (p_recog, v_mon, 'free') on conflict do nothing;
    return json_build_object('ok', true, 'mon', v_mon, 'is_new', true, 'complete', fq_is_complete(p_recog));
  end if;
  v_char := v_pick;
  insert into zukan_owned (recog_no, char_id) values (p_recog, v_char) on conflict do nothing;
  select count(*) into v_owned from zukan_owned where recog_no = p_recog;
  return json_build_object('ok', true, 'char', v_char, 'is_new', true, 'owned', v_owned, 'total', v_total,
                           'complete', fq_is_complete(p_recog));
end; $$;

revoke all on function fq_free_draw(text, text) from public;
grant execute on function fq_free_draw(text, text) to anon, authenticated;

-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select position('fq-free-table-v1' in prosrc) > 0 from pg_proc where proname = 'fq_free_draw';   → true
