-- ============================================================
-- fq-spot-secret-v1 — 図鑑の8か所の記号（?z= のうしろ）を、推測できない形にする（2026-11-10）
--
--  前：iriguchi / hall / cafe … のような分かりやすい英語
--      → URLに ?z=hall と打つだけで、家からキャラを集められた（ゴールの青いネコまで）
--  後：iriguchi-k7m3p のように、うしろにランダムな5文字を付ける
--      → 会場のQRを読まないと分からない
--
--  ・いまある場所の記号に、うしろ5文字を足す（もう付いているものはそのまま。2回流しても同じ）
--  ・管理画面の「ログポース」で新しく場所を足したときも、自動でうしろ5文字が付くようにする
--  ・場所の名前・ヒント・並び順・使う／使わない は変えない
--  ★QRに入れるURLは、管理画面の「ログポース」の各場所の下に出る（新しい記号の形）
--  ★まだ場所のQRは印刷していない前提。印刷したあとに流すと、印刷したQRが使えなくなるので注意
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【いつ流すか】クエストと図鑑を開ける前に1回
-- 【消すもの】ありません。記号の書きかえだけです
-- ============================================================

-- 0. ランダムな5文字（見まちがえやすい 0 o 1 l i は使わない）
create or replace function fq_rand5()
returns text
language sql volatile set search_path = public, extensions as $$
  select string_agg(substr('23456789abcdefghjkmnpqrstuvwxyz', 1 + (get_byte(extensions.gen_random_bytes(1), 0) % 31), 1), '')
    from generate_series(1, 5);
$$;
revoke all on function fq_rand5() from public, anon, authenticated;

-- 1. いまある場所の記号に、うしろ5文字を足す（読んだ記録 zukan_scans も同じ記号に合わせる）
do $$
declare r record; v_new text;
begin
  for r in select spot from logpose_spots where spot !~ '-[2-9a-z]{5}$' loop
    loop
      v_new := r.spot || '-' || fq_rand5();
      exit when not exists (select 1 from logpose_spots where spot = v_new);
    end loop;
    update logpose_spots set spot = v_new, updated_at = now() where spot = r.spot;
    update zukan_scans  set spot = v_new where spot = r.spot;
  end loop;
end $$;

-- 2. 管理画面で新しく場所を足したときも、自動でうしろ5文字を付ける
--    ★中身は fq_logpose.sql のまま。足したのは「新しい記号なら5文字を付ける」の数行だけ
create or replace function logpose_admin_save(
  p_pass text, p_spot text, p_ord int, p_name text, p_hint text, p_enabled boolean)
returns json
language plpgsql security definer set search_path = public as $$
declare ok boolean; v_spot text;
begin
  select (value = p_pass) into ok from fq_admin where key = 'reset_pass';
  if coalesce(ok, false) is not true then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  if p_spot is null or length(btrim(p_spot)) = 0 then
    return json_build_object('ok', false, 'message', '場所の記号（?z= の値）が空です');
  end if;
  v_spot := btrim(p_spot);
  -- fq-spot-secret-v1: まだ無い記号で、うしろ5文字が付いていなければ付ける（推測できないように）
  if not exists (select 1 from logpose_spots where spot = v_spot) and v_spot !~ '-[2-9a-z]{5}$' then
    v_spot := v_spot || '-' || fq_rand5();
  end if;
  insert into logpose_spots (spot, ord, name, hint, enabled, updated_at)
       values (v_spot, coalesce(p_ord,0), coalesce(p_name,''),
               coalesce(p_hint,''), coalesce(p_enabled,true), now())
  on conflict (spot) do update
     set ord = excluded.ord, name = excluded.name, hint = excluded.hint,
         enabled = excluded.enabled, updated_at = now();
  return json_build_object('ok', true, 'spot', v_spot);
end; $$;

revoke all on function logpose_admin_save(text,text,int,text,text,boolean) from public;
grant execute on function logpose_admin_save(text,text,int,text,text,boolean) to anon, authenticated;

-- 確かめる（流したあと、下の1行だけ流すと新しい記号が見えます）
-- select ord, spot, name, enabled from logpose_spots order by ord;
