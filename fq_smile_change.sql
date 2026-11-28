-- ============================================================
-- fq_smile_change.sql ［SupabaseのSQL・福祉クエスト］
-- fq-smile-change-v1 — 笑顔コンテストは 1人1票。ちがう番号を読んだら「○番への投票に変更しますか？」と聞いてから変える（2026-11-28）
--
--  ・はじめて読んだ → 投票する
--  ・同じ番号をもう一度読んだ → 「もう ○番に投票しているよ（1人1票）」
--  ・ちがう番号を読んだ → スマホに「○番への投票に変更しますか？」。「はい」のときだけ変える（票は1つのまま）
--  ・はじめて投票したとき（変更のときは なし）、図鑑の なかまを1体もらえる
--  ★スマホ1台＝1人として数える
--  ★前の fq_smile_once.sql を流していても、いなくても、これを流せば大丈夫です
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】前の投票の関数（引数3つ）を消して、確認つき（引数4つ）に作り直します。投票の記録は消えません
-- 【2回流しても】大丈夫です
-- ============================================================

drop function if exists fq_smile_vote_code(text, text, text);

create or replace function fq_smile_vote_code(p_recog text, p_secret text, p_code text, p_change boolean default false)
returns json
language plpgsql security definer set search_path = public as $$
declare s fq_smiles; v_prev integer; v_z json := null;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  select * into s from fq_smiles where code = btrim(coalesce(p_code, '')) and active;
  if s.id is null then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'not_found');
  end if;
  if fq_setting('smile_open', 0) <> 1 then
    return json_build_object('ok', false, 'reason', 'closed', 'no', s.no);
  end if;
  select x.no into v_prev from fq_smile_votes v join fq_smiles x on x.id = v.smile_id where v.recog_no = p_recog;
  if v_prev is not null and v_prev = s.no then
    return json_build_object('ok', false, 'reason', 'already', 'no', s.no);              -- 同じ番号
  end if;
  if v_prev is not null and not coalesce(p_change, false) then
    return json_build_object('ok', false, 'reason', 'confirm', 'no', s.no, 'prev_no', v_prev);   -- 変えるか聞く
  end if;
  insert into fq_smile_votes (recog_no, smile_id) values (p_recog, s.id)
    on conflict (recog_no) do update set smile_id = excluded.smile_id, voted_at = now();
  -- はじめての投票なら、図鑑の なかまを1体
  if v_prev is null then v_z := zukan_give(p_recog); end if;
  return json_build_object('ok', true, 'no', s.no, 'prev_no', v_prev, 'zukan', v_z);
end; $$;
revoke all on function fq_smile_vote_code(text, text, text, boolean) from public;
grant execute on function fq_smile_vote_code(text, text, text, boolean) to anon, authenticated;

-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select count(*) from pg_proc where proname = 'fq_smile_vote_code' and pronargs = 4;   → 1
