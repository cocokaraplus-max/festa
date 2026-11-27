-- ============================================================
-- fq_team_names.sql ［SupabaseのSQL・福祉クエスト］
-- fq-team-names-v1 — チームでまわるとき、仲間の なまえ を画面に出す（2026-11-27）
--
--  ・クエストの画面の「チーム（3人）」の下に、仲間の なまえ を並べる（自分には「あなた」の印）
--  ・なまえを入れていない人は「認識番号 0012」と出す
--  ・中身は fq_self_draw.sql の fq_g2_state のまま。チームの返す中身に members を足しただけ
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【先に流しておくもの】fq_self_draw.sql
-- 【消すもの】ありません。2回流しても大丈夫です
-- ============================================================

create or replace function fq_g2_state(p_recog text, p_secret text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare m json; v_drawn int; v_earned int; t fq_tickets; v_team fq_teams; v_cnt int; v_tok text; v_wait boolean;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  m := fq_g2_member(p_recog);
  v_drawn := (m->>'drawn')::int; v_earned := (m->>'earned')::int;
  -- fq-self-draw-v1: まだ受け取っていない当たりがあるあいだは、つぎの券を出さない
  v_wait := exists (select 1 from fq_tickets where recog_no = p_recog and is_win and handed_at is null);

  if v_earned > v_drawn and v_drawn < 2 and not v_wait then
    select * into t from fq_tickets where recog_no = p_recog and round = v_drawn + 1;
    if t.token is null then
      v_tok := encode(extensions.gen_random_bytes(18), 'hex');
      insert into fq_tickets (token, recog_no, round) values (v_tok, p_recog, v_drawn + 1)
      on conflict (recog_no, round) do nothing;
      select * into t from fq_tickets where recog_no = p_recog and round = v_drawn + 1;
    end if;
  end if;

  select tm.* into v_team from fq_team_members mm join fq_teams tm on tm.id = mm.team_id where mm.recog_no = p_recog;
  if v_team.id is not null then select count(*) into v_cnt from fq_team_members where team_id = v_team.id; end if;

  return json_build_object(
    'ok', true,
    'self_draw', fq_setting('self_draw', 1) = 1,   -- fq-self-draw-v1
    'claim_wait', v_wait,                          -- fq-self-draw-v1: 受付で景品を受け取るまで待ち
    'member', m,
    'ticket', case when t.token is null then null
                   else json_build_object('token', t.token, 'round', t.round, 'status', t.status) end,
    'results', coalesce((select json_agg(json_build_object('round', x.round, 'is_win', x.is_win, 'prize_no', x.prize_no,
                           'prize_name', x.prize_name, 'rarity', x.rarity, 'handed', x.handed_at is not null,
                           'token', case when x.is_win then x.token end)   -- fq-self-draw-v1: 受け取りのQR
                           order by x.round)
                          from fq_tickets x where x.recog_no = p_recog and x.status = 'drawn'), '[]'::json),
    'team', case when v_team.id is null then null
                 else json_build_object('code', v_team.code, 'count', v_cnt, 'owner', v_team.owner = p_recog,
                   -- fq-team-names-v1: チームの仲間（なまえ・認識番号・自分か）。入った順
                   'members', coalesce((select json_agg(json_build_object('nick', coalesce(p.nickname, ''), 'no', mm2.recog_no,
                                                                         'me', mm2.recog_no = p_recog) order by mm2.joined_at)
                                          from fq_team_members mm2 left join participants p on p.recog_no = mm2.recog_no
                                         where mm2.team_id = v_team.id), '[]'::json)) end,
    'nav', fq_g2_nav(p_recog),
    'grand', exists (select 1 from fq_draw_log where recog_no = p_recog));
end; $$;
revoke all on function fq_g2_state(text, text) from public;
grant execute on function fq_g2_state(text, text) to anon, authenticated;
