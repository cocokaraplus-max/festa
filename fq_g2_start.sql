-- fq_g2_start.sql ［SupabaseのSQL・福祉クエスト］
-- 「ガチャへの道」をスタートさせるQRを作る（fq-g2-start-v1）
--  ・会場の入口に貼る「スタートのQR」。読むまでは、ガチャへの道の行き先を出さない
--  ・ブースのQRと同じしくみ（?q=start.〇〇〇〇〇〇〇〇〇〇）。うしろの10文字はランダムで、家からは打ちこめない
--  ・ポイントは0（ガチャ券の数には関係しない）
--  ・大会リセットで「読んだ記録」は消えるので、当日の朝からまた読む必要がある（QRそのものはそのまま）
-- 【消すもの】ありません。2回以上 Run しても、QRは1つのまま（作り直されません）

insert into fq_codes (code, base, label, points, enabled, sort)
values ('start.' || substr(md5(random()::text || clock_timestamp()::text), 1, 10), 'start', 'ガチャへの道スタート', 0, true, 0)
on conflict (base) do nothing;

-- 確かめ（Run のあと、下の1行だけ貼って Run）
-- select base, label, enabled from fq_codes where base = 'start';   → start / ガチャへの道スタート / true
