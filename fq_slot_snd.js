/* == fq-slot-stop-v1 : スロットの音（音のファイルは使わず、その場で作る） ==
   ・BGM（ピコピコのお祭りの曲）… SPIN で始まり、リーチで速く・高くなる。止まったら終わる
   ・リールの音（カラカラ）… 回っているリールの数だけ にぎやかに
   ・止めた音（ガコッ）・リーチの音（キュイーン）・揃った音・ハズレの音・フリーズの「ドーン」
   ・右上の 🔊 で音を消せる（この端末に覚えておく）
   ・サーバーには何もしない */
(function(){
  'use strict';
  var ac = null, out = null, NB = null;
  var KEY = 'fq_snd_off_v1', muted = false;
  try { muted = localStorage.getItem(KEY) === '1'; } catch (e) {}

  /* 音はスマホの決まりで「さわったとき」にしか始められない */
  function unlock(){
    try {
      if (!ac) { ac = new (window.AudioContext || window.webkitAudioContext)(); out = ac.createGain(); out.gain.value = muted ? 0 : 1; out.connect(ac.destination); }
      if (ac.state === 'suspended') ac.resume();
      var b = ac.createBuffer(1, 1, 22050), s = ac.createBufferSource(); s.buffer = b; s.connect(ac.destination); s.start(0);
    } catch (e) {}
  }
  document.addEventListener('pointerdown', unlock, true);
  document.addEventListener('touchend', unlock, true);
  function A(){
    if (!ac) return null;
    if (!NB) { NB = ac.createBuffer(1, ac.sampleRate, ac.sampleRate); var d = NB.getChannelData(0); for (var i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1; }
    return ac;
  }
  function tone(t, f, len, vol, type, dest){
    var a = ac, o = a.createOscillator(), g = a.createGain();
    o.type = type || 'square'; o.frequency.value = f;
    g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(vol, t + 0.008);
    g.gain.exponentialRampToValueAtTime(0.0001, t + len);
    o.connect(g); g.connect(dest || out); o.start(t); o.stop(t + len + 0.03);
  }
  function noise(t, len, vol, freq, type, dest){
    var a = ac, s = a.createBufferSource(); s.buffer = NB;
    var f = a.createBiquadFilter(); f.type = type || 'bandpass'; f.frequency.value = freq; f.Q.value = 0.9;
    var g = a.createGain(); g.gain.setValueAtTime(vol, t); g.gain.exponentialRampToValueAtTime(0.0001, t + len);
    s.connect(f); f.connect(g); g.connect(dest || out); s.start(t, Math.random() * 0.5); s.stop(t + len + 0.03);
  }
  var N = function(n){ return 440 * Math.pow(2, (n - 69) / 12); };   // MIDIの番号 → 周波数

  /* ---- BGM：お祭りっぽい明るいループ（ハ長調・16分×32） ---- */
  var MEL = [72,0,76,0, 79,0,76,79, 81,0,79,0, 76,0,72,0,  74,0,77,0, 81,0,77,81, 79,0,76,0, 74,0,0,0];
  var BAS = [48,0,55,0, 48,0,55,0, 53,0,60,0, 53,0,60,0,  50,0,57,0, 50,0,57,0, 55,0,62,0, 55,0,59,0];
  /* リーチのとき：同じ音を細かく刻んで、だんだん上がる */
  var RMEL = [79,79,79,79, 80,80,80,80, 81,81,81,81, 83,83,84,84];
  var RBAS = [43,0,43,0, 44,0,44,0, 45,0,45,0, 47,0,48,0];
  var bgm = { on: false, step: 0, next: 0, timer: 0, reach: false, bus: null };
  function bgmTick(){
    if (!bgm.on || !ac) return;
    var bpm = bgm.reach ? 190 : 152, dur = 60 / bpm / 4;
    while (bgm.next < ac.currentTime + 0.12) {
      var t = bgm.next, i = bgm.step;
      if (bgm.reach) {
        var m = RMEL[i % 16], b = RBAS[i % 16];
        if (m) tone(t, N(m), dur * 0.9, 0.05, 'square', bgm.bus);
        if (b) tone(t, N(b), dur * 1.6, 0.09, 'triangle', bgm.bus);
        if (i % 4 === 0) noise(t, 0.12, 0.25, 120, 'lowpass', bgm.bus);   // ドッ（鼓動）
      } else {
        var m2 = MEL[i % 32], b2 = BAS[i % 32];
        if (m2) tone(t, N(m2), dur * 1.7, 0.045, 'square', bgm.bus);
        if (b2) tone(t, N(b2), dur * 1.8, 0.08, 'triangle', bgm.bus);
        if (i % 4 === 0) noise(t, 0.09, 0.22, 140, 'lowpass', bgm.bus);   // 太鼓
        if (i % 4 === 2) noise(t, 0.04, 0.06, 7000, 'highpass', bgm.bus); // シャン
      }
      bgm.next += dur; bgm.step++;
    }
  }
  function bgmStart(){
    var a = A(); if (!a) return; bgmStop(true);
    bgm.bus = a.createGain(); bgm.bus.gain.value = 1; bgm.bus.connect(out);
    bgm.on = true; bgm.reach = false; bgm.step = 0; bgm.next = a.currentTime + 0.05;
    bgm.timer = setInterval(bgmTick, 30); bgmTick();
  }
  function bgmReach(){ if (!bgm.on) return; bgm.reach = true; bgm.step = 0; }
  function bgmStop(now){
    bgm.on = false; clearInterval(bgm.timer);
    var bus = bgm.bus; bgm.bus = null;
    if (bus && ac) { try { bus.gain.setTargetAtTime(0.0001, ac.currentTime, now ? 0.01 : 0.12); setTimeout(function(){ try{ bus.disconnect(); }catch(e){} }, 800); } catch (e) {} }
  }

  /* ---- リールのカラカラ ---- */
  var spin = { n: 0, timer: 0 };
  function spinSet(n){
    spin.n = n; clearInterval(spin.timer);
    if (!n || !A()) return;
    spin.timer = setInterval(function(){
      if (!ac) return; var t = ac.currentTime;
      for (var k = 0; k < spin.n; k++) noise(t + k * 0.017, 0.025, 0.05, 2400 + k * 500, 'bandpass');
    }, 60);
  }

  /* ---- 効果音 ---- */
  function stopHit(i){            // ガコッ
    var a = A(); if (!a) return; var t = a.currentTime;
    tone(t, 160 - i * 15, 0.12, 0.35, 'sine'); noise(t, 0.05, 0.4, 900, 'bandpass'); noise(t, 0.12, 0.25, 200, 'lowpass');
  }
  function reach(){               // キュイーン！
    var a = A(); if (!a) return; var t = a.currentTime;
    var o = a.createOscillator(), g = a.createGain(), lfo = a.createOscillator(), lg = a.createGain();
    o.type = 'sawtooth'; o.frequency.setValueAtTime(700, t); o.frequency.exponentialRampToValueAtTime(2600, t + 0.55);
    lfo.frequency.value = 22; lg.gain.value = 60; lfo.connect(lg); lg.connect(o.frequency);
    var f = a.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = 4000;
    g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(0.12, t + 0.05); g.gain.setValueAtTime(0.12, t + 0.5); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.9);
    o.connect(f); f.connect(g); g.connect(out); o.start(t); lfo.start(t); o.stop(t + 0.95); lfo.stop(t + 0.95);
    bgmReach();
  }
  function win(){                 // 揃った！（ピロリロリン↑）
    var a = A(); if (!a) return; var t = a.currentTime + 0.05;
    [72, 76, 79, 84, 88, 91, 96].forEach(function(n, i){ tone(t + i * 0.06, N(n), 0.35, 0.07, 'square'); tone(t + i * 0.06, N(n + 12), 0.25, 0.03, 'sine'); });
    tone(t + 0.45, N(84), 0.9, 0.08, 'square'); tone(t + 0.45, N(88), 0.9, 0.06, 'square'); tone(t + 0.45, N(91), 0.9, 0.06, 'square');
  }
  function lose(){                // ぽわわ〜ん↓
    var a = A(); if (!a) return; var t = a.currentTime + 0.05;
    [[67, 0], [66, 0.28], [65, 0.56]].forEach(function(p){ tone(t + p[1], N(p[0]), 0.3, 0.07, 'triangle'); });
    var o = a.createOscillator(), g = a.createGain(); o.type = 'triangle';
    o.frequency.setValueAtTime(N(64), t + 0.84); o.frequency.exponentialRampToValueAtTime(N(52), t + 1.8);
    g.gain.setValueAtTime(0.08, t + 0.84); g.gain.exponentialRampToValueAtTime(0.0001, t + 1.9);
    o.connect(g); g.connect(out); o.start(t + 0.84); o.stop(t + 1.95);
  }
  function boom(){                // フリーズ・ひび割れの「ドーン」
    var a = A(); if (!a) return; var t = a.currentTime;
    tone(t, 55, 1.6, 0.5, 'sine'); noise(t, 1.4, 0.7, 90, 'lowpass'); noise(t, 0.3, 0.3, 1500, 'bandpass');
  }
  function crack(){               // ピシッ…バリーン
    var a = A(); if (!a) return; var t = a.currentTime;
    for (var i = 0; i < 6; i++) noise(t + i * 0.05 + Math.random() * 0.03, 0.04, 0.3, 4000 + Math.random() * 3000, 'highpass');
  }
  function all(){ bgmStop(true); spinSet(0); }

  /* ---- 🔊 ボタン ---- */
  function btn(){
    var b = document.createElement('button'); b.type = 'button'; b.id = 'fqSnd';
    b.style.cssText = 'position:fixed;top:8px;right:8px;z-index:2147483002;width:42px;height:42px;border-radius:50%;border:2px solid #ffd700;background:rgba(0,0,0,.6);color:#fff;font-size:20px;line-height:1;padding:0;';
    function paint(){ b.textContent = muted ? '🔇' : '🔊'; b.setAttribute('aria-label', muted ? '音を出す' : '音を消す'); }
    paint();
    b.addEventListener('click', function(){
      muted = !muted; paint(); unlock();
      try { localStorage.setItem(KEY, muted ? '1' : '0'); } catch (e) {}
      if (out && ac) out.gain.setTargetAtTime(muted ? 0 : 1, ac.currentTime, 0.02);
    });
    document.body.appendChild(b);
  }
  if (document.body) btn(); else document.addEventListener('DOMContentLoaded', btn);

  function safe(f){ return function(){ try { f.apply(null, arguments); } catch (e) {} }; }
  window.fqSnd = { start: safe(bgmStart), stopBgm: safe(function(){ bgmStop(false); }), spin: safe(spinSet), stop: safe(stopHit),
                   reach: safe(reach), win: safe(win), lose: safe(lose), boom: safe(boom), crack: safe(crack), all: safe(all) };
})();
