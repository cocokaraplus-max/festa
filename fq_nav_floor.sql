-- ============================================================
-- fq_nav_floor.sql ［SupabaseのSQL・福祉クエスト］
-- fq-nav-floor-v1 — ブースの案内を「1回分は同じ階で3つ」にして、階と順番をチーム・人ごとにばらけさせる（2026-11-27）
--
--  ・1回目のガチャまでの3つ（体験・話を聞く・知る）は、ぜんぶ同じ階で案内する
--      例）4階 知る → 4階 体験 → 4階 話を聞く → ガチャ1回目 → 3階 話を聞く → 3階 知る → 3階 体験 → ガチャ2回目
--  ・2回目は、もう一方の階
--  ・どちらの階から始めるか（3階／4階）と、3つの順番（6通り）は、チーム（ひとりなら その人）ごとに決まる
--      → 2通り × 6通り ＝ 12通りに ばらけるので、同じブースに人が集まりにくい
--      → 順番は1回目と2回目で ちがう並びになる
--  ・チームの誰かが読みはじめたブースは、全員が読むまで同じ行き先（fq-nav-team-v1 のまま）
--  ・途中まで回っている人（前のやり方で 階が混ざっている人）も、行ける階を見て案内する
--  ★変えたのは fq_g2_nav（行き先を決めるところ）だけ。ブースのQR・ガチャ券の数え方は変えない
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません。2回流しても大丈夫です
-- ============================================================

create or replace function fq_g2_nav(p_recog text)
returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_team uuid; v_seed text; m json; v_drawn int; v_earned int;
  cats text[] := array['exp','talk','see'];
  letters text[] := array['e','t','s'];
  perms text[] := array['ets','est','tes','tse','set','ste'];   -- 体験(e)・話を聞く(t)・知る(s) の並び 6通り
  need_cnt int[] := array[0,0,0];
  fl_cnt int[] := array[0,0,0,0,0,0];      -- [cat1-3階, cat1-4階, cat2-3階, ...]
  any_ticket boolean := false; all_done boolean := true;
  i int; f int; best int := -1; best_i int := 0; best_f int := 0; k int; sc text;
  members text[]; lbl text;
  v_round int := 3; v_perm text; v_pf int; v_of int;
begin
  select team_id into v_team from fq_team_members where recog_no = p_recog;
  if v_team is null then
    members := array[p_recog];
    v_seed := p_recog;
  else
    select array_agg(recog_no order by joined_at) into members from fq_team_members where team_id = v_team;
    v_seed := v_team::text;
  end if;

  foreach sc in array members loop
    m := fq_g2_member(sc);
    v_drawn := (m->>'drawn')::int; v_earned := (m->>'earned')::int;
    if v_drawn >= 2 then continue; end if;
    all_done := false;
    if v_earned > v_drawn then any_ticket := true; continue; end if;
    v_round := least(v_round, v_drawn + 1);
    for i in 1..3 loop
      if ((m->'n'->>cats[i])::int) <= v_drawn then          -- このカテゴリが、いまの回でまだ
        need_cnt[i] := need_cnt[i] + 1;
        for f in 3..4 loop
          if not exists (select 1 from json_array_elements_text(m->'floors'->cats[i]) x where x::int = f) then
            fl_cnt[(i-1)*2 + (f-2)] := fl_cnt[(i-1)*2 + (f-2)] + 1;
          end if;
        end loop;
      end if;
    end loop;
  end loop;

  if all_done then return json_build_object('kind', 'zukan'); end if;

  -- 種類：チームの誰かが読みはじめた種類を先に（必要な人がいちばん少ない）。
  --       同じなら、チーム（人）と回ごとに決まった順番（6通り）
  v_perm := perms[1 + (('x' || substr(md5(v_seed || ':order:' || v_round), 1, 2))::bit(8)::int % 6)];
  for i in 1..3 loop
    if need_cnt[i] > 0 then
      k := (100 - need_cnt[i]) * 10 + (3 - position(letters[i] in v_perm));
      if k > best then best := k; best_i := i; end if;
    end if;
  end loop;

  if best_i = 0 then
    if any_ticket then return json_build_object('kind', 'uketsuke'); end if;
    return json_build_object('kind', 'zukan');
  end if;

  -- 階：1回目は チーム（人）ごとに決まった階、2回目は もう一方の階。
  --     その階に行けない人が多いとき（前に読んだ）だけ、もう一方の階
  v_pf := 3 + (('x' || substr(md5(v_seed || ':floor'), 1, 2))::bit(8)::int % 2);
  if v_round >= 2 then v_pf := 7 - v_pf; end if;
  v_of := 7 - v_pf;
  if fl_cnt[(best_i-1)*2 + (v_pf-2)] >= fl_cnt[(best_i-1)*2 + (v_of-2)] and fl_cnt[(best_i-1)*2 + (v_pf-2)] > 0 then
    best_f := v_pf;
  else
    best_f := v_of;
  end if;

  lbl := case cats[best_i] when 'exp' then '体験' when 'talk' then '話を聞く' else '知る' end;   -- fq-nav-floor-v1
  return json_build_object('kind', 'booth', 'floor', best_f, 'cat', cats[best_i], 'label', lbl,
                           'need', need_cnt[best_i], 'ticket_waiting', any_ticket);
end; $$;

-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select position('fq-nav-floor-v1' in prosrc) > 0 from pg_proc where proname = 'fq_g2_nav';   → true
