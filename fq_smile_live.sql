-- ============================================================
-- fq_smile_live.sql ［SupabaseのSQL・福祉クエスト］
-- fq-smile-live-v1 — 笑顔コンテストの番号のQRだけ、先に「本番用」を作れるようにする（2026-11-28）
--
--  ・管理画面の「笑顔コンテスト」に「本番用のQRを作る」ボタン（ほかのQRはテスト用のままでよい）
--  ・押すと、番号のQRを作り直して「本番用」と印刷できるようになる。テストで入った票は消える
--  ・あとで「QRコード」の「本番用のQRを作る」を押しても、笑顔コンテストのQRは変えない（印刷した紙はそのまま使える）
--  ・当日（ほかのQRも本番用で、票が入っている）に押しても、断る
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】この SQL を流しただけでは何も消えません（ボタンを押したときに、テストの票だけ消えます）
-- 【2回流しても】大丈夫です
-- ============================================================

insert into fq_admin (key, value) values ('smile_qr_mode', '')    on conflict (key) do nothing;
insert into fq_admin (key, value) values ('smile_qr_made_at', '') on conflict (key) do nothing;

-- 笑顔コンテストのQRだけ本番用にする
create or replace function fq_admin_smile_qr_live(p_pass text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_votes int; v_at text;
begin
  if not fq_admin_ok(p_pass) then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  select count(*) into v_votes from fq_smile_votes;
  if coalesce((select value from fq_admin where key = 'qr_mode'), '') = 'live' and v_votes > 0 then
    return json_build_object('ok', false, 'message', 'ほかのQRが本番用になっていて、票が ' || v_votes || ' 票 入っています。当日の票を守るため、作り直せません。');
  end if;
  delete from fq_smile_votes where true;   -- テストの票
  update fq_smiles
     set code = no || '-' || substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6)
   where true;
  v_at := to_char(now() at time zone 'Asia/Tokyo', 'MM/DD HH24:MI');
  update fq_admin set value = 'live', updated_at = now() where key = 'smile_qr_mode';
  update fq_admin set value = v_at,   updated_at = now() where key = 'smile_qr_made_at';
  return json_build_object('ok', true, 'made_at', v_at, 'votes_deleted', v_votes);
end; $$;

create or replace function fq_admin_qr_info(p_pass text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not fq_admin_ok(p_pass) then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  return json_build_object(
    'ok', true,
    'mode',    coalesce((select value from fq_admin where key = 'qr_mode'), ''),
    'made_at', coalesce((select value from fq_admin where key = 'qr_made_at'), ''),
    'people',  (select count(*) from fq_devices),
    'smile_mode', coalesce((select value from fq_admin where key = 'smile_qr_mode'), ''),          -- fq-smile-live-v1
    'smile_made_at', coalesce((select value from fq_admin where key = 'smile_qr_made_at'), ''));
end; $$;

-- 2. QRを作り直す（p_mode は 'test' か 'live'）
create or replace function fq_admin_qr_remake(p_pass text, p_mode text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r record; v_new text; v_people int; v_at text;
begin
  if not fq_admin_ok(p_pass) then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'message', '合言葉が違います');
  end if;
  if p_mode is null or p_mode not in ('test', 'live') then
    return json_build_object('ok', false, 'message', 'テスト用か本番用かが分かりません');
  end if;

  -- お客さんの記録が1件でもあれば作り直さない（当日の押しまちがいで、印刷したQRがだめになるのを防ぐ）
  lock table fq_devices in share row exclusive mode;
  select count(*) into v_people from fq_devices;
  if v_people > 0
     or exists (select 1 from fq_earned)
     or exists (select 1 from zukan_scans)
     or exists (select 1 from fq_smile_votes) then
    return json_build_object('ok', false, 'reason', 'people',
      'message', 'お客さんの記録が ' || v_people || ' 人分あるので、作り直せません。先に「大会リセット」をしてから押してください。');
  end if;

  -- スタート・ブース・診断（?q=）：記号の前（start. f3_exp. など）は同じ。うしろの10文字だけ変える
  update fq_codes
     set code = base || '.' || substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 10)
   where true;   -- Supabase は WHERE のない UPDATE を止めるので「全部」と書く

  -- 図鑑の8か所（?z=）：うしろの5文字だけ変える
  for r in select spot from logpose_spots loop
    loop
      v_new := regexp_replace(r.spot, '-[2-9a-z]{5}$', '') || '-' || fq_rand5();
      exit when not exists (select 1 from logpose_spots where spot = v_new);
    end loop;
    update logpose_spots set spot = v_new, updated_at = now() where spot = r.spot;
  end loop;

  -- 笑顔コンテストの番号（?v=）：うしろの6文字だけ変える
  -- fq-smile-live-v1: 笑顔コンテストだけ先に「本番用」にしてあるときは、そのまま（印刷した紙を守る）
  if coalesce((select value from fq_admin where key = 'smile_qr_mode'), '') <> 'live' then
    update fq_smiles
       set code = no || '-' || substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6)
     where true;
  end if;

  v_at := to_char(now() at time zone 'Asia/Tokyo', 'MM/DD HH24:MI');
  update fq_admin set value = p_mode, updated_at = now() where key = 'qr_mode';
  update fq_admin set value = v_at,   updated_at = now() where key = 'qr_made_at';

  return json_build_object('ok', true, 'mode', p_mode, 'made_at', v_at);
end; $$;


revoke all on function fq_admin_smile_qr_live(text) from public;
grant execute on function fq_admin_smile_qr_live(text) to anon, authenticated;
revoke all on function fq_admin_qr_info(text)         from public;
revoke all on function fq_admin_qr_remake(text, text) from public;
grant execute on function fq_admin_qr_info(text)         to anon, authenticated;
grant execute on function fq_admin_qr_remake(text, text) to anon, authenticated;

-- 確かめ（下の1行だけ をコピーして、SQL Editor を空にしてから貼って Run）
-- select count(*) from fq_admin where key in ('smile_qr_mode', 'smile_qr_made_at');
--   → 2 と出ればOK
