-- ============================================================
-- fq_booth_lock.sql ［SupabaseのSQL・福祉クエスト］
-- fq-booth-lock-v1 — ブースのQRは「つぎの行き先」に出ているところしか読めないようにする（2026-11-27）
--
--  困りごと：「話を聞く」に案内されているのに「体験」のQRを読んでも、ガチャ券の数に入ってしまう
--  やること：3階・4階のブースのQR（f3_ / f4_）を読んだとき、
--            ・いまの行き先（fq_g2_nav）と同じブースなら、今までどおり数える
--            ・ちがうブースなら数えない（図鑑の1体も出さない）。行き先をお知らせする
--  ★チームで同じブースに来たとき：先に1人が読むと、ほかの人の行き先が変わることがある。
--    そこで「15分以内に同じチームの人が読んだブース」で、自分がまだその種類を
--    この回で読んでいなければ、続けて読めるようにしてある
--  ★当たった景品を受け取る前（受付で交換する前）と、ガチャをまわす前は、ブースのQRは読めない
--  ★スタート・福祉タイプ診断のQRは、今までどおり
--  中身は fq_zukan2.sql の fq_scan のまま。足したのは「ブースなら行き先を確かめる」ところだけ
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません。2回流しても大丈夫です
-- ============================================================

create or replace function fq_scan(p_recog text, p_secret text, p_code text, p_nick text)
returns json
language plpgsql security definer set search_path = public as $$
declare c fq_codes; v_rows int; v_total int; v_z json := null;
        v_nav json; v_ok boolean; v_cat text; m json; v_drawn int; v_earned int;
begin
  if not fq_auth(p_recog, p_secret) then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'auth');
  end if;
  select * into c from fq_codes where code = btrim(coalesce(p_code,'')) and enabled;
  if c.code is null then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'reason', 'bad_code');
  end if;

  -- fq-booth-lock-v1: ブースのQRは、いまの行き先のところだけ
  if c.base ~ '^f[34]_' and not exists (select 1 from fq_earned where recog_no = p_recog and code = c.code) then
    if exists (select 1 from fq_tickets where recog_no = p_recog and is_win and handed_at is null) then
      return json_build_object('ok', false, 'reason', 'claim_first', 'label', c.label);
    end if;
    v_nav := fq_g2_nav(p_recog);
    v_ok := (v_nav->>'kind') = 'booth' and c.base = 'f' || (v_nav->>'floor') || '_' || (v_nav->>'cat');
    if not v_ok then
      -- 同じチームの人が15分以内に読んだブースで、自分がこの回まだその種類を読んでいなければOK
      v_cat := substring(c.base from 4);
      m := fq_g2_member(p_recog);
      v_drawn := (m->>'drawn')::int; v_earned := (m->>'earned')::int;
      if v_drawn < 2 and v_earned <= v_drawn
         and coalesce((m->'n'->>v_cat)::int, 0) <= v_drawn
         and exists (select 1 from fq_team_members a
                       join fq_team_members b on b.team_id = a.team_id and b.recog_no <> a.recog_no
                       join fq_earned e on e.recog_no = b.recog_no and e.code = c.code
                      where a.recog_no = p_recog and e.earned_at > now() - interval '15 minutes') then
        v_ok := true;
      end if;
    end if;
    if not v_ok then
      return json_build_object('ok', false, 'reason', 'wrong_booth', 'label', c.label, 'nav', v_nav);
    end if;
  end if;

  insert into fq_earned (recog_no, code) values (p_recog, c.code) on conflict do nothing;
  get diagnostics v_rows = row_count;
  -- fq-zukan2-v1: ブースのQR（f3_ / f4_）を はじめて読んだら、図鑑に1体
  if v_rows > 0 and c.base ~ '^f[34]_' then
    v_z := zukan_give(p_recog);
  end if;
  v_total := fq_earned_total(p_recog);
  -- ランキング（participants）は「もらったポイントの合計」をサーバーが書く
  insert into participants (recog_no, nickname, points)
       values (p_recog, left(coalesce(p_nick,''), 20), v_total)
  on conflict (recog_no) do update
     set points = v_total,
         nickname = case when coalesce(p_nick,'') <> '' then left(p_nick, 20) else participants.nickname end,
         updated_at = case when participants.points <> v_total then now() else participants.updated_at end;
  return json_build_object('ok', true, 'new', v_rows > 0, 'base', c.base, 'label', c.label,
                           'points', c.points, 'balance', fq_balance(p_recog), 'earned_total', v_total,
                           'zukan', v_z);
end; $$;

revoke all on function fq_scan(text, text, text, text) from public;
grant execute on function fq_scan(text, text, text, text) to anon, authenticated;

-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select position('fq-booth-lock-v1' in prosrc) > 0 from pg_proc where proname = 'fq_scan';   → true
