// Buddy drawn on a <canvas>, for pages that show him (whatsnew.html; whatsnew.lua inlines
// this file). Mirrors buddy.lua's drawing, by way of the skins gallery (tools/skins.html):
// the 14×12 body grid at 5 points a cell on a 200×170 box, the skin layers in the same
// order, eyes, arms, blinks and the speech bubble. No particles: pages only need him
// standing, waving and talking. Hooks let a page draw scenery under, beside and over him.
window.BuddyDraw = (() => {
  const S = 5, W = 200, H = 170, BODY_TOP = 98, GROUND = BODY_TOP + 12 * S;
  const rgb = (r, g, b, a = 1) => ({ r, g, b, a });
  const C = {
    body: rgb(.85, .47, .34), shade: rgb(.70, .36, .26), shine: rgb(.94, .62, .50), eye: rgb(.10, .08, .08),
    pink: rgb(.97, .42, .58), blush: rgb(.97, .42, .58, .55), white: rgb(.97, .97, .97), grey: rgb(.58, .60, .64),
    dark: rgb(.20, .21, .24), red: rgb(.86, .22, .22), yellow: rgb(.99, .88, .55), gold: rgb(.98, .78, .25),
    brown: rgb(.48, .31, .19), blue: rgb(.45, .75, .98), shadow: rgb(0, 0, 0, .28), bubble: rgb(1, 1, 1, .95), ink: rgb(.12, .12, .13),
  };
  const BASE_NAMES = ["body", "shade", "shine", "eye", "white", "grey", "dark", "red", "yellow", "gold", "brown", "blue", "pink"];
  const css = c => typeof c === "string" ? c : `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${c.a})`;
  const hex = h => {
    const m = /^#([0-9a-f]{6})([0-9a-f]{2})?$/i.exec(h || "");
    if (!m) return null;
    const n = parseInt(m[1], 16);
    return rgb(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255, m[2] ? parseInt(m[2], 16) / 255 : 1);
  };

  // A skin's JSON (skins/<id>.json) ready to draw. Anything it can't read is left out,
  // so a broken or missing skin draws as plain Buddy.
  function prepare(skin) {
    skin = skin && typeof skin === "object" ? skin : {};
    const base = Object.assign({}, C);
    for (const [k, v] of Object.entries(skin.colors || {})) { const c = hex(v); if (c) base[k] = c; }
    const palette = {};
    for (const [k, v] of Object.entries(skin.palette || {})) { const c = hex(v); if (c) palette[k] = c; }
    const color = name => {
      if (typeof name === "string" && name[0] === "#") return hex(name) || C.white;
      return palette[name] || (BASE_NAMES.includes(name) ? base[name] : null) || C.white;
    };
    const rects = list => (Array.isArray(list) ? list : [])
      .filter(r => Array.isArray(r) && r.length === 5 && r.slice(0, 4).every(Number.isInteger))
      .map(r => [r[0], r[1], r[2], r[3], color(r[4])]);
    const layers = {};
    for (const name of ["behind", "legs", "body", "face", "hand", "top"]) {
      const v = skin[name];
      if (v == null) continue;
      if (name === "legs" && v === false) { layers.legs = false; continue; }
      if (Array.isArray(v)) layers[name] = { fps: 1, frames: [rects(v)] };
      else if (typeof v === "object" && Array.isArray(v.frames) && v.frames.length)
        layers[name] = { fps: v.fps > 0 ? v.fps : 1, frames: v.frames.map(rects) };
    }
    let top = 0;
    for (const f of (layers.top && layers.top.frames) || []) for (const r of f) top = Math.max(top, -r[1]);
    return { skin, base, layers, top, float: skin.float || 0, shadow: skin.shadow ?? 36 };
  }

  function layerAt(P, name, t) {
    const l = P.layers[name];
    if (!l) return l;
    return l.frames[Math.floor(t * l.fps) % l.frames.length];
  }

  function bodyOffset(kind, t) {
    if (kind === "breathe") return [0, Math.floor(Math.sin(t * 2.2) * 1.5 + 0.5)];
    if (kind === "bounce") return [0, -Math.floor(Math.abs(Math.sin(t * 7)) * 10)];
    if (kind === "sway") return [Math.floor(Math.sin(t * 4) * 5 + 0.5), -Math.floor(Math.abs(Math.sin(t * 8)) * 3)];
    return [0, 0];
  }

  function drawEyes(px, kind, blinking, eye, white) {
    const open = { track: 1, ahead: 1 };
    if (blinking && open[kind]) { px(3, 4, 2, 1, eye); px(9, 4, 2, 1, eye); }
    else if (open[kind]) for (const c of [3, 9]) { px(c, 3, 2, 3, eye); px(c, 3, 1, 1, white); }
    else if (kind === "closed") { px(3, 5, 2, 1, eye); px(9, 5, 2, 1, eye); }
    else if (kind === "happy") for (const o of [0, 6]) { px(2 + o, 4, 1, 1, eye); px(3 + o, 3, 2, 1, eye); px(5 + o, 4, 1, 1, eye); }
    else if (kind === "hearts") for (const o of [1, 8]) {
      px(o + 1, 2, 1, 1, C.pink); px(o + 3, 2, 1, 1, C.pink); px(o, 3, 5, 1, C.pink); px(o + 1, 4, 3, 1, C.pink); px(o + 2, 5, 1, 1, C.pink);
    }
  }

  function drawArms(px, kind, f, body) {
    if (kind === "up") {
      const hand = 2 - f % 2;
      px(-1, 4, 1, 1, body); px(-2, 3, 1, 1, body); px(-2, hand, 1, 1, body);
      px(14, 4, 1, 1, body); px(15, 3, 1, 1, body); px(15, hand, 1, 1, body);
    } else if (kind === "wave") {
      px(-1, 5, 1, 2, body); px(14, 4, 1, 1, body); px(15, 3, 1, 1, body); px(15 + f % 2, 2, 1, 1, body);
    } else { px(-1, 5, 1, 2, body); px(14, 5, 1, 2, body); }
  }

  // P from prepare(). opts.script(at) -> { eyes, arms, body, blush } for this moment
  // (default: eyes open, breathing, arms down); opts.under(ctx, at) draws before Buddy,
  // opts.extra(px, at, s) after him in his own grid, opts.over(ctx, at) on top.
  function makeBuddy(P, opts = {}) {
    const st = { t0: performance.now() / 1000, nextBlink: 0, blinkUntil: 0, bubble: null, bubbleUntil: 0,
      talkUntil: 0, flashUntil: 0, box: null };
    function draw(ctx) {
      const now = performance.now() / 1000, at = now - st.t0, f = Math.floor(at * 6);
      const s = Object.assign({ eyes: "track", body: "breathe", arms: "rest" }, opts.script ? opts.script(at) : {});
      const [bx, by] = bodyOffset(s.body, at);
      const ox = Math.floor((W - 14 * S) / 2) + bx, oy = BODY_TOP + by - P.float, cx = ox + 7 * S;
      const px = (c, r, w, h, col) => { ctx.fillStyle = css(col); ctx.fillRect(ox + c * S, oy + r * S, w * S, h * S); };
      const layer = name => { const l = layerAt(P, name, at); if (l) for (const r of l) px(...r); };
      const K = P.base;
      ctx.clearRect(0, 0, W, H);
      if (opts.under) opts.under(ctx, at);
      const lift = Math.max(0, -by), half = Math.max(0, P.shadow - lift);
      ctx.fillStyle = css(C.shadow); ctx.beginPath(); ctx.ellipse(cx, GROUND + 0.5, half, 3.5, 0, 0, Math.PI * 2); ctx.fill();
      layer("behind");
      if (P.layers.legs === undefined) [2, 4, 9, 11].forEach((c, i) => {
        const up = s.body === "sway" && ((i + 1 + f) % 2 === 0) ? 1 : 0;
        px(c, 10, 1, 2 - up, K.shade);
      }); else if (P.layers.legs) layer("legs");
      px(1, 0, 12, 10, K.body); px(0, 1, 1, 8, K.body); px(13, 1, 1, 8, K.body);
      px(1, 9, 12, 1, K.shade); px(2, 1, 2, 1, K.shine);
      if (s.blush) { px(1, 6, 2, 1, C.blush); px(11, 6, 2, 1, C.blush); }
      layer("body");
      if (now > st.nextBlink) { st.blinkUntil = now + 0.14; st.nextBlink = now + 2.5 + Math.random() * 4; }
      drawEyes(px, s.eyes, now < st.blinkUntil, K.eye, C.white);
      const talking = now < st.talkUntil && s.eyes !== "closed";
      if (talking) { if (f % 2 === 0) px(6, 7, 2, 2, K.eye); else px(6, 8, 2, 1, K.eye); }
      else if (s.eyes === "happy" || s.eyes === "hearts") { px(5, 7, 1, 1, K.eye); px(6, 8, 2, 1, K.eye); px(8, 7, 1, 1, K.eye); }
      layer("face");
      drawArms(px, s.arms, f, K.body);
      if (s.arms === "rest") layer("hand");
      layer("top");
      if (opts.extra) opts.extra(px, at, s);
      if (opts.over) opts.over(ctx, at);
      if (st.bubble && now > st.bubbleUntil) { st.bubble = null; st.box = null; }
      if (st.bubble) {
        ctx.font = "600 11.5px -apple-system, system-ui, sans-serif";
        ctx.textAlign = "center"; ctx.textBaseline = "middle";
        const bw = Math.min(W - 6, Math.ceil(ctx.measureText(st.bubble).width) + 18), bh = 24;
        const bxp = Math.max(3, Math.min(W - bw - 3, cx - bw / 2));
        const byp = Math.max(2, BODY_TOP - P.top * S - bh - 22);
        st.box = [bxp, byp, bw, bh];
        ctx.fillStyle = css(now < st.flashUntil ? rgb(1, .86, .72) : C.bubble);
        ctx.beginPath(); ctx.roundRect(bxp, byp, bw, bh, 9); ctx.fill();
        ctx.beginPath(); ctx.moveTo(cx - 6, byp + bh - 1); ctx.lineTo(cx + 6, byp + bh - 1); ctx.lineTo(cx - 1, byp + bh + 8); ctx.fill();
        ctx.fillStyle = css(C.ink); ctx.fillText(st.bubble, bxp + bw / 2, byp + bh / 2 + 1, bw - 10);
      }
    }
    return {
      draw, st,
      say(text, secs = 4) {
        if (!text) return;
        const n = performance.now() / 1000;
        st.bubble = String(text); st.bubbleUntil = n + secs; st.talkUntil = n + 1.4;
      },
      flash(secs = 0.25) { st.flashUntil = performance.now() / 1000 + secs; },
    };
  }

  // A canvas the size of Buddy's box times scale, sharp on Retina.
  function canvas(el, scale) {
    const dpr = window.devicePixelRatio || 1;
    el.width = W * scale * dpr; el.height = H * scale * dpr;
    el.style.width = W * scale + "px"; el.style.height = H * scale + "px";
    const ctx = el.getContext("2d"); ctx.scale(scale * dpr, scale * dpr);
    return ctx;
  }

  return { W, H, S, BODY_TOP, prepare, makeBuddy, canvas };
})();
