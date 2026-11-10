-- ============================================================
-- fq-staff-lookup-v1 — 受付の画面で「認識番号で調べる」（2026-11-10）
--
--  お客さんが「受け取っていない」と言ってきたときに、その場で確かめるための関数。
--  認識番号を入れると、その人のガチャ券ごとに
--    ・いまの状態（券が出ただけ／受付で読んだ／まわした）
--    ・当たりなら 何番の何か
--    ・渡したなら いつ・どの受付の端末で（ログインのときの呼び名）
--  を返す。
--
--  ★受付の端末（暗証番号で登録した端末）からしか呼べない。お客さんのアプリからは何も見えない。
--  ★認識番号は「1」でも「0001」でも「１」（全角）でも同じ人として調べる。
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【いつ流すか】patch_fq_staff_lookup_v1.py を push する「前」に1回
-- 【消すもの】ありません。読むだけの関数です。2回流しても同じ結果になります
-- ============================================================

create or replace function fq_staff_lookup(p_staff text, p_recog text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_who text; v_r text;
begin
  v_who := fq_staff_ok(p_staff);
  if v_who is null then
    perform pg_sleep(0.5);
    return json_build_object('ok', false, 'reason', 'staff');
  end if;

  v_r := translate(coalesce(p_recog, ''), '０１２３４５６７８９', '0123456789');
  v_r := regexp_replace(v_r, '[^0-9]', '', 'g');
  if v_r = '' then return json_build_object('ok', false, 'reason', 'empty'); end if;
  if length(v_r) < 4 then v_r := lpad(v_r, 4, '0'); end if;

  return json_build_object('ok', true, 'recog', v_r,
    'nickname', coalesce((select nickname from participants where recog_no = v_r), ''),
    'list', coalesce((
      select json_agg(json_build_object(
               'token', t.token, 'round', t.round, 'status', t.status,
               'is_win', t.is_win, 'prize_no', t.prize_no, 'prize_name', t.prize_name,
               'unlocked_at', t.unlocked_at, 'unlocked_by', t.unlocked_by,
               'drawn_at', t.drawn_at,
               'handed_at', t.handed_at, 'handed_by', t.handed_by) order by t.round)
        from fq_tickets t where t.recog_no = v_r), '[]'::json));
end; $$;

revoke all on function fq_staff_lookup(text, text) from public;
grant execute on function fq_staff_lookup(text, text) to anon, authenticated;
