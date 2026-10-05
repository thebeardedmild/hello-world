"use strict";

// ---------------------------------------------------------------- constants
const NODE_LETTERS = "ABCDEFGHIJKLMNOP";
const SUBCARRIERS = [];
for (let k = -26; k <= 26; k++) if (k !== 0) SUBCARRIERS.push(k);

const METRICS = {
  amp_atten: { label: "Amplitude attenuation", unit: "dB", vector: true, signed: true, floor: 1, detect: 2,
    desc: "Baseline amplitude minus current, per subcarrier. Shadowing by a body in the link." },
  rssi_atten: { label: "RSSI drop", unit: "dB", vector: false, signed: true, floor: 1, detect: 2,
    desc: "Wide-band received power vs baseline. Coarse, but no CSI needed." },
  amp_std: { label: "Amplitude variability", unit: "dB", vector: true, signed: false, floor: 0.5, detect: 2.5,
    desc: "Std. dev. of amplitude over the window, above its empty-room level. Movement near the link." },
  phase_std: { label: "Phase variability", unit: "rad", vector: true, signed: false, floor: 0.02, detect: 0.08,
    desc: "Circular std. dev. of sanitized phase (CFO/STO removed), above its empty-room level. Small motion. Needs real multipath; nearly flat in the simulator." },
  motion: { label: "Motion energy", unit: "dB", vector: true, signed: false, floor: 0.3, detect: 1.0,
    desc: "Mean packet-to-packet amplitude change, above its empty-room level. Fast movement only." },
};
const HISTORY_LEN = 300;  // 30 s at 10 Hz
const TRAIL_LEN = 100;    // 10 s of disturbance positions
const GRID_CELLS = 2400;  // reconstruction pixels
const C = 299792458;

// Sequential blue (magnitude) and blue<->red diverging (signed) ramps.
const SEQ = { light: ["#fcfcfb", "#cde2fb", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b"],
              dark: ["#1a1a19", "#104281", "#1c5cab", "#2a78d6", "#5598e7", "#b7d3f6"] };
const DIV = { light: ["#b8302f", "#e34948", "#f0efec", "#3987e5", "#1c5cab"],
              dark: ["#e66767", "#9c3434", "#383835", "#2a78d6", "#86b6ef"] };

// ---------------------------------------------------------------- state
const store = {
  get(k, d) { try { const v = localStorage.getItem("csilite." + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem("csilite." + k, JSON.stringify(v)); } catch {} },
};
const S = {
  ws: null,
  status: null,
  cfg: null,
  draft: null,            // editable copy of cfg.devices
  draftDirty: false,
  history: [],
  metric: store.get("metric", "amp_atten"),
  showRouter: store.get("showRouter", true),
  showPeer: store.get("showPeer", true),
  linkOff: new Set(store.get("linkOff", [])),
  hlLink: null,
  scLo: store.get("scLo", -26),
  scHi: store.get("scHi", 26),
  autoScale: store.get("autoScale", true),
  scaleMax: store.get("scaleMax", 6),
  imgMode: store.get("imgMode", "tomo"),
  reg: store.get("reg", 0.3),
  thresh: store.get("thresh", {}),
  refAnt: store.get("refAnt", "R"),
  histMode: store.get("histMode", null), // null = auto
  editLayout: false,
  model: null,
  dirty: true,
};
if (!METRICS[S.metric]) S.metric = "amp_atten";

const $ = (id) => document.getElementById(id);
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const isDark = () => {
  const t = document.documentElement.dataset.theme;
  return t ? t === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
};
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const devName = (n) => n === "R" ? "Router" : `Node ${n}`;
const linkEnds = (l) => l.split("-");
const linkLabel = (l) => { const [a, b] = linkEnds(l); return a === "R" ? `Router → ${b}` : `${a} ↔ ${b}`; };
const dist = (p, q) => Math.hypot(p[0] - q[0], p[1] - q[1]);
const threshold = () => S.thresh[S.metric] ?? METRICS[S.metric].detect;
const fmt = (v, unit, digits) => v == null || !isFinite(v) ? "–"
  : `${v.toFixed(digits ?? (Math.abs(v) < 1 ? 2 : 1))}${unit ? " " + unit : ""}`;

// ---------------------------------------------------------------- websocket
function connect() {
  const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
  S.ws = ws;
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.type === "status") onStatus(m);
    else if (m.type === "frame") onFrame(m);
    else if (m.type === "error") showMsg("cfgMsg", m.message, true);
  };
  ws.onclose = () => { $("mode").textContent = "disconnected"; setTimeout(connect, 1500); };
}
function send(obj) { if (S.ws && S.ws.readyState === 1) S.ws.send(JSON.stringify(obj)); }

function onStatus(m) {
  const cfgChanged = JSON.stringify(m.config) !== JSON.stringify(S.cfg);
  S.status = m;
  S.cfg = m.config;
  $("mode").textContent = m.simulate ? "simulated" : "live";
  $("nodePills").innerHTML = Object.entries(m.nodes).map(([n, node]) => {
    const cls = !node.placed ? "unplaced" : node.online ? "on" : "off";
    const txt = !node.placed ? "not placed" : node.online ? (node.ip || "") : "offline";
    return `<span class="pill ${cls}" title="${esc(node.mac || "")}"><span class="dot"></span>${n} ${esc(txt)}</span>`;
  }).join("");
  $("btnStart").disabled = m.running;
  $("btnStop").disabled = !m.running;
  $("btnCalib").disabled = !m.running || m.calibrating;
  $("calibState").textContent = m.calibrating ? `calibrating… ${m.calib_remaining.toFixed(1)} s, keep the area clear` : "";
  if (cfgChanged) {
    if (!S.draftDirty) S.draft = structuredClone(m.config.devices);
    fillConfig();
  }
  renderDevices();
  updateRateHint();
  S.dirty = true;
}

function onFrame(m) {
  S.history.push(m);
  if (S.history.length > HISTORY_LEN) S.history.shift();
  if (S.status) S.status.calibrating = m.calibrating;
  S.dirty = true;
}

// ---------------------------------------------------------------- config panel
const CFG_FIELDS = ["channel", "rate_hz", "window_s", "fresnel_m"];
function fillConfig() {
  for (const k of CFG_FIELDS) if (document.activeElement !== $(k)) $(k).value = S.cfg[k];
  updateGeomInfo();
}
function showMsg(id, text, err) { const el = $(id); el.textContent = text; el.className = "small" + (err ? " err" : " muted"); }
function markDraftDirty() {
  S.draftDirty = true;
  S.dirty = true;
  showMsg("cfgMsg", "Unsaved antenna changes. Click Apply.", false);
  updateGeomInfo(); updateRateHint();
}
function nodesIn(devs) { return Object.keys(devs).filter((n) => n !== "R").sort(); }

function renderDevices() {
  if (!S.draft) return;
  const tb = $("devTable").tBodies[0];
  const nodes = S.status ? S.status.nodes : {};
  const names = ["R", ...nodesIn(S.draft)];
  // don't rebuild under the user's cursor; a status update arrives every second
  if (!tb.contains(document.activeElement)) tb.innerHTML = names.map((n) => {
    const st = n === "R" ? null : nodes[n];
    const dot = n === "R" ? "" : `<span class="dot ${st && st.online ? "on" : "off"}" title="${st && st.online ? "online " + esc(st.ip || "") : "offline"}"></span>`;
    const p = S.draft[n];
    return `<tr><td><span class="name">${dot}${devName(n)}</span></td>
      <td><input type="number" step="0.05" data-key="${n}.0" value="${p[0]}"></td>
      <td><input type="number" step="0.05" data-key="${n}.1" value="${p[1]}"></td>
      <td>${n === "R" ? "" : `<button class="icon-btn" data-remove="${n}" title="Remove ${devName(n)}">×</button>`}</td></tr>`;
  }).join("");

  const unplaced = Object.entries(nodes).filter(([n, s]) => s.online && !(n in S.draft)).map(([n]) => n);
  $("unplaced").innerHTML = unplaced.map((n) =>
    `<button class="small-btn" data-add="${n}">Place online node ${n}</button>`).join(" ");

  // place-by-distance selectors
  const opts = (list, sel) => list.map((n) => `<option value="${n}" ${n === sel ? "selected" : ""}>${devName(n)}</option>`).join("");
  const keep = (id, list, d) => { const v = $(id).value; $(id).innerHTML = opts(list, list.includes(v) ? v : d); };
  const ns = nodesIn(S.draft);
  keep("plNode", ns, ns[ns.length - 1]);
  keep("plRef1", names, "R");
  keep("plRef2", names, names.find((n) => n !== "R" && n !== $("plNode").value) || "R");
  keep("refAnt", names, names.includes(S.refAnt) ? S.refAnt : "R");
  S.refAnt = $("refAnt").value;
}
$("devTable").addEventListener("change", (e) => {
  const key = e.target.dataset.key;
  if (!key) return;
  const [n, i] = key.split(".");
  const v = parseFloat(e.target.value);
  if (isFinite(v)) { S.draft[n][+i] = v; markDraftDirty(); }
});
$("devTable").addEventListener("click", (e) => {
  const n = e.target.dataset.remove;
  if (!n) return;
  if (nodesIn(S.draft).length <= 1) { showMsg("cfgMsg", "Keep at least one node.", true); return; }
  delete S.draft[n];
  markDraftDirty(); renderDevices();
});
function freeSpot() {
  const pts = Object.values(S.draft);
  const cx = pts.reduce((s, p) => s + p[0], 0) / pts.length, cy = pts.reduce((s, p) => s + p[1], 0) / pts.length;
  for (let r = 1; r < 10; r += 0.5) for (let a = 0; a < 12; a++) {
    const p = [cx + r * Math.cos(a * Math.PI / 6), cy + r * Math.sin(a * Math.PI / 6)].map((v) => Math.round(v * 20) / 20);
    if (pts.every((q) => dist(p, q) > 0.8)) return p;
  }
  return [cx + 1, cy + 1];
}
function addNode(n) {
  n = n || [...NODE_LETTERS].find((c) => !(c in S.draft));
  if (!n) { showMsg("cfgMsg", "All 16 node IDs are in use.", true); return; }
  S.draft[n] = freeSpot();
  markDraftDirty(); renderDevices();
  showMsg("cfgMsg", `Added ${devName(n)}. Flash a board with Node ID ${NODE_LETTERS.indexOf(n)}, set its position, then Apply.`, false);
}
$("btnAddNode").onclick = () => addNode();
$("unplaced").addEventListener("click", (e) => { if (e.target.dataset.add) addNode(e.target.dataset.add); });

$("btnPlace").onclick = () => {
  const n = $("plNode").value, r1 = $("plRef1").value, r2 = $("plRef2").value;
  const d1 = +$("plD1").value, d2 = +$("plD2").value, side = +$("plSide").value;
  if (!n || n === r1 || n === r2 || r1 === r2) { showMsg("placeMsg", "Pick a node and two different reference antennas.", true); return; }
  const p1 = S.draft[r1], p2 = S.draft[r2], d = dist(p1, p2);
  const a = (d1 * d1 - d2 * d2 + d * d) / (2 * d), h2 = d1 * d1 - a * a;
  if (!(d > 0) || h2 < -1e-6) { showMsg("placeMsg", `Those distances don't meet: ${devName(r1)} and ${devName(r2)} are ${d.toFixed(2)} m apart.`, true); return; }
  const h = Math.sqrt(Math.max(h2, 0)), ux = (p2[0] - p1[0]) / d, uy = (p2[1] - p1[1]) / d;
  S.draft[n] = [p1[0] + a * ux - side * h * uy, p1[1] + a * uy + side * h * ux].map((v) => Math.round(v * 1000) / 1000);
  markDraftDirty(); renderDevices();
  showMsg("placeMsg", `${devName(n)} placed at (${S.draft[n][0].toFixed(2)}, ${S.draft[n][1].toFixed(2)}).`, false);
};

function wavelength(ch) { return C / (ch === 14 ? 2.484e9 : 2.407e9 + 5e6 * ch); }
function updateGeomInfo() {
  if (!S.draft) return;
  const lam = wavelength(+$("channel").value || 6);
  const links = allLinks();
  const longest = Math.max(...links.map((l) => linkLength(l)));
  $("geomInfo").innerHTML = `${nodesIn(S.draft).length} nodes, ${links.length} links · λ = ${(lam * 100).toFixed(1)} cm · ` +
    `1st Fresnel zone radius at the middle of the longest link (${longest.toFixed(2)} m): ${(Math.sqrt(lam * longest) / 2 * 100).toFixed(0)} cm`;
}
function updateRateHint() {
  if (!S.draft) return;
  const n = nodesIn(S.draft).length, rate = +$("rate_hz").value || 0;
  const total = n * n * rate;
  let txt = `≈ ${Math.round(total)} CSI packets/s in total (each node hears the router and ${n - 1} other node${n === 2 ? "" : "s"}).`;
  if (total > 3000) txt += " That's heavy for a small server. Consider a lower rate.";
  if (S.status && S.status.simulate && S.status.sim_rate != null && S.status.sim_rate < rate) txt += ` The simulator runs at ${S.status.sim_rate} Hz to save CPU.`;
  $("rateHint").textContent = txt;
}

// ---------------------------------------------------------------- links & values
function allLinks() {
  const ns = nodesIn(S.draft || {});
  const out = ns.map((n) => `R-${n}`);
  for (let i = 0; i < ns.length; i++) for (let j = i + 1; j < ns.length; j++) out.push(`${ns[i]}-${ns[j]}`);
  return out;
}
function linkShown(l) { return l.startsWith("R-") ? S.showRouter : S.showPeer; }
function enabledLinks() { return allLinks().filter((l) => linkShown(l) && !S.linkOff.has(l)); }
function linkLength(l) { const [a, b] = linkEnds(l); return dist(S.draft[a], S.draft[b]); }
const selKey = () => `${S.metric}|${S.scLo}|${S.scHi}`;

function linkValue(frame, link) {
  const d = frame && frame.links[link];
  if (!d) return null;
  const v = d[S.metric];
  if (!Array.isArray(v)) return v;
  let s = 0, n = 0;
  for (let i = 0; i < SUBCARRIERS.length; i++) {
    const k = SUBCARRIERS[i];
    if (k >= S.scLo && k <= S.scHi) { s += v[i]; n++; }
  }
  return n ? s / n : null;
}
function frameValues(frame) {
  const key = selKey();
  if (!frame._v || frame._v.key !== key) {
    const vals = {};
    for (const l of Object.keys(frame.links)) vals[l] = linkValue(frame, l);
    frame._v = { key, vals };
  }
  return frame._v.vals;
}
function currentScale() {
  const m = METRICS[S.metric];
  if (!S.autoScale) return S.scaleMax;
  let mx = 0;
  const links = enabledLinks();
  for (const f of S.history.slice(-50)) {
    const vals = frameValues(f);
    for (const l of links) if (vals[l] != null) mx = Math.max(mx, Math.abs(vals[l]));
  }
  return Math.max(mx * 1.1, m.floor);
}

// ---------------------------------------------------------------- reconstruction model
const END_TAPER_M = 0.4;
// How much point (x,y) sits inside link a-b's zone: Gaussian in excess path,
// faded out near the two antennas. Every link touching an antenna overlaps
// there, which would otherwise pull every estimate onto the antennas.
function zoneWeight(x, y, a, b, d, width) {
  const ra = Math.hypot(x - a[0], y - a[1]), rb = Math.hypot(x - b[0], y - b[1]);
  const ex = ra + rb - d, r = Math.min(ra, rb);
  return Math.exp(-0.5 * (ex / width) ** 2) * (1 - Math.exp(-0.5 * (r / END_TAPER_M) ** 2));
}
// W[l, p]: how much pixel p sits inside link l's zone (see zoneWeight).
// Backprojection: img = Wᵀ y. Tomographic: img = Wᵀ (W Wᵀ + αI)⁻¹ y, the
// minimum-norm regularized solution, so overlapping links aren't counted twice.
// Both are scaled so one link reading v alone peaks at about v.
function invert(A, n) {
  const M = A.map((row, i) => [...row, ...Array.from({ length: n }, (_, j) => (i === j ? 1 : 0))]);
  for (let c = 0; c < n; c++) {
    let piv = c;
    for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[piv][c])) piv = r;
    [M[c], M[piv]] = [M[piv], M[c]];
    const d = M[c][c] || 1e-12;
    for (let j = 0; j < 2 * n; j++) M[c][j] /= d;
    for (let r = 0; r < n; r++) if (r !== c) {
      const f = M[r][c];
      if (f) for (let j = 0; j < 2 * n; j++) M[r][j] -= f * M[c][j];
    }
  }
  return M.map((row) => row.slice(n));
}
function getModel() {
  if (!S.draft || !S.cfg) return null;
  const links = enabledLinks();
  const width = +$("fresnel_m").value || S.cfg.fresnel_m;
  const key = JSON.stringify([S.draft, links, width, S.imgMode, S.reg]);
  if (S.model && S.model.key === key) return S.model;

  const pts = S.draft;
  const xs = Object.values(pts).map((p) => p[0]), ys = Object.values(pts).map((p) => p[1]);
  const x0 = Math.min(...xs) - 1, x1 = Math.max(...xs) + 1, y0 = Math.min(...ys) - 1, y1 = Math.max(...ys) + 1;
  const cell = Math.max(0.05, Math.sqrt((x1 - x0) * (y1 - y0) / GRID_CELLS));
  const nx = Math.ceil((x1 - x0) / cell), ny = Math.ceil((y1 - y0) / cell), P = nx * ny, L = links.length;
  const px = new Float32Array(P), py = new Float32Array(P);
  for (let j = 0; j < ny; j++) for (let i = 0; i < nx; i++) {
    px[j * nx + i] = x0 + (i + 0.5) * cell;
    py[j * nx + i] = y1 - (j + 0.5) * cell; // row 0 = top
  }
  const W = new Float32Array(L * P);
  links.forEach((l, k) => {
    const [a, b] = linkEnds(l).map((n) => pts[n]);
    const d = dist(a, b);
    for (let p = 0; p < P; p++) W[k * P + p] = zoneWeight(px[p], py[p], a, b, d, width);
  });
  let M = null, norm = 1;
  if (S.imgMode === "tomo" && L) {
    const G = Array.from({ length: L }, () => new Array(L).fill(0));
    for (let a = 0; a < L; a++) for (let b = a; b < L; b++) {
      let s = 0;
      for (let p = 0; p < P; p++) s += W[a * P + p] * W[b * P + p];
      G[a][b] = G[b][a] = s;
    }
    let tr = 0;
    for (let a = 0; a < L; a++) tr += G[a][a];
    const alpha = S.reg * tr / L;
    for (let a = 0; a < L; a++) G[a][a] += alpha;
    const Gi = invert(G, L);
    M = new Float32Array(P * L);
    for (let p = 0; p < P; p++) for (let l = 0; l < L; l++) {
      let s = 0;
      for (let k = 0; k < L; k++) s += W[k * P + p] * Gi[k][l];
      M[p * L + l] = s;
    }
    // one link alone at value 1 should peak near 1
    let peaks = 0;
    for (let l = 0; l < L; l++) { let mx = 0; for (let p = 0; p < P; p++) mx = Math.max(mx, M[p * L + l]); peaks += mx; }
    norm = peaks / L || 1;
  }
  S.model = { key, links, pts, x0, x1, y0, y1, cell, nx, ny, P, L, px, py, W, M, norm, width };
  return S.model;
}

// Image + disturbance estimate for one frame, cached on the frame.
function locate(frame, model) {
  const key = model.key + "|" + selKey();
  if (frame._loc && frame._loc.key === key) return frame._loc;
  const vals = frameValues(frame);
  const { P, L, links, W, M } = model;
  const raw = links.map((l) => vals[l] ?? 0);
  // A body changes a few links; drift, interference or AGC trouble lifts them
  // all. Image only what stands out above the median link.
  const sorted = [...raw].sort((a, b) => a - b);
  const med = L > 2 ? Math.max(0, sorted[Math.floor((L - 1) / 2)]) : 0;
  const y = raw.map((v) => v - med);
  const img = new Float32Array(P);
  if (M) {
    for (let p = 0; p < P; p++) { let s = 0; for (let l = 0; l < L; l++) s += M[p * L + l] * y[l]; img[p] = s / model.norm; }
  } else {
    for (let l = 0; l < L; l++) { const v = Math.max(0, y[l]); if (v) for (let p = 0; p < P; p++) img[p] += W[l * P + p] * v; }
  }
  let peak = 0, pi = -1;
  for (let p = 0; p < P; p++) if (img[p] > peak) { peak = img[p]; pi = p; }
  let loc = null;
  if (pi >= 0) {
    // weighted centroid of the top of the peak (sub-pixel, and steadier than argmax)
    const cut = 0.7 * peak;
    let sx = 0, sy = 0, sw = 0;
    for (let p = 0; p < P; p++) if (img[p] > cut) {
      const w = img[p] - cut;
      if (Math.hypot(model.px[p] - model.px[pi], model.py[p] - model.py[pi]) < 1.0) { sx += w * model.px[p]; sy += w * model.py[p]; sw += w; }
    }
    loc = sw ? [sx / sw, sy / sw] : [model.px[pi], model.py[pi]];
  }
  const maxLink = raw.length ? Math.max(...raw) : 0;
  frame._loc = { key, img, peak, loc, maxLink };
  return frame._loc;
}
const detected = (r) => r && r.loc && r.maxLink >= threshold();

// ---------------------------------------------------------------- canvas helpers
function fitCanvas(cv, cssHeight) {
  if (cssHeight != null) cv.style.height = cssHeight + "px";
  const r = cv.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const w = Math.round(r.width * dpr), h = Math.round(r.height * dpr);
  if (cv.width !== w || cv.height !== h) { cv.width = w; cv.height = h; }
  const ctx = cv.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx, w: r.width, h: r.height };
}
function hexToRgb(h) { const n = parseInt(h.slice(1), 16); return [n >> 16, (n >> 8) & 255, n & 255]; }
const lutCache = {};
function lut(kind) {
  const mode = isDark() ? "dark" : "light", k = kind + mode;
  if (lutCache[k]) return lutCache[k];
  const stops = (kind === "div" ? DIV : SEQ)[mode].map(hexToRgb);
  const out = new Uint8ClampedArray(256 * 3);
  for (let i = 0; i < 256; i++) {
    const t = i / 255 * (stops.length - 1), j = Math.min(Math.floor(t), stops.length - 2), f = t - j;
    for (let c = 0; c < 3; c++) out[i * 3 + c] = stops[j][c] + (stops[j + 1][c] - stops[j][c]) * f;
  }
  return (lutCache[k] = out);
}
// value -> rgb string, sequential for magnitudes, diverging for signed metrics
function colorFor(v, scale, signed) {
  let i;
  if (signed) i = Math.round((Math.max(-1, Math.min(1, v / scale)) + 1) / 2 * 255);
  else i = Math.round(Math.max(0, Math.min(1, v / scale)) * 255);
  const L = lut(signed ? "div" : "seq");
  return `rgb(${L[i * 3]},${L[i * 3 + 1]},${L[i * 3 + 2]})`;
}
function rampCss(signed) { return `linear-gradient(90deg,${(signed ? DIV : SEQ)[isDark() ? "dark" : "light"].join(",")})`; }
const tip = $("tip");
function showTip(e, html) {
  tip.innerHTML = html; tip.style.display = "block";
  const x = Math.min(e.clientX + 14, window.innerWidth - tip.offsetWidth - 8);
  const y = Math.min(e.clientY + 14, window.innerHeight - tip.offsetHeight - 8);
  tip.style.left = x + "px"; tip.style.top = y + "px";
}
function hideTip() { tip.style.display = "none"; }
function trail(model) {
  const out = [];
  for (const f of S.history.slice(-TRAIL_LEN)) {
    const r = locate(f, model);
    if (detected(r)) out.push({ loc: r.loc, t: f.t });
  }
  return out;
}

// ---------------------------------------------------------------- spatial map
const mapCv = $("map");
const off = document.createElement("canvas");
let mapView = null, dragDev = null, frozenView = null;

function makeView(w, h, m) {
  const s = Math.min(w / (m.x1 - m.x0), h / (m.y1 - m.y0));
  const ox = (w - (m.x1 - m.x0) * s) / 2, oy = (h - (m.y1 - m.y0) * s) / 2;
  return {
    s, x0: m.x0, y1: m.y1, ox, oy,
    toScreen: (p) => [ox + (p[0] - m.x0) * s, oy + (m.y1 - p[1]) * s],
    toWorld: (x, y) => [m.x0 + (x - ox) / s, m.y1 - (y - oy) / s],
  };
}
function drawMap() {
  const { ctx, w, h } = fitCanvas(mapCv);
  ctx.fillStyle = css("--surface"); ctx.fillRect(0, 0, w, h);
  const model = getModel();
  if (!model) return;
  const view = mapView = frozenView || makeView(w, h, model);
  const frame = S.history[S.history.length - 1];
  const res = frame && model.L ? locate(frame, model) : null;
  const scale = currentScale();

  // reconstruction image
  if (res) {
    off.width = model.nx; off.height = model.ny;
    const octx = off.getContext("2d"), img = octx.createImageData(model.nx, model.ny), L = lut("seq");
    for (let p = 0; p < model.P; p++) {
      const li = Math.round(Math.max(0, Math.min(1, res.img[p] / scale)) * 255) * 3;
      img.data[p * 4] = L[li]; img.data[p * 4 + 1] = L[li + 1]; img.data[p * 4 + 2] = L[li + 2]; img.data[p * 4 + 3] = 255;
    }
    octx.putImageData(img, 0, 0);
    const [sx, sy] = view.toScreen([model.x0, model.y1]);
    ctx.imageSmoothingEnabled = true;
    ctx.drawImage(off, sx, sy, model.nx * model.cell * view.s, model.ny * model.cell * view.s);
  }

  // 1 m grid
  ctx.strokeStyle = css("--grid"); ctx.lineWidth = 1; ctx.globalAlpha = 0.5;
  const [wx0, wy0] = view.toWorld(0, h), [wx1, wy1] = view.toWorld(w, 0);
  for (let x = Math.ceil(wx0); x <= wx1; x++) { const [sx] = view.toScreen([x, 0]); ctx.beginPath(); ctx.moveTo(sx, 0); ctx.lineTo(sx, h); ctx.stroke(); }
  for (let y = Math.ceil(wy0); y <= wy1; y++) { const [, sy] = view.toScreen([0, y]); ctx.beginPath(); ctx.moveTo(0, sy); ctx.lineTo(w, sy); ctx.stroke(); }
  ctx.globalAlpha = 1;

  // links
  const on = new Set(model.links);
  for (const l of allLinks()) {
    const [a, b] = linkEnds(l).map((n) => S.draft[n]);
    const hl = l === S.hlLink;
    ctx.strokeStyle = hl ? css("--accent") : css("--ink-2");
    ctx.globalAlpha = hl ? 1 : on.has(l) ? 0.45 : 0.12;
    ctx.lineWidth = hl ? 2.5 : 1;
    ctx.setLineDash(l.startsWith("R-") ? [] : [6, 4]);
    ctx.beginPath(); ctx.moveTo(...view.toScreen(a)); ctx.lineTo(...view.toScreen(b)); ctx.stroke();
    ctx.setLineDash([]);
    if (hl) {
      const d = dist(a, b), A = (d + model.width) / 2, B = Math.sqrt(Math.max(A * A - (d / 2) ** 2, 0));
      const mid = view.toScreen([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]);
      ctx.setLineDash([3, 3]); ctx.lineWidth = 1;
      ctx.beginPath(); ctx.ellipse(mid[0], mid[1], A * view.s, B * view.s, -Math.atan2(b[1] - a[1], b[0] - a[0]), 0, 2 * Math.PI); ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = css("--ink"); ctx.font = "12px system-ui, sans-serif"; ctx.textAlign = "center";
      ctx.fillText(`${linkLabel(l)} · ${d.toFixed(2)} m`, mid[0], mid[1] - 8);
    }
  }
  ctx.globalAlpha = 1;

  // disturbance: trail, marker, and range lines to the reference antenna
  if (res && !S.editLayout) {
    const tr = trail(model);
    const mark = css("--mark");
    tr.forEach((pt, i) => {
      const [x, y] = view.toScreen(pt.loc);
      ctx.globalAlpha = 0.15 + 0.6 * (i / tr.length);
      ctx.fillStyle = mark; ctx.beginPath(); ctx.arc(x, y, 3, 0, 2 * Math.PI); ctx.fill();
    });
    ctx.globalAlpha = 1;
    if (detected(res)) {
      const [x, y] = view.toScreen(res.loc);
      const ref = S.draft[S.refAnt];
      if (ref) {
        const [rx, ry] = view.toScreen(ref);
        ctx.strokeStyle = mark; ctx.lineWidth = 1; ctx.setLineDash([4, 4]);
        ctx.beginPath(); ctx.moveTo(rx, ry); ctx.lineTo(x, y); ctx.stroke(); ctx.setLineDash([]);
        ctx.fillStyle = css("--ink"); ctx.font = "600 12px system-ui, sans-serif"; ctx.textAlign = "center";
        ctx.fillText(`${dist(ref, res.loc).toFixed(2)} m`, (rx + x) / 2, (ry + y) / 2 - 6);
      }
      ctx.strokeStyle = css("--surface"); ctx.lineWidth = 5;
      ctx.beginPath(); ctx.arc(x, y, 10, 0, 2 * Math.PI); ctx.stroke();
      ctx.strokeStyle = mark; ctx.lineWidth = 2.5;
      ctx.beginPath(); ctx.arc(x, y, 10, 0, 2 * Math.PI); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(x - 15, y); ctx.lineTo(x - 5, y); ctx.moveTo(x + 5, y); ctx.lineTo(x + 15, y);
      ctx.moveTo(x, y - 15); ctx.lineTo(x, y - 5); ctx.moveTo(x, y + 5); ctx.lineTo(x, y + 15); ctx.stroke();
    }
  }

  // simulator ground truth
  if (frame && frame.truth) {
    const [x, y] = view.toScreen(frame.truth);
    ctx.strokeStyle = css("--ink"); ctx.lineWidth = 1.5; ctx.globalAlpha = 0.8;
    ctx.beginPath(); ctx.moveTo(x, y - 7); ctx.lineTo(x + 7, y); ctx.lineTo(x, y + 7); ctx.lineTo(x - 7, y); ctx.closePath(); ctx.stroke();
    ctx.globalAlpha = 1;
  }

  // antennas
  for (const [n, p] of Object.entries(S.draft)) {
    const [x, y] = view.toScreen(p);
    const st = n === "R" ? { online: true } : (S.status && S.status.nodes[n]) || {};
    ctx.fillStyle = css("--ink"); ctx.strokeStyle = n === S.refAnt ? css("--mark") : css("--surface"); ctx.lineWidth = 2;
    ctx.beginPath();
    if (n === "R") ctx.rect(x - 6, y - 6, 12, 12); else ctx.arc(x, y, 6, 0, 2 * Math.PI);
    ctx.fill(); ctx.stroke();
    if (!st.online) { ctx.fillStyle = css("--critical"); ctx.beginPath(); ctx.arc(x + 6, y - 6, 3, 0, 2 * Math.PI); ctx.fill(); }
    ctx.fillStyle = css("--ink");
    ctx.font = "600 12px system-ui, sans-serif"; ctx.textAlign = "left";
    ctx.fillText(devName(n), x + 10, y + 4);
    if (S.editLayout) {
      ctx.font = "11px system-ui, sans-serif"; ctx.fillStyle = css("--ink-2");
      ctx.fillText(`(${p[0].toFixed(2)}, ${p[1].toFixed(2)})`, x + 10, y + 17);
    }
  }

  // scale bar
  ctx.strokeStyle = css("--ink-2"); ctx.lineWidth = 2;
  ctx.beginPath(); ctx.moveTo(12, h - 14); ctx.lineTo(12 + view.s, h - 14); ctx.stroke();
  ctx.fillStyle = css("--ink-2"); ctx.font = "11px system-ui, sans-serif"; ctx.textAlign = "left";
  ctx.fillText("1 m", 12, h - 20);

  const m = METRICS[S.metric];
  $("legend").innerHTML =
    `<span>0</span><span class="ramp" style="background:${rampCss(false)}"></span>` +
    `<span>${fmt(scale, m.unit)}${S.autoScale ? " (auto)" : ""}</span>` +
    `<span class="key"><span class="sym"></span>estimated disturbance (dots = last 10 s)</span>` +
    `<span class="key">solid = router links · dashed = node links</span>` +
    (frame && "truth" in frame ? `<span class="key">◇ simulated person (true position)</span>` : "");

  drawRelative(model, res);
}
function nearestLink(p) {
  let best = null, bd = 1e9;
  for (const l of allLinks()) {
    const [a, b] = linkEnds(l).map((n) => S.draft[n]);
    const dx = b[0] - a[0], dy = b[1] - a[1], t = Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)));
    const d = dist(p, [a[0] + t * dx, a[1] + t * dy]);
    if (d < bd) { bd = d; best = l; }
  }
  return { link: best, d: bd };
}
function deviceAt(x, y) {
  for (const [n, p] of Object.entries(S.draft || {})) {
    const [sx, sy] = mapView.toScreen(p);
    if (Math.hypot(sx - x, sy - y) < 12) return n;
  }
  return null;
}
mapCv.addEventListener("mousedown", (e) => {
  if (!S.editLayout || !mapView) return;
  const r = mapCv.getBoundingClientRect();
  dragDev = deviceAt(e.clientX - r.left, e.clientY - r.top);
  if (dragDev) frozenView = mapView;
});
window.addEventListener("mouseup", () => {
  if (dragDev) { dragDev = null; frozenView = null; renderDevices(); S.dirty = true; }
  scDrag = null;
});
mapCv.addEventListener("mousemove", (e) => {
  if (!mapView || !S.draft) return;
  const r = mapCv.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
  const p = mapView.toWorld(x, y);
  if (dragDev) {
    S.draft[dragDev] = p.map((v) => Math.round(v * 20) / 20);
    markDraftDirty();
    return;
  }
  if (S.editLayout) {
    mapCv.style.cursor = deviceAt(x, y) ? "grab" : "default";
    showTip(e, `x ${p[0].toFixed(2)} m, y ${p[1].toFixed(2)} m<br>Drag an antenna to move it`);
    return;
  }
  const model = getModel(), frame = S.history[S.history.length - 1];
  let html = `x ${p[0].toFixed(2)} m, y ${p[1].toFixed(2)} m`;
  if (model && frame && model.L) {
    const res = locate(frame, model);
    const i = Math.floor((p[0] - model.x0) / model.cell), j = Math.floor((model.y1 - p[1]) / model.cell);
    if (i >= 0 && j >= 0 && i < model.nx && j < model.ny) html += `<br>image <b>${fmt(res.img[j * model.nx + i], METRICS[S.metric].unit)}</b>`;
  }
  const ref = S.draft[S.refAnt];
  if (ref) html += `<br>${dist(ref, p).toFixed(2)} m from ${devName(S.refAnt)}`;
  const nl = nearestLink(p);
  if (nl.link && nl.d < 0.4) {
    html += `<br>${linkLabel(nl.link)}: <b>${fmt(frame ? frameValues(frame)[nl.link] : null, METRICS[S.metric].unit)}</b>`;
  }
  showTip(e, html);
});
mapCv.addEventListener("mouseleave", hideTip);
mapCv.addEventListener("click", (e) => {
  if (S.editLayout || !mapView) return;
  const r = mapCv.getBoundingClientRect();
  const nl = nearestLink(mapView.toWorld(e.clientX - r.left, e.clientY - r.top));
  S.hlLink = nl.link && nl.d < 0.4 && S.hlLink !== nl.link ? nl.link : null;
  S.dirty = true;
});

// ---------------------------------------------------------------- relative-to-antenna views
const radarCv = $("radar");
function bearing(from, to) {
  // 0° = up on the map, clockwise
  const a = Math.atan2(to[0] - from[0], to[1] - from[1]) * 180 / Math.PI;
  return (a + 360) % 360;
}
function drawRelative(model, res) {
  const { ctx, w, h } = fitCanvas(radarCv);
  ctx.fillStyle = css("--surface"); ctx.fillRect(0, 0, w, h);
  const ref = S.draft[S.refAnt];
  if (!ref) return;
  const det = detected(res);
  const maxD = Math.max(1, ...Object.values(S.draft).map((p) => dist(ref, p))) + 1;
  const R = Math.min(w, h) / 2 - 22, cx = w / 2, cy = h / 2, s = R / maxD;
  const to = (p) => [cx + (p[0] - ref[0]) * s, cy - (p[1] - ref[1]) * s];

  // range rings + spokes
  const step = maxD > 8 ? 2 : maxD > 4 ? 1 : 0.5;
  ctx.strokeStyle = css("--grid"); ctx.lineWidth = 1;
  ctx.fillStyle = css("--muted"); ctx.font = "11px system-ui, sans-serif"; ctx.textAlign = "left";
  for (let r = step; r <= maxD + 1e-6; r += step) {
    ctx.beginPath(); ctx.arc(cx, cy, r * s, 0, 2 * Math.PI); ctx.stroke();
    ctx.fillText(`${r} m`, cx + r * s * 0.707 + 2, cy + r * s * 0.707 + 10);
  }
  ctx.textAlign = "center";
  for (let a = 0; a < 360; a += 45) {
    const t = a * Math.PI / 180;
    ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(cx + Math.sin(t) * R, cy - Math.cos(t) * R); ctx.stroke();
    if (a % 90 === 0) ctx.fillText(`${a}°`, cx + Math.sin(t) * (R + 12), cy - Math.cos(t) * (R + 12) + 4);
  }

  // other antennas and the links touching the reference
  for (const l of allLinks()) {
    const [a, b] = linkEnds(l);
    if (a !== S.refAnt && b !== S.refAnt) continue;
    ctx.strokeStyle = css("--ink-2"); ctx.globalAlpha = 0.35; ctx.setLineDash(a === "R" ? [] : [6, 4]);
    ctx.beginPath(); ctx.moveTo(...to(S.draft[a])); ctx.lineTo(...to(S.draft[b])); ctx.stroke();
    ctx.setLineDash([]); ctx.globalAlpha = 1;
  }
  for (const [n, p] of Object.entries(S.draft)) {
    const [x, y] = to(p);
    ctx.fillStyle = css("--ink");
    ctx.beginPath();
    if (n === "R") ctx.rect(x - 5, y - 5, 10, 10); else ctx.arc(x, y, 5, 0, 2 * Math.PI);
    ctx.fill();
    ctx.font = n === S.refAnt ? "600 12px system-ui, sans-serif" : "11px system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.fillText(n === S.refAnt ? `${devName(n)} (centre)` : devName(n), x + 8, y + 4);
  }

  // trail + current
  const mark = css("--mark");
  const tr = res ? trail(model) : [];
  tr.forEach((pt, i) => {
    const [x, y] = to(pt.loc);
    ctx.globalAlpha = 0.15 + 0.6 * (i / tr.length);
    ctx.fillStyle = mark; ctx.beginPath(); ctx.arc(x, y, 3, 0, 2 * Math.PI); ctx.fill();
  });
  ctx.globalAlpha = 1;
  if (det) {
    const [x, y] = to(res.loc);
    ctx.strokeStyle = mark; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(x, y); ctx.stroke();
    ctx.strokeStyle = css("--surface"); ctx.lineWidth = 4;
    ctx.beginPath(); ctx.arc(x, y, 8, 0, 2 * Math.PI); ctx.stroke();
    ctx.strokeStyle = mark; ctx.lineWidth = 2.5;
    ctx.beginPath(); ctx.arc(x, y, 8, 0, 2 * Math.PI); ctx.stroke();
  }

  const m = METRICS[S.metric];
  if (det) {
    $("locText").innerHTML = `<b>${dist(ref, res.loc).toFixed(2)} m</b> at bearing <b>${bearing(ref, res.loc).toFixed(0)}°</b> from ${devName(S.refAnt)}` +
      ` · position (${res.loc[0].toFixed(2)}, ${res.loc[1].toFixed(2)}) m<br><span class="muted">strongest link ${fmt(res.maxLink, m.unit)} ≥ threshold ${fmt(threshold(), m.unit)} · 0° = up on the map, clockwise</span>`;
  } else {
    $("locText").innerHTML = `No disturbance above threshold.<br><span class="muted">strongest link ${fmt(res ? res.maxLink : null, m.unit)} &lt; ${fmt(threshold(), m.unit)}</span>`;
  }

  // distance list
  const names = Object.keys(S.draft).sort((a, b) => a === "R" ? -1 : b === "R" ? 1 : a.localeCompare(b));
  const ds = det ? names.map((n) => dist(S.draft[n], res.loc)) : null;
  const dmax = ds ? Math.max(...ds) : 1, nearest = ds ? names[ds.indexOf(Math.min(...ds))] : null;
  $("distList").innerHTML = names.map((n, i) => `<div class="dist-row ${n === nearest ? "nearest" : ""}">
    <span class="name">${devName(n)}</span>
    <span class="track"><span class="fill" style="display:block;width:${ds ? (ds[i] / dmax * 100).toFixed(1) : 0}%"></span></span>
    <span class="num">${ds ? ds[i].toFixed(2) + " m" : "–"}</span></div>`).join("");
  if (det) {
    const zones = model.links.map((l) => {
      const [a, b] = linkEnds(l).map((n) => S.draft[n]);
      return { l, w: zoneWeight(res.loc[0], res.loc[1], a, b, dist(a, b), model.width) };
    }).filter((z) => z.w > 0.3).sort((a, b) => b.w - a.w);
    $("zoneList").innerHTML = zones.length
      ? `Inside the zone of: ${zones.map((z) => `${linkLabel(z.l)} (${(z.w * 100).toFixed(0)}%)`).join(", ")}`
      : "Not inside any single link's zone. The estimate is pulled between several links.";
  } else $("zoneList").textContent = "";
}

// ---------------------------------------------------------------- link table
let tableT = 0;
function drawLinkTable(force) {
  const now = performance.now();
  if (!force && now - tableT < 400) return;
  tableT = now;
  const frame = S.history[S.history.length - 1];
  const vals = frame ? frameValues(frame) : {};
  const m = METRICS[S.metric], scale = currentScale();
  const rows = allLinks().map((l) => ({ l, v: vals[l], d: frame && frame.links[l], on: linkShown(l) && !S.linkOff.has(l) }))
    .sort((a, b) => (b.on - a.on) || ((b.v ?? -1e9) - (a.v ?? -1e9)));
  $("linkTable").tBodies[0].innerHTML = rows.map(({ l, v, d, on }) => {
    const pct = v == null ? 0 : Math.min(100, Math.abs(v) / scale * 100);
    const fill = v == null ? "" : v >= 0 ? `<span class="fill" style="left:0;width:${pct}%"></span>`
      : `<span class="fill neg" style="left:0;width:${pct}%"></span>`;
    return `<tr data-link="${l}" class="${on ? "" : "off"} ${l === S.hlLink ? "hl" : ""}">
      <td><input type="checkbox" data-toggle="${l}" ${S.linkOff.has(l) ? "" : "checked"} ${linkShown(l) ? "" : "disabled"}></td>
      <td>${linkLabel(l)}</td><td class="num">${fmt(v, m.unit)}</td>
      <td class="bar-col"><div class="track">${fill}</div></td>
      <td class="num">${d ? d.rate.toFixed(0) : "–"}</td><td class="num">${d ? d.rssi.toFixed(0) + " dBm" : "–"}</td>
      <td class="muted">${d ? (d.calibrated ? "calibrated" : "running") : "no data"}</td></tr>`;
  }).join("");
}
// mousedown, not click: the table re-renders a few times a second
$("linkTable").addEventListener("mousedown", (e) => {
  const tog = e.target.dataset.toggle;
  if (tog) {
    e.preventDefault();
    S.linkOff.has(tog) ? S.linkOff.delete(tog) : S.linkOff.add(tog);
    store.set("linkOff", [...S.linkOff]);
  } else {
    const tr = e.target.closest("tr[data-link]");
    if (!tr) return;
    S.hlLink = S.hlLink === tr.dataset.link ? null : tr.dataset.link;
  }
  S.dirty = true; drawLinkTable(true);
});

// ---------------------------------------------------------------- per-subcarrier heatmap
const scCv = $("sc");
let scLayout = null, scDrag = null;
function drawSubcarriers() {
  const m = METRICS[S.metric];
  const links = enabledLinks();
  const rowH = Math.max(8, Math.min(18, Math.floor(320 / Math.max(links.length, 1))));
  const L = 64, T = 6, B = T + rowH * Math.max(links.length, 1);
  const { ctx, w, h } = fitCanvas(scCv, m.vector ? B + 22 : 60);
  ctx.fillStyle = css("--surface"); ctx.fillRect(0, 0, w, h);
  const R = w - 8;
  scLayout = { L, R, T, rowH, step: (R - L) / SUBCARRIERS.length, links };
  if (!m.vector) {
    ctx.fillStyle = css("--muted"); ctx.font = "13px system-ui, sans-serif"; ctx.textAlign = "center";
    ctx.fillText(`${m.label} is one number per packet, so there's no per-subcarrier breakdown.`, w / 2, 34);
    $("scLegend").innerHTML = "";
    return;
  }
  const frame = S.history[S.history.length - 1];
  let mx = m.floor;
  for (const l of links) { const v = frame && frame.links[l] && frame.links[l][S.metric]; if (v) for (const x of v) mx = Math.max(mx, Math.abs(x)); }
  const step = scLayout.step;
  links.forEach((l, r) => {
    const v = frame && frame.links[l] && frame.links[l][S.metric];
    const y = T + r * rowH;
    ctx.fillStyle = css("--ink-2"); ctx.font = `${Math.min(12, rowH)}px system-ui, sans-serif`; ctx.textAlign = "right";
    ctx.fillText(l, L - 6, y + rowH - Math.max(1, (rowH - 10) / 2) - 1);
    if (!v) return;
    for (let i = 0; i < SUBCARRIERS.length; i++) {
      ctx.fillStyle = colorFor(v[i], mx, m.signed);
      ctx.fillRect(L + i * step, y, step - 1, rowH - 1);
    }
    if (l === S.hlLink) { ctx.strokeStyle = css("--accent"); ctx.lineWidth = 2; ctx.strokeRect(L - 1, y - 1, R - L + 1, rowH + 1); }
  });
  // dim unselected columns
  ctx.fillStyle = css("--surface"); ctx.globalAlpha = 0.65;
  SUBCARRIERS.forEach((k, i) => { if (k < S.scLo || k > S.scHi) ctx.fillRect(L + i * step, T, step, B - T); });
  ctx.globalAlpha = 1;
  ctx.fillStyle = css("--muted"); ctx.font = "11px system-ui, sans-serif"; ctx.textAlign = "center";
  for (const k of [-26, -13, 13, 26]) ctx.fillText(k, L + (SUBCARRIERS.indexOf(k) + 0.5) * step, h - 6);
  ctx.fillText("subcarrier (DC at centre)", (L + R) / 2, h - 6);
  $("scLegend").innerHTML = `<span>${m.signed ? fmt(-mx, m.unit) : "0"}</span><span class="ramp" style="background:${rampCss(m.signed)}"></span><span>${fmt(mx, m.unit)}</span>`;
}
function scHit(e) {
  const r = scCv.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
  const i = Math.max(0, Math.min(SUBCARRIERS.length - 1, Math.floor((x - scLayout.L) / scLayout.step)));
  const row = Math.floor((y - scLayout.T) / scLayout.rowH);
  return { i, link: scLayout.links[row] };
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
scCv.addEventListener("mousedown", (e) => {
  if (!scLayout || !METRICS[S.metric].vector) return;
  scDrag = scHit(e).i;
  setScRange(SUBCARRIERS[scDrag], SUBCARRIERS[scDrag]);
});
scCv.addEventListener("mousemove", (e) => {
  if (!scLayout || !METRICS[S.metric].vector) return;
  const { i, link } = scHit(e);
  if (scDrag != null) setScRange(SUBCARRIERS[scDrag], SUBCARRIERS[i]);
  const frame = S.history[S.history.length - 1];
  if (!link) { hideTip(); return; }
  const v = frame && frame.links[link] && frame.links[link][S.metric];
  showTip(e, `${linkLabel(link)} · subcarrier ${SUBCARRIERS[i]}<br><b>${fmt(v ? v[i] : null, METRICS[S.metric].unit)}</b>`);
});
scCv.addEventListener("mouseleave", hideTip);

// ---------------------------------------------------------------- history
const histCv = $("hist");
let histLayout = null;
function drawHistory() {
  const m = METRICS[S.metric], model = getModel();
  const links = enabledLinks();
  const mode = S.histMode || (links.length <= 6 ? "bars" : "heat");
  for (const b of $("histMode").children) b.classList.toggle("on", b.dataset.v === mode);
  const distH = 56, laneH = mode === "bars" ? 44 : Math.max(6, Math.min(14, Math.floor(300 / Math.max(links.length, 1))));
  const Lm = 64, T = 4;
  const B = T + distH + 8 + laneH * links.length;
  const { ctx, w, h } = fitCanvas(histCv, B + 22);
  ctx.fillStyle = css("--surface"); ctx.fillRect(0, 0, w, h);
  const R = w - 8, n = HISTORY_LEN, step = (R - Lm) / n, start = n - S.history.length;
  histLayout = { Lm, step, links, start };
  if (!model) return;

  // calibration shading
  ctx.fillStyle = css("--select");
  S.history.forEach((f, i) => { if (f.calibrating) ctx.fillRect(Lm + (start + i) * step, T, step + 0.5, B - T); });

  const bw = Math.max(1, step - (step > 3 ? 1 : 0));
  // lane 0: distance of the disturbance from the reference antenna
  const ref = S.draft[S.refAnt];
  const ds = S.history.map((f) => { const r = model.L ? locate(f, model) : null; return detected(r) && ref ? dist(ref, r.loc) : null; });
  const dMax = Math.max(1, ...Object.values(S.draft).map((p) => ref ? dist(ref, p) : 0)) + 0.5;
  const dTop = T + 12, dBot = T + distH;
  ctx.strokeStyle = css("--axis"); ctx.lineWidth = 1;
  ctx.beginPath(); ctx.moveTo(Lm, dBot + 0.5); ctx.lineTo(R, dBot + 0.5); ctx.stroke();
  ctx.fillStyle = css("--ink-2"); ctx.font = "11px system-ui, sans-serif"; ctx.textAlign = "left";
  ctx.fillText(`Disturbance distance from ${devName(S.refAnt)}`, Lm + 4, T + 9);
  ctx.textAlign = "right"; ctx.fillStyle = css("--muted");
  ctx.fillText(`${dMax.toFixed(1)} m`, Lm - 4, dTop + 8); ctx.fillText("0", Lm - 4, dBot);
  const mark = css("--mark");
  ds.forEach((d, i) => { if (d != null) bar(ctx, Lm + (start + i) * step, dBot, dBot - d / dMax * (dBot - dTop), bw, mark); });

  // link lanes
  let mx = m.floor, mn = 0;
  for (const f of S.history) { const vals = frameValues(f); for (const l of links) { const v = vals[l]; if (v != null) { mx = Math.max(mx, v); mn = Math.min(mn, v); } } }
  if (mn < 0) { const a = Math.max(mx, -mn); mx = a; mn = -a; }
  const top0 = dBot + 8;
  const accent = css("--accent");
  links.forEach((l, j) => {
    const top = top0 + j * laneH;
    ctx.fillStyle = l === S.hlLink ? css("--accent") : css("--ink-2"); ctx.textAlign = "right";
    ctx.font = `${Math.min(11, laneH)}px system-ui, sans-serif`;
    if (mode === "heat") {
      ctx.fillText(l, Lm - 6, top + laneH - 2);
      S.history.forEach((f, i) => {
        const v = frameValues(f)[l];
        if (v == null) return;
        ctx.fillStyle = colorFor(v, Math.max(mx, -mn), m.signed);
        ctx.fillRect(Lm + (start + i) * step, top, step + 0.5, laneH - 1);
      });
    } else {
      const t = top + 4, b = top + laneH - 4;
      const y = (v) => b - (v - mn) / (mx - mn) * (b - t);
      ctx.fillText(l, Lm - 6, t + 9);
      ctx.fillStyle = css("--muted"); ctx.fillText(fmt(mx, ""), Lm - 6, t + 20);
      ctx.strokeStyle = css("--axis"); ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(Lm, y(0) + 0.5); ctx.lineTo(R, y(0) + 0.5); ctx.stroke();
      S.history.forEach((f, i) => { const v = frameValues(f)[l]; if (v != null) bar(ctx, Lm + (start + i) * step, y(0), y(v), bw, accent); });
    }
  });
  ctx.fillStyle = css("--muted"); ctx.textAlign = "center"; ctx.font = "11px system-ui, sans-serif";
  for (let s = 30; s >= 0; s -= 5) ctx.fillText(s ? `-${s}s` : "now", Lm + (n - s * 10) * step - (s ? 0 : 12), h - 5);

  if (histLayout.hover != null) {
    const x = Lm + (histLayout.hover + 0.5) * step;
    ctx.strokeStyle = css("--ink-2"); ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(x, T); ctx.lineTo(x, B); ctx.stroke();
  }
}
function bar(ctx, x, y0, y1, bw, color) {
  // rounded end on the data side, flat on the baseline
  const top = Math.min(y0, y1), hgt = Math.abs(y1 - y0);
  if (hgt < 0.5) return;
  const r = Math.min(4, bw / 2, hgt);
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.roundRect(x, top, bw, hgt, y1 <= y0 ? [r, r, 0, 0] : [0, 0, r, r]);
  ctx.fill();
}
histCv.addEventListener("mousemove", (e) => {
  if (!histLayout) return;
  const r = histCv.getBoundingClientRect();
  const slot = Math.floor((e.clientX - r.left - histLayout.Lm) / histLayout.step);
  const f = S.history[slot - histLayout.start];
  if (!f) { histLayout.hover = null; hideTip(); S.dirty = true; return; }
  histLayout.hover = slot; S.dirty = true;
  const m = METRICS[S.metric], model = getModel(), vals = frameValues(f);
  const res = model && model.L ? locate(f, model) : null, ref = S.draft[S.refAnt];
  const top = histLayout.links.map((l) => [l, vals[l]]).filter(([, v]) => v != null).sort((a, b) => b[1] - a[1]).slice(0, 6);
  const ago = (S.history[S.history.length - 1].t - f.t).toFixed(1);
  showTip(e, `${ago} s ago${f.calibrating ? " · calibrating" : ""}<br>` +
    (detected(res) && ref ? `disturbance <b>${dist(ref, res.loc).toFixed(2)} m</b> from ${devName(S.refAnt)}<br>` : "no disturbance<br>") +
    top.map(([l, v]) => `${linkLabel(l)}: <b>${fmt(v, m.unit)}</b>`).join("<br>"));
});
histCv.addEventListener("mouseleave", () => { if (histLayout) histLayout.hover = null; hideTip(); S.dirty = true; });

// ---------------------------------------------------------------- selection panel
function segmented(id, get, set) {
  const el = $(id);
  const paint = () => { for (const b of el.children) b.classList.toggle("on", b.dataset.v === get()); };
  el.addEventListener("click", (e) => { if (e.target.dataset.v) { set(e.target.dataset.v); paint(); S.dirty = true; } });
  paint();
}
function onSelectionChange() {
  const m = METRICS[S.metric];
  $("metricLabel").textContent = `${m.label} (${m.unit})` + (m.vector ? "" : " · subcarrier selection n/a");
  $("scaleUnit").textContent = m.unit;
  $("threshUnit").textContent = m.unit;
  $("thresh").value = threshold();
  S.dirty = true;
}
function buildControls() {
  for (const [key, m] of Object.entries(METRICS)) {
    const lab = document.createElement("label");
    lab.innerHTML = `<input type="radio" name="metric" value="${key}"><span>${m.label} <em class="muted">(${m.unit})</em><span class="desc">${m.desc}</span></span>`;
    lab.querySelector("input").checked = key === S.metric;
    lab.querySelector("input").onchange = () => { S.metric = key; store.set("metric", key); onSelectionChange(); };
    $("metrics").appendChild(lab);
  }
  const bindCheck = (id, prop) => {
    $(id).checked = S[prop];
    $(id).onchange = () => { S[prop] = $(id).checked; store.set(prop, S[prop]); S.dirty = true; drawLinkTable(true); };
  };
  bindCheck("showRouter", "showRouter");
  bindCheck("showPeer", "showPeer");
  bindCheck("autoScale", "autoScale");
  $("scLo").value = S.scLo; $("scHi").value = S.scHi;
  $("scLo").onchange = $("scHi").onchange = () => setScRange(+$("scLo").value, +$("scHi").value);
  $("scAll").onclick = () => setScRange(-26, 26);
  $("scaleMax").value = S.scaleMax;
  $("scaleMax").onchange = () => {
    S.scaleMax = Math.max(0.01, +$("scaleMax").value || 1);
    S.autoScale = false; $("autoScale").checked = false;
    store.set("scaleMax", S.scaleMax); store.set("autoScale", false); S.dirty = true;
  };
  $("reg").value = S.reg;
  $("reg").onchange = () => { S.reg = Math.max(0.01, +$("reg").value || 0.3); store.set("reg", S.reg); S.dirty = true; };
  $("thresh").onchange = () => { S.thresh[S.metric] = Math.max(0, +$("thresh").value || 0); store.set("thresh", S.thresh); S.dirty = true; };
  const help = () => {
    $("imgModeHelp").textContent = S.imgMode === "tomo"
      ? "Solves for the picture that best explains all link readings at once, so a spot covered by several links isn't counted twice. Higher regularization gives a smoother, more cautious picture."
      : "Each link paints its value over its zone, and overlaps add up. Simple, but blurrier, and busy spots near antennas can look hotter than they are.";
    $("reg").closest("label").style.display = S.imgMode === "tomo" ? "" : "none";
  };
  segmented("imgMode", () => S.imgMode, (v) => { S.imgMode = v; store.set("imgMode", v); help(); });
  help();
  segmented("histMode", () => S.histMode, (v) => { S.histMode = v; store.set("histMode", v); });
  $("refAnt").onchange = () => { S.refAnt = $("refAnt").value; store.set("refAnt", S.refAnt); S.dirty = true; };
  $("editLayout").onchange = () => { S.editLayout = $("editLayout").checked; mapCv.classList.toggle("editing", S.editLayout); S.dirty = true; };
  onSelectionChange();
}

// ---------------------------------------------------------------- wiring
function loop() {
  if (S.dirty) {
    S.dirty = false;
    drawMap(); drawSubcarriers(); drawHistory(); drawLinkTable();
  }
  requestAnimationFrame(loop);
}
$("btnStart").onclick = () => { S.history = []; send({ cmd: "start" }); };
$("btnStop").onclick = () => send({ cmd: "stop" });
$("btnCalib").onclick = () => send({ cmd: "calibrate" });
$("btnApply").onclick = () => {
  const c = { devices: S.draft };
  for (const k of CFG_FIELDS) c[k] = parseFloat($(k).value);
  send({ cmd: "config", config: c });
  S.draftDirty = false;
  showMsg("cfgMsg", "Applied. If antennas moved, baselines were reset, so re-calibrate.", false);
};
$("channel").addEventListener("input", updateGeomInfo);
$("rate_hz").addEventListener("input", updateRateHint);
$("fresnel_m").addEventListener("input", () => { S.dirty = true; });
window.addEventListener("resize", () => { S.dirty = true; });
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { S.dirty = true; });

buildControls();
connect();
requestAnimationFrame(loop);
