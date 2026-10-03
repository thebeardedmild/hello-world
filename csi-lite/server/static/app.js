"use strict";

// ---------------------------------------------------------------- constants
const LINKS = ["RA", "RB", "AB"];
const LINK_NAME = { RA: "Router → A", RB: "Router → B", AB: "A ↔ B" };
const LINK_ENDS = { RA: ["R", "A"], RB: ["R", "B"], AB: ["A", "B"] };
const SUBCARRIERS = [];
for (let k = -26; k <= 26; k++) if (k !== 0) SUBCARRIERS.push(k);

const METRICS = {
  amp_atten: { label: "Amplitude attenuation", unit: "dB", vector: true, signed: true, floor: 1,
    desc: "Baseline amplitude minus current, per subcarrier. Shadowing by a body in the link." },
  rssi_atten: { label: "RSSI drop", unit: "dB", vector: false, signed: true, floor: 1,
    desc: "Wide-band received power vs baseline. Coarse, but no CSI needed." },
  amp_std: { label: "Amplitude variability", unit: "dB", vector: true, signed: false, floor: 0.5,
    desc: "Std. dev. of amplitude over the window, above its empty-room level. Rises with movement near the link." },
  phase_std: { label: "Phase variability", unit: "rad", vector: true, signed: false, floor: 0.02,
    desc: "Circular std. dev. of sanitized phase (CFO/STO removed), above its empty-room level. Sensitive to small motion." },
  motion: { label: "Motion energy", unit: "dB", vector: true, signed: false, floor: 0.3,
    desc: "Mean packet-to-packet amplitude change, above its empty-room level. Fast movement only." },
};
const HISTORY_LEN = 300; // 30 s at 10 Hz
const C = 299792458;

// Sequential blue ramp (light→dark on light surface, dark→light on dark).
const RAMP_LIGHT = ["#fcfcfb", "#cde2fb", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b"];
const RAMP_DARK = ["#1a1a19", "#104281", "#1c5cab", "#2a78d6", "#5598e7", "#b7d3f6"];

// ---------------------------------------------------------------- state
const store = {
  get(k, d) { try { const v = localStorage.getItem("csilite." + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem("csilite." + k, JSON.stringify(v)); } catch {} },
};
const S = {
  ws: null,
  status: null,
  cfg: null,
  history: [],       // frames, oldest first
  metric: store.get("metric", "amp_atten"),
  links: new Set(store.get("links", LINKS)),
  scLo: store.get("scLo", -26),
  scHi: store.get("scHi", 26),
  autoScale: store.get("autoScale", true),
  scaleMax: store.get("scaleMax", 6),
  dirty: true,
  drag: null,
};
if (!METRICS[S.metric]) S.metric = "amp_atten";

const $ = (id) => document.getElementById(id);
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const isDark = () => {
  const t = document.documentElement.dataset.theme;
  if (t) return t === "dark";
  return matchMedia("(prefers-color-scheme: dark)").matches;
};

// ---------------------------------------------------------------- websocket
function connect() {
  const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
  S.ws = ws;
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.type === "status") onStatus(m);
    else if (m.type === "frame") onFrame(m);
    else if (m.type === "error") showCfgMsg(m.message, true);
  };
  ws.onclose = () => {
    $("mode").textContent = "disconnected";
    setTimeout(connect, 1500);
  };
}
function send(obj) { if (S.ws && S.ws.readyState === 1) S.ws.send(JSON.stringify(obj)); }

function onStatus(m) {
  const cfgChanged = JSON.stringify(m.config) !== JSON.stringify(S.cfg);
  S.status = m;
  S.cfg = m.config;
  $("mode").textContent = m.simulate ? "simulated" : "live";
  for (const n of ["A", "B"]) {
    const node = m.nodes[n];
    const el = $("node" + n);
    el.className = "pill " + (node.online ? "on" : "off");
    el.innerHTML = `<span class="dot"></span>Node ${n} ${node.online ? (node.ip || "") : "offline"}`;
    el.title = node.mac || "";
  }
  $("btnStart").disabled = m.running;
  $("btnStop").disabled = !m.running;
  $("btnCalib").disabled = !m.running || m.calibrating;
  $("calibState").textContent = m.calibrating ? `calibrating… ${m.calib_remaining.toFixed(1)} s — keep the area clear` : "";
  if (cfgChanged) { fillConfig(); S.dirty = true; }
}

function onFrame(m) {
  S.history.push(m);
  if (S.history.length > HISTORY_LEN) S.history.shift();
  if (S.status) S.status.calibrating = m.calibrating;
  S.dirty = true;
}

// ---------------------------------------------------------------- config panel
const CFG_FIELDS = ["d_ra", "d_rb", "d_ab", "channel", "rate_hz", "window_s", "fresnel_m"];
function fillConfig() {
  for (const k of CFG_FIELDS) {
    const el = $(k);
    if (document.activeElement !== el) el.value = S.cfg[k];
  }
  updateGeomInfo();
}
function readConfig() {
  const c = {};
  for (const k of CFG_FIELDS) c[k] = parseFloat($(k).value);
  return c;
}
function showCfgMsg(text, err) {
  const el = $("cfgMsg");
  el.textContent = text;
  el.className = "small" + (err ? " err" : " muted");
}
function triangle(c) {
  const ax = c.d_ra;
  const bx = (c.d_ra ** 2 + c.d_rb ** 2 - c.d_ab ** 2) / (2 * c.d_ra);
  const by = Math.sqrt(Math.max(c.d_rb ** 2 - bx ** 2, 0));
  return { R: [0, 0], A: [ax, 0], B: [bx, by] };
}
function validTriangle(c) {
  const { d_ra: a, d_rb: b, d_ab: d } = c;
  return a > 0 && b > 0 && d > 0 && a + b > d && a + d > b && b + d > a;
}
function wavelength(ch) { return C / (ch === 14 ? 2.484e9 : 2.407e9 + 5e6 * ch); }
function updateGeomInfo() {
  const c = readConfig();
  const el = $("geomInfo");
  if (!validTriangle(c)) { el.textContent = "These distances can't form a triangle."; el.style.color = css("--critical"); return; }
  el.style.color = "";
  const lam = wavelength(c.channel);
  const f1 = (d) => (Math.sqrt(lam * d) / 2 * 100).toFixed(0);
  el.innerHTML = `λ = ${(lam * 100).toFixed(1)} cm · 1st Fresnel zone radius at mid-link: ` +
    `R→A ${f1(c.d_ra)} cm, R→B ${f1(c.d_rb)} cm, A↔B ${f1(c.d_ab)} cm`;
}

// ---------------------------------------------------------------- selection panel
function buildSelectors() {
  const ml = $("metrics");
  for (const [key, m] of Object.entries(METRICS)) {
    const lab = document.createElement("label");
    lab.innerHTML = `<input type="radio" name="metric" value="${key}"><span>${m.label} <em class="muted">(${m.unit})</em><span class="desc">${m.desc}</span></span>`;
    lab.querySelector("input").checked = key === S.metric;
    lab.querySelector("input").onchange = () => { S.metric = key; store.set("metric", key); onSelectionChange(); };
    ml.appendChild(lab);
  }
  const lt = $("linkToggles");
  for (const l of LINKS) {
    const lab = document.createElement("label");
    lab.innerHTML = `<input type="checkbox"><span class="swatch" style="background:var(--link-${l})"></span>${LINK_NAME[l]}`;
    const cb = lab.querySelector("input");
    cb.checked = S.links.has(l);
    cb.onchange = () => {
      cb.checked ? S.links.add(l) : S.links.delete(l);
      store.set("links", [...S.links]);
      S.dirty = true;
    };
    lt.appendChild(lab);
  }
  $("scLo").value = S.scLo; $("scHi").value = S.scHi;
  $("scLo").onchange = $("scHi").onchange = () => setScRange(+$("scLo").value, +$("scHi").value);
  $("scAll").onclick = () => setScRange(-26, 26);
  $("autoScale").checked = S.autoScale;
  $("autoScale").onchange = () => { S.autoScale = $("autoScale").checked; store.set("autoScale", S.autoScale); S.dirty = true; };
  $("scaleMax").value = S.scaleMax;
  $("scaleMax").onchange = () => {
    S.scaleMax = Math.max(0.01, +$("scaleMax").value || 1);
    S.autoScale = false; $("autoScale").checked = false;
    store.set("scaleMax", S.scaleMax); store.set("autoScale", false); S.dirty = true;
  };
  onSelectionChange();
}
function setScRange(a, b) {
  a = Math.max(-26, Math.min(26, Math.round(a || 0)));
  b = Math.max(-26, Math.min(26, Math.round(b || 0)));
  if (a > b) [a, b] = [b, a];
  S.scLo = a; S.scHi = b;
  $("scLo").value = a; $("scHi").value = b;
  store.set("scLo", a); store.set("scHi", b);
  S.dirty = true;
}
function onSelectionChange() {
  const m = METRICS[S.metric];
  $("metricLabel").textContent = `${m.label} (${m.unit})` + (m.vector ? "" : " · subcarrier selection n/a");
  $("scaleUnit").textContent = m.unit;
  S.dirty = true;
}

// ---------------------------------------------------------------- values
function linkValue(frame, link, metric = S.metric) {
  const d = frame && frame.links[link];
  if (!d) return null;
  const v = d[metric];
  if (!Array.isArray(v)) return v;
  let s = 0, n = 0;
  for (let i = 0; i < SUBCARRIERS.length; i++) {
    const k = SUBCARRIERS[i];
    if (k >= S.scLo && k <= S.scHi) { s += v[i]; n++; }
  }
  return n ? s / n : null;
}
function currentScale() {
  const m = METRICS[S.metric];
  if (!S.autoScale) return S.scaleMax;
  let mx = 0;
  for (const f of S.history.slice(-50)) {
    for (const l of S.links) {
      const v = linkValue(f, l);
      if (v != null) mx = Math.max(mx, Math.abs(v));
    }
  }
  return Math.max(mx * 1.1, m.floor);
}
const fmt = (v, unit) => v == null ? "–" : `${v.toFixed(Math.abs(v) < 1 ? 2 : 1)} ${unit}`;

// ---------------------------------------------------------------- canvas helpers
function fitCanvas(cv) {
  const r = cv.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const w = Math.round(r.width * dpr), h = Math.round(r.height * dpr);
  if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; }
  const ctx = cv.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx, w: r.width, h: r.height };
}
function hexToRgb(h) { const n = parseInt(h.slice(1), 16); return [n >> 16, (n >> 8) & 255, n & 255]; }
let rampCache = null;
function rampLUT() {
  const dark = isDark();
  if (rampCache && rampCache.dark === dark) return rampCache.lut;
  const stops = (dark ? RAMP_DARK : RAMP_LIGHT).map(hexToRgb);
  const lut = new Uint8ClampedArray(256 * 3);
  for (let i = 0; i < 256; i++) {
    const t = i / 255 * (stops.length - 1);
    const j = Math.min(Math.floor(t), stops.length - 2), f = t - j;
    for (let c = 0; c < 3; c++) lut[i * 3 + c] = stops[j][c] + (stops[j + 1][c] - stops[j][c]) * f;
  }
  rampCache = { dark, lut };
  return lut;
}
const tip = $("tip");
function showTip(e, html) {
  tip.innerHTML = html; tip.style.display = "block";
  const x = Math.min(e.clientX + 14, window.innerWidth - tip.offsetWidth - 8);
  tip.style.left = x + "px"; tip.style.top = (e.clientY + 14) + "px";
}
function hideTip() { tip.style.display = "none"; }

// ---------------------------------------------------------------- spatial map
const mapCv = $("map");
const off = document.createElement("canvas");
let mapView = null; // world<->screen transform for hover

function computeMapView(w, h, pts) {
  const xs = Object.values(pts).map((p) => p[0]), ys = Object.values(pts).map((p) => p[1]);
  const pad = 1.0;
  const x0 = Math.min(...xs) - pad, x1 = Math.max(...xs) + pad;
  const y0 = Math.min(...ys) - pad, y1 = Math.max(...ys) + pad;
  const s = Math.min(w / (x1 - x0), h / (y1 - y0));
  const ox = (w - (x1 - x0) * s) / 2, oy = (h - (y1 - y0) * s) / 2;
  return {
    s, toScreen: (p) => [ox + (p[0] - x0) * s, h - (oy + (p[1] - y0) * s)],
    toWorld: (x, y) => [x0 + (x - ox) / s, y0 + (h - y - oy) / s],
  };
}
function linkWeight(p, a, b, d, width) {
  const excess = Math.hypot(p[0] - a[0], p[1] - a[1]) + Math.hypot(p[0] - b[0], p[1] - b[1]) - d;
  return Math.exp(-0.5 * (excess / width) ** 2);
}
// Backprojection: each link spreads its value over an ellipse around its
// line of sight (foci = its two ends). Overlapping links add up.
function intensityAt(p, pts, values, width) {
  let s = 0;
  for (const l of LINKS) {
    const v = values[l];
    if (v == null || !S.links.has(l)) continue;
    const [a, b] = LINK_ENDS[l].map((n) => pts[n]);
    s += linkWeight(p, a, b, Math.hypot(a[0] - b[0], a[1] - b[1]), width) * Math.max(0, v);
  }
  return s;
}
function drawMap() {
  const { ctx, w, h } = fitCanvas(mapCv);
  ctx.fillStyle = css("--surface"); ctx.fillRect(0, 0, w, h);
  if (!S.cfg || !validTriangle(S.cfg)) return;
  const pts = triangle(S.cfg);
  const view = mapView = computeMapView(w, h, pts);
  const frame = S.history[S.history.length - 1];
  const values = {};
  for (const l of LINKS) values[l] = linkValue(frame, l);
  const scale = currentScale();
  const width = S.cfg.fresnel_m;

  // heatmap at low resolution, then smoothed up
  const cell = 4, gw = Math.ceil(w / cell), gh = Math.ceil(h / cell);
  off.width = gw; off.height = gh;
  const octx = off.getContext("2d");
  const img = octx.createImageData(gw, gh);
  const lut = rampLUT();
  for (let j = 0; j < gh; j++) {
    for (let i = 0; i < gw; i++) {
      const p = view.toWorld((i + 0.5) * cell, (j + 0.5) * cell);
      const t = Math.min(1, intensityAt(p, pts, values, width) / scale);
      const li = Math.round(t * 255) * 3, o = (j * gw + i) * 4;
      img.data[o] = lut[li]; img.data[o + 1] = lut[li + 1]; img.data[o + 2] = lut[li + 2]; img.data[o + 3] = 255;
    }
  }
  octx.putImageData(img, 0, 0);
  ctx.imageSmoothingEnabled = true;
  ctx.drawImage(off, 0, 0, gw * cell, gh * cell);

  // 1 m grid
  ctx.strokeStyle = css("--grid"); ctx.lineWidth = 1; ctx.globalAlpha = 0.5;
  const [wx0, wy0] = view.toWorld(0, h), [wx1, wy1] = view.toWorld(w, 0);
  for (let x = Math.ceil(wx0); x <= wx1; x++) { const [sx] = view.toScreen([x, 0]); ctx.beginPath(); ctx.moveTo(sx, 0); ctx.lineTo(sx, h); ctx.stroke(); }
  for (let y = Math.ceil(wy0); y <= wy1; y++) { const [, sy] = view.toScreen([0, y]); ctx.beginPath(); ctx.moveTo(0, sy); ctx.lineTo(w, sy); ctx.stroke(); }
  ctx.globalAlpha = 1;

  // links: line of sight + ellipse outline at 1 width of excess path
  for (const l of LINKS) {
    const on = S.links.has(l);
    const [a, b] = LINK_ENDS[l].map((n) => pts[n]);
    const d = Math.hypot(a[0] - b[0], a[1] - b[1]);
    const col = css("--link-" + l);
    ctx.globalAlpha = on ? 1 : 0.25;
    ctx.strokeStyle = col; ctx.lineWidth = 2;
    const sa = view.toScreen(a), sb = view.toScreen(b);
    ctx.beginPath(); ctx.moveTo(...sa); ctx.lineTo(...sb); ctx.stroke();
    const A = (d + width) / 2, B = Math.sqrt(Math.max(A * A - (d / 2) ** 2, 0));
    const mid = view.toScreen([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]);
    const ang = -Math.atan2(b[1] - a[1], b[0] - a[0]);
    ctx.setLineDash([4, 4]); ctx.lineWidth = 1;
    ctx.beginPath(); ctx.ellipse(mid[0], mid[1], A * view.s, B * view.s, ang, 0, 2 * Math.PI); ctx.stroke();
    ctx.setLineDash([]);
    // distance label
    ctx.fillStyle = css("--ink-2"); ctx.font = "11px system-ui, sans-serif"; ctx.textAlign = "center";
    ctx.fillText(`${d.toFixed(2)} m`, mid[0], mid[1] - 6);
    ctx.globalAlpha = 1;
  }

  // devices
  const labels = { R: "Router", A: "Node A", B: "Node B" };
  for (const [n, p] of Object.entries(pts)) {
    const [x, y] = view.toScreen(p);
    ctx.fillStyle = css("--ink"); ctx.strokeStyle = css("--surface"); ctx.lineWidth = 2;
    ctx.beginPath();
    if (n === "R") ctx.rect(x - 6, y - 6, 12, 12); else ctx.arc(x, y, 6, 0, 2 * Math.PI);
    ctx.fill(); ctx.stroke();
    ctx.font = "600 12px system-ui, sans-serif"; ctx.textAlign = "left";
    ctx.fillText(labels[n], x + 10, y + 4);
  }

  // scale bar
  const [bx0] = view.toScreen([0, 0]), [bx1] = view.toScreen([1, 0]);
  ctx.strokeStyle = css("--ink-2"); ctx.lineWidth = 2;
  ctx.beginPath(); ctx.moveTo(12, h - 14); ctx.lineTo(12 + (bx1 - bx0), h - 14); ctx.stroke();
  ctx.fillStyle = css("--ink-2"); ctx.font = "11px system-ui, sans-serif"; ctx.textAlign = "left";
  ctx.fillText("1 m", 12, h - 20);

  drawLegend(scale);
  drawReadouts(frame);
}
mapCv.addEventListener("mousemove", (e) => {
  if (!mapView || !S.cfg) return;
  const r = mapCv.getBoundingClientRect();
  const p = mapView.toWorld(e.clientX - r.left, e.clientY - r.top);
  const frame = S.history[S.history.length - 1];
  const values = {};
  for (const l of LINKS) values[l] = linkValue(frame, l);
  const v = intensityAt(p, triangle(S.cfg), values, S.cfg.fresnel_m);
  showTip(e, `x ${p[0].toFixed(2)} m, y ${p[1].toFixed(2)} m<br><b>${fmt(v, METRICS[S.metric].unit)}</b>`);
});
mapCv.addEventListener("mouseleave", hideTip);

function drawLegend(scale) {
  const m = METRICS[S.metric];
  const stops = (isDark() ? RAMP_DARK : RAMP_LIGHT).join(",");
  $("legend").innerHTML =
    `<span>0</span><span class="ramp" style="background:linear-gradient(90deg,${stops})"></span>` +
    `<span>${fmt(scale, m.unit)}${S.autoScale ? " (auto)" : ""}</span>` +
    `<span class="key">dashed = ellipse of ±${(S.cfg.fresnel_m * 100).toFixed(0)} cm excess path</span>`;
}
function drawReadouts(frame) {
  const m = METRICS[S.metric];
  $("readouts").innerHTML = LINKS.map((l) => {
    const d = frame && frame.links[l];
    const v = linkValue(frame, l);
    const base = d ? (d.calibrated ? "calibrated baseline" : "running baseline") : "no data";
    return `<div class="readout" style="opacity:${S.links.has(l) ? 1 : 0.45}">
      <div class="name"><span class="swatch" style="background:var(--link-${l})"></span>${LINK_NAME[l]}</div>
      <div class="val">${fmt(v, m.unit)}</div>
      <div class="sub">${d ? `${d.rate.toFixed(0)} pkt/s · RSSI ${d.rssi.toFixed(0)} dBm` : "–"}<br>${base}</div>
    </div>`;
  }).join("");
}

// ---------------------------------------------------------------- shared axis drawing
function yAxis(ctx, x, top, bottom, lo, hi, unit, w) {
  ctx.font = "11px system-ui, sans-serif"; ctx.textAlign = "right"; ctx.fillStyle = css("--muted");
  const ticks = lo < 0 ? [lo, 0, hi] : [0, hi / 2, hi];
  for (const t of ticks) {
    const y = bottom - (t - lo) / (hi - lo) * (bottom - top);
    ctx.strokeStyle = t === 0 ? css("--axis") : css("--grid"); ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(x, y + 0.5); ctx.lineTo(w, y + 0.5); ctx.stroke();
    ctx.fillText(`${t.toFixed(Math.abs(hi) < 1 ? 2 : 1)}`, x - 4, y + 4);
  }
  ctx.save(); ctx.translate(10, (top + bottom) / 2); ctx.rotate(-Math.PI / 2);
  ctx.textAlign = "center"; ctx.fillText(unit, 0, 0); ctx.restore();
}
function bar(ctx, x, y0, y1, bw, color) {
  // rounded end on the data side, flat on the baseline
  const top = Math.min(y0, y1), hgt = Math.abs(y1 - y0);
  if (hgt < 0.5) return;
  const r = Math.min(4, bw / 2, hgt);
  ctx.fillStyle = color;
  ctx.beginPath();
  if (y1 <= y0) ctx.roundRect(x, top, bw, hgt, [r, r, 0, 0]);
  else ctx.roundRect(x, top, bw, hgt, [0, 0, r, r]);
  ctx.fill();
}

// ---------------------------------------------------------------- per-subcarrier bars
const scCv = $("sc");
let scLayout = null;
function drawSubcarriers() {
  const { ctx, w, h } = fitCanvas(scCv);
  ctx.fillStyle = css("--surface"); ctx.fillRect(0, 0, w, h);
  const m = METRICS[S.metric];
  const frame = S.history[S.history.length - 1];
  const L = 44, R = w - 8, T = 10, B = h - 22;
  scLayout = { L, R, step: (R - L) / SUBCARRIERS.length };
  if (!m.vector) {
    ctx.fillStyle = css("--muted"); ctx.font = "13px system-ui, sans-serif"; ctx.textAlign = "center";
    ctx.fillText(`${m.label} is one number per packet — there is no per-subcarrier breakdown.`, w / 2, h / 2);
    return;
  }
  const links = LINKS.filter((l) => S.links.has(l));
  let mx = m.floor, mn = 0;
  for (const l of links) {
    const v = frame && frame.links[l] && frame.links[l][S.metric];
    if (v) for (const x of v) { mx = Math.max(mx, x); mn = Math.min(mn, x); }
  }
  if (m.signed) { const a = Math.max(mx, -mn); mx = a; mn = mn < 0 ? -a : 0; }
  const step = scLayout.step;
  const y = (v) => B - (v - mn) / (mx - mn) * (B - T);

  // selection band
  const i0 = SUBCARRIERS.indexOf(S.scLo === 0 ? 1 : S.scLo), i1 = SUBCARRIERS.indexOf(S.scHi === 0 ? -1 : S.scHi);
  ctx.fillStyle = css("--select");
  ctx.fillRect(L + i0 * step, T, (i1 - i0 + 1) * step, B - T);

  yAxis(ctx, L, T, B, mn, mx, m.unit, R);

  const gap = 2;
  const bw = Math.max(1, (step - gap) / Math.max(links.length, 1) - (links.length > 1 ? 1 : 0));
  SUBCARRIERS.forEach((k, i) => {
    const sel = k >= S.scLo && k <= S.scHi;
    links.forEach((l, j) => {
      const v = frame && frame.links[l] && frame.links[l][S.metric];
      if (!v) return;
      ctx.globalAlpha = sel ? 1 : 0.3;
      bar(ctx, L + i * step + gap / 2 + j * (bw + 1), y(0), y(v[i]), bw, css("--link-" + l));
    });
  });
  ctx.globalAlpha = 1;
  ctx.fillStyle = css("--muted"); ctx.font = "11px system-ui, sans-serif"; ctx.textAlign = "center";
  for (const k of [-26, -13, 13, 26]) {
    const i = SUBCARRIERS.indexOf(k);
    ctx.fillText(k, L + (i + 0.5) * step, h - 6);
  }
  ctx.fillText("subcarrier (DC at centre)", (L + R) / 2, h - 6);
}
function scIndexAt(e) {
  const r = scCv.getBoundingClientRect();
  const i = Math.floor((e.clientX - r.left - scLayout.L) / scLayout.step);
  return Math.max(0, Math.min(SUBCARRIERS.length - 1, i));
}
scCv.addEventListener("mousedown", (e) => {
  if (!scLayout || !METRICS[S.metric].vector) return;
  S.drag = scIndexAt(e);
  setScRange(SUBCARRIERS[S.drag], SUBCARRIERS[S.drag]);
});
window.addEventListener("mouseup", () => { S.drag = null; });
scCv.addEventListener("mousemove", (e) => {
  if (!scLayout || !METRICS[S.metric].vector) return;
  const i = scIndexAt(e);
  if (S.drag != null) setScRange(SUBCARRIERS[S.drag], SUBCARRIERS[i]);
  const frame = S.history[S.history.length - 1];
  const m = METRICS[S.metric];
  const rows = LINKS.filter((l) => S.links.has(l) && frame && frame.links[l]).map((l) =>
    `<span class="swatch" style="background:var(--link-${l})"></span> ${LINK_NAME[l]}: <b>${fmt(frame.links[l][S.metric][i], m.unit)}</b>`);
  showTip(e, `Subcarrier ${SUBCARRIERS[i]}<br>${rows.join("<br>")}`);
});
scCv.addEventListener("mouseleave", hideTip);

// ---------------------------------------------------------------- history (scrolling bars)
const histCv = $("hist");
let histLayout = null;
function drawHistory() {
  const { ctx, w, h } = fitCanvas(histCv);
  ctx.fillStyle = css("--surface"); ctx.fillRect(0, 0, w, h);
  const m = METRICS[S.metric];
  const links = LINKS.filter((l) => S.links.has(l));
  const L = 44, R = w - 8, T = 6, B = h - 20;
  const n = HISTORY_LEN, step = (R - L) / n;
  histLayout = { L, R, step, links };
  if (!links.length) return;

  let mx = m.floor, mn = 0;
  for (const f of S.history) for (const l of links) {
    const v = linkValue(f, l);
    if (v != null) { mx = Math.max(mx, v); mn = Math.min(mn, v); }
  }
  if (mn < 0) { const a = Math.max(mx, -mn); mx = a; mn = -a; }
  // one lane per link (small multiples), shared y scale
  const laneH = (B - T) / links.length;
  const start = n - S.history.length;

  // calibration periods
  ctx.fillStyle = css("--select");
  S.history.forEach((f, i) => { if (f.calibrating) ctx.fillRect(L + (start + i) * step, T, step + 0.5, B - T); });

  links.forEach((l, j) => {
    const top = T + j * laneH + 4, bot = T + (j + 1) * laneH - 4;
    const y = (v) => bot - (v - mn) / (mx - mn) * (bot - top);
    ctx.strokeStyle = css("--axis"); ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(L, y(0) + 0.5); ctx.lineTo(R, y(0) + 0.5); ctx.stroke();
    ctx.fillStyle = css("--muted"); ctx.font = "11px system-ui, sans-serif"; ctx.textAlign = "right";
    ctx.fillText(mx.toFixed(mx < 1 ? 2 : 1), L - 4, top + 8);
    ctx.fillText("0", L - 4, y(0) + 4);
    ctx.textAlign = "left"; ctx.fillStyle = css("--ink-2");
    ctx.fillText(LINK_NAME[l], L + 4, top + 10);
    const col = css("--link-" + l);
    const bw = Math.max(1, step - (step > 3 ? 1 : 0));
    S.history.forEach((f, i) => {
      const v = linkValue(f, l);
      if (v == null) return;
      bar(ctx, L + (start + i) * step, y(0), y(v), bw, col);
    });
  });
  ctx.fillStyle = css("--muted"); ctx.textAlign = "center"; ctx.font = "11px system-ui, sans-serif";
  for (let s = 30; s >= 0; s -= 5) ctx.fillText(s ? `-${s}s` : "now", L + (n - s * 10) * step - (s ? 0 : 12), h - 5);
  ctx.save(); ctx.translate(10, (T + B) / 2); ctx.rotate(-Math.PI / 2);
  ctx.textAlign = "center"; ctx.fillText(m.unit, 0, 0); ctx.restore();

  if (histLayout.hover != null) {
    const x = L + (histLayout.hover + 0.5) * step;
    ctx.strokeStyle = css("--ink-2"); ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(x, T); ctx.lineTo(x, B); ctx.stroke();
  }
}
histCv.addEventListener("mousemove", (e) => {
  if (!histLayout) return;
  const r = histCv.getBoundingClientRect();
  const slot = Math.floor((e.clientX - r.left - histLayout.L) / histLayout.step);
  const idx = slot - (HISTORY_LEN - S.history.length);
  const f = S.history[idx];
  if (!f) { histLayout.hover = null; hideTip(); S.dirty = true; return; }
  histLayout.hover = slot; S.dirty = true;
  const m = METRICS[S.metric];
  const ago = (S.history[S.history.length - 1].t - f.t).toFixed(1);
  const rows = histLayout.links.map((l) =>
    `<span class="swatch" style="background:var(--link-${l})"></span> ${LINK_NAME[l]}: <b>${fmt(linkValue(f, l), m.unit)}</b>`);
  showTip(e, `${ago} s ago${f.calibrating ? " · calibrating" : ""}<br>${rows.join("<br>")}`);
});
histCv.addEventListener("mouseleave", () => { if (histLayout) histLayout.hover = null; hideTip(); S.dirty = true; });

// ---------------------------------------------------------------- wiring
function loop() {
  if (S.dirty) {
    S.dirty = false;
    drawMap(); drawSubcarriers(); drawHistory();
  }
  requestAnimationFrame(loop);
}
$("btnStart").onclick = () => { S.history = []; send({ cmd: "start" }); };
$("btnStop").onclick = () => send({ cmd: "stop" });
$("btnCalib").onclick = () => send({ cmd: "calibrate" });
$("btnApply").onclick = () => {
  const c = readConfig();
  if (!validTriangle(c)) { showCfgMsg("Those distances can't form a triangle.", true); return; }
  send({ cmd: "config", config: c });
  showCfgMsg("Applied. If geometry changed, baselines were reset — re-calibrate.", false);
};
for (const k of ["d_ra", "d_rb", "d_ab", "channel"]) $(k).addEventListener("input", updateGeomInfo);
window.addEventListener("resize", () => { S.dirty = true; });
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { S.dirty = true; });

buildSelectors();
connect();
requestAnimationFrame(loop);
