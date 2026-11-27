-- ============================================================
-- fq_nav_team.sql ［SupabaseのSQL・福祉クエスト］
-- fq-nav-team-v1 — チームの行き先が、1人が読むたびに変わってしまうのを直す（2026-11-27）
--
--  困りごと：3人チームで「3階 話を聞く」に案内 → 1人が読むと、残り2人の行き先が「3階 体験」に変わる
--            （前は「まだ必要な人がいちばん多い種類」を選んでいたので、読んでいない種類に移っていた）
--            → 残りの2人が「話を聞く」を読むと、行き先とちがうので断られる／ばらばらに動く
--  やること：チームの誰かが読みはじめた種類を先に案内する（まだ必要な人が いちばん少ない種類）。
--            全員が読み終わったら、つぎの種類へ。ひとりで回る人は、今までと同じ
--  ★中身は fq_shiru.sql の fq_g2_nav のまま。変えたのは種類を選ぶ1行だけ
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
  need_cnt int[] := array[0,0,0];
  fl_cnt int[] := array[0,0,0,0,0,0];      -- [cat1-3階, cat1-4階, cat2-3階, ...]
  any_ticket boolean := false; all_done boolean := true;
  i int; f int; best int := 0; best_i int := 0; best_f int := 0; k int; sc text; bsc text;
  members text[];
  lbl text;
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

  -- fq-nav-team-v1: チームの誰かが読みはじめたブースを先に（必要な人がいちばん少ないカテゴリ）。
  --   前は「必要な人がいちばん多い」を選んでいたので、1人が読むと 残りの人の行き先が別のブースに変わっていた。
  --   同じなら、人（チーム）ごとに決まった順番
  for i in 1..3 loop
    if need_cnt[i] > 0 then
      k := (100 - need_cnt[i]) * 100 + (('x' || substr(md5(v_seed || ':' || cats[i]), 1, 2))::bit(8)::int % 100);
      if k > best then best := k; best_i := i; end if;
    end if;
  end loop;

  if best_i = 0 then
    if any_ticket then return json_build_object('kind', 'uketsuke'); end if;
    return json_build_object('kind', 'zukan');
  end if;

  -- 階：行ける人がいちばん多い階。同じなら人（チーム）ごとにばらける
  best := -1;
  for f in 3..4 loop
    k := fl_cnt[(best_i-1)*2 + (f-2)] * 100 + (('x' || substr(md5(v_seed || ':' || cats[best_i] || ':' || f), 1, 2))::bit(8)::int % 100);
    if k > best then best := k; best_f := f; end if;
  end loop;
  lbl := case cats[best_i] when 'exp' then '体験' when 'talk' then '話を聞く' else '知る' end;   -- fq-shiru-v1: 「見る」→「知る」
  return json_build_object('kind', 'booth', 'floor', best_f, 'cat', cats[best_i], 'label', lbl,
                           'need', need_cnt[best_i], 'ticket_waiting', any_ticket);
end; $$;


-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select position('fq-nav-team-v1' in prosrc) > 0 from pg_proc where proname = 'fq_g2_nav';   → true
