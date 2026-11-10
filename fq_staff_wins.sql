-- ============================================================
-- fq-atari-v1 — 本部のモニター「ガチャ あたり速報」（2026-11-10）
--
--  ガチャで当たりが出たら、本部のモニター（atari.html）に
--  「認識番号 0012 さん　カフェ券　あたり！」と出すための関数。
--  ★出すのは 認識番号・景品の名前・演出の段階・時刻 だけ。なまえ（ニックネーム）は出さない
--  ★受付の端末と同じ暗証番号で登録した端末からしか呼べない
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【いつ流すか】atari.html を push する前でも後でもよい（流すまでは「つながりません」と出るだけ）
-- 【消すもの】ありません。読むだけの関数です。2回流しても同じ結果になります
-- ============================================================

create or replace function fq_staff_wins(p_staff text, p_after timestamptz)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if fq_staff_ok(p_staff) is null then
    perform pg_sleep(0.5);
    return json_build_object('ok', false, 'reason', 'staff');
  end if;
  return json_build_object('ok', true,
    'total', (select count(*) from fq_tickets where is_win),
    'list', coalesce((
      select json_agg(json_build_object('recog_no', x.recog_no, 'prize_name', x.prize_name,
                                        'rarity', x.rarity, 'drawn_at', x.drawn_at) order by x.drawn_at)
        from (select recog_no, prize_name, coalesce(rarity, 1) as rarity, drawn_at
                from fq_tickets
               where is_win and (p_after is null or drawn_at > p_after)
               order by drawn_at desc
               limit 12) x), '[]'::json));
end; $$;

revoke all on function fq_staff_wins(text, timestamptz) from public;
grant execute on function fq_staff_wins(text, timestamptz) to anon, authenticated;
