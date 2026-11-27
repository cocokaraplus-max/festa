-- ============================================================
-- fq_fx10.sql ［SupabaseのSQL・福祉クエスト］
-- fq-fx10-v1 — 当たりの演出を10段階に（2026-11-27）
--
--  ・景品ごとの「演出」を 1〜10 で選べるようにする（前は 1〜4）
--      1〜8：景品モニターの鐘・拍手・太鼓・花火がだんだん派手になる
--      9＝1等、10＝特賞：ファンファーレと大きな花火。お客さんのスマホにも花火が上がる
--  ・いま登録してある景品の演出は、近い段階に1回だけ移す
--      通常あたり(1)→1　虹色(2)→4　フリーズ(3)→6　ネガ反転(4)→9
--  ・景品モニター（atari.html）に、なまえ・景品番号・渡したかも返す
--
-- 【どこに流すか】Supabase（FUKUSHI QUEST のプロジェクト）の SQL Editor
--   ※ TASUKARU の Supabase ではありません。福祉クエストは Supabase が1つだけです
-- 【消すもの】ありません
-- 【2回流しても】大丈夫です（演出の移しかえは1回目だけ）
-- ============================================================

-- 0. 移しかえたかどうかの印
insert into fq_settings (key, value) values ('fx10', 0) on conflict (key) do nothing;

-- 1. いまの景品の演出を10段階に移す（1回だけ）
do $$
begin
  if fq_setting('fx10', 0) = 0 then
    update prizes set rarity = case rarity when 2 then 4 when 3 then 6 when 4 then 9 else 1 end where true;
    update fq_tickets set rarity = case rarity when 2 then 4 when 3 then 6 when 4 then 9 else 1 end where rarity is not null;
    update fq_settings set value = 1 where key = 'fx10';
  end if;
end $$;

-- 2. 景品を保存するとき、演出は 1〜10（中身は fq_voucher.sql のまま。変えたのは 4 → 10 の2か所だけ）
create or replace function fq_admin_prize_save(p_pass text, p_id text, p_name text, p_rarity int, p_initial int,
                                               p_shop_id text, p_description text, p_expires_on text, p_sort int)
returns json
language plpgsql security definer set search_path = public as $$
declare pr prizes; v_diff int;
begin
  if not fq_admin_ok(p_pass) then perform pg_sleep(1); return json_build_object('ok', false, 'message', '合言葉が違います'); end if;
  if coalesce(btrim(p_name),'') = '' then return json_build_object('ok', false, 'message', '景品の名前を入れてください'); end if;
  if coalesce(p_id,'') = '' then
    insert into prizes (name, rarity, stock, initial_stock, sort, shop_id, description, expires_on)
         values (btrim(p_name), greatest(1, least(10, coalesce(p_rarity,1))), greatest(0, coalesce(p_initial,0)),
                 greatest(0, coalesce(p_initial,0)), coalesce(p_sort, 0), nullif(p_shop_id,'')::uuid,
                 coalesce(p_description,''), nullif(p_expires_on,'')::date)
    returning * into pr;
  else
    select * into pr from prizes where id = p_id::uuid for update;
    if pr.id is null then return json_build_object('ok', false, 'message', '景品が見つかりません'); end if;
    v_diff := greatest(0, coalesce(p_initial,0)) - pr.initial_stock;
    update prizes set name = btrim(p_name), rarity = greatest(1, least(10, coalesce(p_rarity,1))),
                      initial_stock = greatest(0, coalesce(p_initial,0)), stock = greatest(0, stock + v_diff),
                      sort = coalesce(p_sort, 0), shop_id = nullif(p_shop_id,'')::uuid,
                      description = coalesce(p_description,''), expires_on = nullif(p_expires_on,'')::date
     where id = pr.id returning * into pr;
  end if;
  return json_build_object('ok', true, 'id', pr.id, 'stock', pr.stock);
end; $$;

-- 3. 景品モニター：なまえ・景品番号・演出（1〜10）・渡したか
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
      select json_agg(json_build_object('recog_no', x.recog_no, 'nickname', x.nickname, 'prize_no', x.prize_no,
                                        'prize_name', x.prize_name, 'rarity', x.rarity, 'drawn_at', x.drawn_at,
                                        'handed', x.handed) order by x.drawn_at)
        from (select t.recog_no, coalesce(p.nickname, '') as nickname, t.prize_no, t.prize_name,
                     coalesce(t.rarity, 1) as rarity, t.drawn_at, t.handed_at is not null as handed
                from fq_tickets t left join participants p on p.recog_no = t.recog_no
               where t.is_win and (p_after is null or t.drawn_at > p_after)
               order by t.drawn_at desc
               limit 12) x), '[]'::json));
end; $$;

revoke all on function fq_admin_prize_save(text,text,text,int,int,text,text,text,int) from public;
grant execute on function fq_admin_prize_save(text,text,text,int,int,text,text,text,int) to anon, authenticated;
revoke all on function fq_staff_wins(text, timestamptz) from public;
grant execute on function fq_staff_wins(text, timestamptz) to anon, authenticated;

-- 確かめ（Run のあと、下の1行だけ選んで Run。--は付けない）
-- select sort as 番号, name as 景品, rarity as 演出 from prizes order by sort;
