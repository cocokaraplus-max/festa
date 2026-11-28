-- ============================================================
-- fq_wins_more.sql ［SupabaseのSQL・福祉クエスト］
-- fq-wins-more-v1 — 景品モニターの「さっきの当たり」を、もっと前までスクロールで見られるようにする（2026-11-28）
--  ・開いたときに読む当たりを 12件 → 100件 に。中身は fq_staff_wins の数だけを変えたもの
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません。2回流しても大丈夫です
-- ============================================================

create or replace function fq_staff_wins(p_staff text, p_after timestamptz)
returns json
language plpgsql security definer set search_path = public as $$
begin
  -- fq-wins-more-v1
  if fq_staff_ok(p_staff) is null then
    perform pg_sleep(0.5);
    return json_build_object('ok', false, 'reason', 'staff');
  end if;
  return json_build_object('ok', true,
    'total', (select count(*) from fq_tickets where is_win),
    'list', coalesce((
      select json_agg(json_build_object('recog_no', x.recog_no, 'nickname', x.nickname, 'prize_no', x.prize_no,
                                        'prize_name', x.prize_name, 'rarity', x.rarity, 'drawn_at', x.drawn_at,
                                        'handed', x.handed) order by x.drawn_at)
        from (select t.recog_no, coalesce(p.nickname, '') as nickname, t.prize_no, t.prize_name,
                     coalesce(t.rarity, 1) as rarity, t.drawn_at, t.handed_at is not null as handed
                from fq_tickets t left join participants p on p.recog_no = t.recog_no
               where t.is_win and (p_after is null or t.drawn_at > p_after)
               order by t.drawn_at desc
               limit case when p_after is null then 100 else 30 end) x), '[]'::json));
end; $$;

revoke all on function fq_staff_wins(text, timestamptz) from public;
grant execute on function fq_staff_wins(text, timestamptz) to anon, authenticated;

-- 確かめ（下の1行だけ をコピーして、SQL Editor を空にしてから貼って Run）
-- select position('fq-wins-more-v1' in prosrc) > 0 from pg_proc where proname = 'fq_staff_wins';
--   → true と出ればOK
