-- ============================================================
-- fq_restore.sql ［SupabaseのSQL・福祉クエスト］
-- fq-restore-v1 — 記録をもとに戻す（引きつぎ）（2026-11-28）
--
--  困りごと：プライベートブラウズでタブを閉じた・スマホを変えた などで、
--            アプリが新しい人になってしまい、集めたなかまが0に見える（記録はサーバーに残っている）
--  やること：受付で 認識番号を聞いて「もどすQR」を作る → お客さんのスマホで読む → 前の記録に戻る
--   ・QRは 10分間・1回だけ使える。受付の暗証番号でログインした端末でしか作れない
--   ・戻すと、前のスマホ（なくしたほう）の鍵は使えなくなる
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません。2回流しても大丈夫です
-- ============================================================

create table if not exists fq_restore (
  token_hash text primary key,
  recog_no   text not null,
  made_by    text,
  made_at    timestamptz not null default now(),
  used_at    timestamptz
);
alter table fq_restore enable row level security;   -- 直接は読めない（下の関数からだけ）

-- 受付：もどすQRを作る
create or replace function fq_restore_make(p_staff text, p_recog text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_who text; v_r text; v_tok text;
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
  if not exists (select 1 from fq_devices where recog_no = v_r) then
    return json_build_object('ok', false, 'reason', 'none', 'recog', v_r);
  end if;
  v_tok := encode(extensions.gen_random_bytes(16), 'hex');
  insert into fq_restore (token_hash, recog_no, made_by)
       values (encode(extensions.digest(v_tok, 'sha256'), 'hex'), v_r, v_who);
  return json_build_object('ok', true, 'recog', v_r, 'token', v_tok,
    'nickname', coalesce((select nickname from participants where recog_no = v_r), ''),
    'zukan', (select count(*) from zukan_owned where recog_no = v_r),
    'drawn', (select count(*) from fq_tickets where recog_no = v_r and drawn_at is not null),
    'goal', exists (select 1 from logpose_goal where recog_no = v_r));
end; $$;

-- お客さん：QRの中身を確かめる（まだ戻さない）
create or replace function fq_restore_peek(p_token text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r fq_restore;
begin
  select * into r from fq_restore
   where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if r.recog_no is null or r.used_at is not null or r.made_at < now() - interval '10 minutes' then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'bad');
  end if;
  return json_build_object('ok', true, 'recog', r.recog_no,
    'zukan', (select count(*) from zukan_owned where recog_no = r.recog_no));
end; $$;

-- お客さん：戻す（新しい鍵を渡す。前の鍵は使えなくなる）
create or replace function fq_restore_use(p_token text)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r fq_restore; v_secret text; v_h text;
begin
  v_h := encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  select * into r from fq_restore where token_hash = v_h for update;
  if r.recog_no is null or r.used_at is not null or r.made_at < now() - interval '10 minutes' then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'bad');
  end if;
  v_secret := encode(extensions.gen_random_bytes(24), 'hex');
  update fq_devices set secret_hash = encode(extensions.digest(v_secret, 'sha256'), 'hex') where recog_no = r.recog_no;
  update fq_restore set used_at = now() where token_hash = v_h;
  return json_build_object('ok', true, 'recog', r.recog_no, 'secret', v_secret);
end; $$;

revoke all on function fq_restore_make(text, text) from public;
revoke all on function fq_restore_peek(text) from public;
revoke all on function fq_restore_use(text) from public;
grant execute on function fq_restore_make(text, text) to anon, authenticated;
grant execute on function fq_restore_peek(text) to anon, authenticated;
grant execute on function fq_restore_use(text) to anon, authenticated;

-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select count(*) from pg_proc where proname in ('fq_restore_make', 'fq_restore_peek', 'fq_restore_use');   → 3
