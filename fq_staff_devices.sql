-- ============================================================
-- fq-staff-dev-v1 — 受付の端末を、管理画面から見る・解除する（2026-11-10）
--
--  受付の端末 ＝ 受付の暗証番号で登録したスマホやパソコン
--                （受付（管理画面）・受付（景品モニター））
--  ・管理画面に「受付の端末」の一覧を出し、1台ずつ／全部 解除できるようにする（管理画面の合言葉が要る）
--  ・受付の画面の「この端末の受付をやめる」を押したら、サーバーの登録も消す
--  ★解除された端末は、もう一度「受付の暗証番号」を入れるまで使えない
--  ★鍵そのもの（端末の中にあるもの）はサーバーに残していない。残っているのは鍵の指紋（ハッシュ）だけ
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【いつ流すか】patch_fq_staff_dev_v1.py を push する「前」に1回
-- 【消すもの】ありません（流しただけでは何も消えません）。2回流しても同じ結果になります
-- ============================================================

-- 一覧（管理画面の合言葉）
create or replace function fq_admin_staff_list(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  return json_build_object('ok', true, 'list', coalesce((
    select json_agg(json_build_object('id', token_hash, 'label', label, 'created_at', created_at) order by created_at)
      from fq_staff_tokens), '[]'::json));
end; $$;

-- 解除（管理画面の合言葉）。p_id = 'ALL' なら全部
create or replace function fq_admin_staff_remove(p_pass text, p_id text)
returns json
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  if p_id = 'ALL' then
    delete from fq_staff_tokens where true;
  else
    delete from fq_staff_tokens where token_hash = coalesce(p_id, '');
  end if;
  get diagnostics n = row_count;
  return json_build_object('ok', true, 'removed', n);
end; $$;

-- 受付の画面の「この端末の受付をやめる」：自分の登録を消す
create or replace function fq_staff_logout(p_staff text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  delete from fq_staff_tokens
   where token_hash = encode(extensions.digest(coalesce(p_staff, ''), 'sha256'), 'hex');
  get diagnostics n = row_count;
  return json_build_object('ok', true, 'removed', n);
end; $$;

revoke all on function fq_admin_staff_list(text)         from public;
revoke all on function fq_admin_staff_remove(text, text) from public;
revoke all on function fq_staff_logout(text)             from public;
grant execute on function fq_admin_staff_list(text)         to anon, authenticated;
grant execute on function fq_admin_staff_remove(text, text) to anon, authenticated;
grant execute on function fq_staff_logout(text)             to anon, authenticated;
