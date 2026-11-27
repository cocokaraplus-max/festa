/* FUKUSHI QUEST PWA service worker
   fq-sw-v3 (2026-08-24)
   fq-sw-nocache-v1 (2026-10-05) 画面はブラウザの控えを使わず毎回確かめる
   ------------------------------------------------------------------
   ★v2までの問題：すべての GET を「キャッシュ優先」で返していたため、
     1) Supabase の ranking / prizes 取得（GET）が最初の1回で固定され、
        ランキングも在庫連動も二度と更新されなかった。
     2) index.html も更新が届かず、当日の朝に直しても前日に開いた人には
        古い画面が出続けた。
   ★v3 の方針：
     - 別ドメイン（Supabase / CDN / Google Fonts）は一切さわらない＝素通し。
     - 同一オリジンの HTML と config.js は「ネットワーク優先」。
       つながらない時だけキャッシュを出す（＝オフラインでも開ける）。
     - アイコン・manifest だけ「キャッシュ優先」（変わらないので速さ優先）。
   ------------------------------------------------------------------ */
const CACHE = 'fq326-v74';  // fq-zkbig-v1: 図鑑のキャラを大きく・おたのしみガチャにハズレ
// (旧) const CACHE = 'fq326-v73';  // fq-goal-nocam-v1: ゴールした人には「QRを読む」を出さない
// (旧) const CACHE = 'fq326-v72';  // fq-goal-free-v1: ゴールのあと おたのしみガチャへ・294くん/294ちゃんに ふりがな
// (旧) const CACHE = 'fq326-v71';  // fq-uke-cam-v1: 受付の画面に「受け取りのQRを読む」
// (旧) const CACHE = 'fq326-v70';  // fq-bd-num-v1: 診断の生年月日を数字でも入れられる
// (旧) const CACHE = 'fq326-v69';  // fq-booth-fix-v1: ブースはいつもサーバーに確かめる・古いガチャの箱を隠す
// (旧) const CACHE = 'fq326-v68';  // fq-team-poll-v1: チームのときは6秒ごとに行き先を確かめる
// (旧) const CACHE = 'fq326-v67';  // fq-cat-align-v1: 体験・話を聞く・知るの文字をまん中に
// (旧) const CACHE = 'fq326-v66';  // fq-no-floor-v1: 「○階で読んだ！」を消した
// (旧) const CACHE = 'fq326-v65';  // fq-booth-lock-v1: ブースは行き先のところだけ・済のはんこ
// (旧) const CACHE = 'fq326-v64';  // fq-slot-only-v1: 演出はスロットだけ。揃った なかまが図鑑に入る
// (旧) const CACHE = 'fq326-v63';  // fq-team-ux-v1: チームはえらんでから作る・すぐ戻れる
// (旧) const CACHE = 'fq326-v62';  // fq-spot-lock-v1: 8か所めぐりはガチャ2回のあと
// (旧) const CACHE = 'fq326-v61';  // fq-spot-order-v1: 図鑑はログポースが指した場所だけ
// (旧) const CACHE = 'fq326-v60';  // fq-shiru-v1: 「見る」→「知る」
// (旧) const CACHE = 'fq326-v59';  // fq-shindan-quest-v1: 診断の結果の下に「クエストをはじめる」
// (旧) const CACHE = 'fq326-v58';  // fq-team-names-v1: チームの仲間の なまえ を出す
// (旧) const CACHE = 'fq326-v57';  // fq-qrcam-v1: クエストの中でQRを読むカメラ（lib/jsQR.min.js）
// (旧) const CACHE = 'fq326-v56';  // fq-marche-ig-v3: マルシェの Instagram の札を目立たせる
// (旧) const CACHE = 'fq326-v55';  // fq-marche-ig-v2: マルシェの Instagram のマークを揺らす
// (旧) const CACHE = 'fq326-v54';  // fq-marche-ig-v1: マルシェの看板に Instagram の札
// (旧) const CACHE = 'fq326-v53';  // fq-fx10-v1: 演出を10段階に。1等・特賞はスマホにも花火
// (旧) const CACHE = 'fq326-v52';  // fq-atari-v2: 景品モニターに鐘と花火、なまえと景品番号
// (旧) const CACHE = 'fq326-v51';  // fq-qr-label-v1: QRのテスト用・本番用を色で分けて出す
// (旧) const CACHE = 'fq326-v50';  // fq-self-draw-v1: ガチャは自分のスマホで。受付は当たりの受け取りだけ
// (旧) const CACHE = 'fq326-v49';  // fq-qr-remake-v2: 本番用QRの作り直しは2回確かめる
// (旧) const CACHE = 'fq326-v48';  // fq-qr-remake-v1: QRをテスト用と本番用に分けた
// (旧) const CACHE = 'fq326-v47';  // fq-zukan86-v1: 図鑑の絵を86体に入れかえた
// (旧) const CACHE = 'fq326-v21';  // fq-voucher-v1: lib/qrcode.min.js を足した
// (旧) const CACHE = 'fq326-v20';  // fq-mon7-v1: mon_1〜mon_7 を切り抜き直したので版を上げる
// ★名前を変えずに絵の中身だけ差し替えたときは、必ずここを上げること。
//   上げないと、端末に残った古い絵（白い丸の「日」）が出続ける。
//   ★名前が新しい絵（time.png / time_note.png）は、上げなくても出る。
// ★画像は下で「キャッシュ優先」にしている。版を上げないと、
//   一度端末に取り込まれた古い絵がいつまでも出続ける。
//   ★img/ の絵を差し替えたら、必ずここの数字を上げること。
const ASSETS = ['./', './index.html', './quest.html', './config.js', './manifest.webmanifest',  // fq-swap-home-v1: quest.html も先に保存する
  './icons/icon-192.png', './icons/icon-512.png', './icons/icon-512-maskable.png',
  /* == fq-newcast-v1 ==
     アプリの絵。quest.html の中に埋め込んでいたのを、ファイルに出した。
     ★HTML は毎回ネットから取り直すので、絵を埋め込んだままだと
       1500人ぶんの通信がとんでもない量になる。
     ★ここに書いておくと、最初の1回でまとめて端末に保存される。
     ★絵を差し替えたら、上の CACHE の版を必ず上げること。 */
  './img/app/brand.png', './img/app/gacha.png', './img/app/prize.png',
  './img/app/next.png',
  './img/app/m_jigyosho.png', './img/app/m_talk.png',
  './img/app/m_check.png', './img/app/m_event.png',
  './img/app/sw1.png', './img/app/sw2.png', './img/app/sw3.png',
  './img/app/sw4.png', './img/app/sw5.png', './img/app/sw6.png',
  './lib/qrcode.min.js', './lib/jsQR.min.js', './shop.html'];  // fq-voucher-v1

self.addEventListener('install', e => {
  // 1つでも落ちると全部入らないので、個別に入れて失敗は無視する
  e.waitUntil(
    caches.open(CACHE)
      .then(c => Promise.all(ASSETS.map(u => c.add(u).catch(() => {}))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;

  let url;
  try { url = new URL(req.url); } catch (_) { return; }

  // ★別ドメインは素通し（Supabase API・supabase-js CDN・Google Fonts）
  if (url.origin !== self.location.origin) return;

  const isShell =
    req.mode === 'navigate' ||
    url.pathname.endsWith('/') ||
    url.pathname.endsWith('.html') ||
    url.pathname.endsWith('config.js');

  if (isShell) {
    // ネットワーク優先：新しいのが取れたらそれを出し、控えも更新する
    e.respondWith(
      // ★fq-sw-nocache-v1: ブラウザの控え（最大10分）を使わず、毎回サーバーに確かめる
      fetch(req.url, { cache: 'no-cache', credentials: 'same-origin' })
        .then(res => {
          if (res && res.ok) {
            const cp = res.clone();
            caches.open(CACHE).then(c => c.put(req, cp)).catch(() => {});
          }
          return res;
        })
        .catch(() => caches.match(req).then(r => r || caches.match('./index.html')))
    );
    return;
  }

  // アイコン等：キャッシュ優先
  e.respondWith(
    caches.match(req).then(r => r || fetch(req).then(res => {
      if (res && res.ok) {
        const cp = res.clone();
        caches.open(CACHE).then(c => c.put(req, cp)).catch(() => {});
      }
      return res;
    }))
  );
});

// 「今すぐ新しい版に切り替える」用（ページ側から postMessage で呼べる）
self.addEventListener('message', e => {
  if (e.data && e.data.type === 'SKIP_WAITING') self.skipWaiting();
});
