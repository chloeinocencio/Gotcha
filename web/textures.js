/* Gotcha — texture painter.
 * Every printed or surface texture in the scene is painted here: the display cards, the machine's
 * printed face, the cap badge, the flap, the floor, the wall, the reflection environment and the
 * plastic's surface grain. The web app paints them at runtime; tools/bake-textures.py renders the
 * same functions to PNGs for the iOS app, so both platforms show identical artwork.
 * All randomness is seeded, so every paint is the same.
 */
(function (root) {
"use strict";

const FONT = '"Zen Maru Gothic", "Arial Rounded MT Bold", ui-rounded, sans-serif';
const C = {
  navy: "#1c3f8a", blue: "#2a4fa8", sky: "#5f97ea", ice: "#cfe2ff",
  yellow: "#f2c230", red: "#d8352a", ink: "#2b2230", cream: "#ece6d8", paper: "#fffdf8"
};

/* ---------- helpers ---------- */
function rng(seed) {
  let s = (seed >>> 0) || 1;
  return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296);
}
function logical(canvas, lw, lh) {
  const g = canvas.getContext("2d");
  g.setTransform(canvas.width / lw, 0, 0, canvas.height / lh, 0, 0);
  g.lineJoin = "round"; g.lineCap = "round";
  return g;
}
function rr(g, x, y, w, h, r) {
  r = Math.min(r, w / 2, h / 2);
  g.beginPath(); g.moveTo(x + r, y);
  g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r);
  g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath();
}
function circle(g, x, y, r) { g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); }
function text(g, s, x, y, size, weight, fill, align = "center") {
  g.font = `${weight} ${size}px ${FONT}`; g.textAlign = align; g.textBaseline = "middle";
  g.fillStyle = fill; g.fillText(s, x, y);
}
/* Chunky sticker lettering: offset shadow, thick outline, then fill. */
function bigText(g, s, x, y, size, fill, stroke, shadow, sw) {
  g.font = `900 ${size}px ${FONT}`; g.textAlign = "center"; g.textBaseline = "middle";
  g.lineWidth = sw; g.strokeStyle = shadow; g.strokeText(s, x + size * 0.05, y + size * 0.08);
  g.fillStyle = shadow; g.fillText(s, x + size * 0.05, y + size * 0.08);
  g.strokeStyle = stroke; g.strokeText(s, x, y);
  g.fillStyle = fill; g.fillText(s, x, y);
}
function sparkle(g, x, y, r, fill) {
  g.fillStyle = fill; g.beginPath();
  g.moveTo(x, y - r);
  g.quadraticCurveTo(x + r * 0.18, y - r * 0.18, x + r, y);
  g.quadraticCurveTo(x + r * 0.18, y + r * 0.18, x, y + r);
  g.quadraticCurveTo(x - r * 0.18, y + r * 0.18, x - r, y);
  g.quadraticCurveTo(x - r * 0.18, y - r * 0.18, x, y - r);
  g.fill();
}
function sunburst(g, cx, cy, n, R, c1, c2, rot) {
  g.fillStyle = c1; g.fillRect(-10, -10, 4000, 4000);
  g.fillStyle = c2;
  for (let i = 0; i < n; i++) {
    const a = rot + (i / n) * Math.PI * 2;
    g.beginPath(); g.moveTo(cx, cy);
    g.lineTo(cx + Math.cos(a) * R, cy + Math.sin(a) * R);
    g.lineTo(cx + Math.cos(a + Math.PI / n) * R, cy + Math.sin(a + Math.PI / n) * R);
    g.closePath(); g.fill();
  }
}
function halftone(g, x0, y0, w, h, step, maxR, color, fromCorner) {
  g.fillStyle = color;
  for (let y = y0; y < y0 + h; y += step) for (let x = x0; x < x0 + w; x += step) {
    const fx = (x - x0) / w, fy = (y - y0) / h;
    const t = fromCorner === "tr" ? Math.hypot(1 - fx, fy) : Math.hypot(fx, 1 - fy);
    const r = maxR * Math.max(0, 1 - t / 1.1);
    if (r > 0.4) { circle(g, x, y, r); g.fill(); }
  }
}
function burst(g, x, y, r, points, fill, stroke) {
  g.beginPath();
  for (let i = 0; i < points * 2; i++) {
    const a = (i / (points * 2)) * Math.PI * 2 - Math.PI / 2, rr2 = i % 2 ? r * 0.8 : r;
    g.lineTo(x + Math.cos(a) * rr2, y + Math.sin(a) * rr2);
  }
  g.closePath(); g.fillStyle = fill; g.fill();
  if (stroke) { g.lineWidth = 5; g.strokeStyle = stroke; g.stroke(); }
}
function cuteFace(g, x, y, s, ink = C.ink) {
  g.fillStyle = ink;
  for (const sx of [-1, 1]) { g.beginPath(); g.ellipse(x + sx * 0.34 * s, y, 0.075 * s, 0.1 * s, 0, 0, Math.PI * 2); g.fill(); }
  g.fillStyle = "#fff";
  for (const sx of [-1, 1]) { circle(g, x + sx * 0.34 * s + 0.025 * s, y - 0.035 * s, 0.028 * s); g.fill(); }
  g.fillStyle = "rgba(255,120,150,0.55)";
  for (const sx of [-1, 1]) { g.beginPath(); g.ellipse(x + sx * 0.55 * s, y + 0.14 * s, 0.11 * s, 0.065 * s, 0, 0, Math.PI * 2); g.fill(); }
  g.strokeStyle = ink; g.lineWidth = 0.045 * s;
  g.beginPath(); g.arc(x - 0.06 * s, y + 0.07 * s, 0.065 * s, 0.1 * Math.PI, 0.9 * Math.PI); g.stroke();
  g.beginPath(); g.arc(x + 0.06 * s, y + 0.07 * s, 0.065 * s, 0.1 * Math.PI, 0.9 * Math.PI); g.stroke();
}

/* ---------- little icons for the lineup ---------- */
const ICONS = {
  heart(g, x, y, s, c) { g.fillStyle = c; g.beginPath(); g.moveTo(x, y + s * 0.7);
    g.bezierCurveTo(x - s * 1.2, y - s * 0.1, x - s * 0.5, y - s * 0.95, x, y - s * 0.35);
    g.bezierCurveTo(x + s * 0.5, y - s * 0.95, x + s * 1.2, y - s * 0.1, x, y + s * 0.7); g.fill(); },
  star(g, x, y, s, c) { g.fillStyle = c; g.beginPath();
    for (let i = 0; i < 10; i++) { const a = -Math.PI / 2 + i * Math.PI / 5, r = i % 2 ? s * 0.42 : s; g.lineTo(x + Math.cos(a) * r, y + Math.sin(a) * r); }
    g.closePath(); g.fill(); },
  sun(g, x, y, s, c) { g.fillStyle = c; circle(g, x, y, s * 0.48); g.fill(); g.strokeStyle = c; g.lineWidth = s * 0.16;
    for (let i = 0; i < 8; i++) { const a = i * Math.PI / 4; g.beginPath(); g.moveTo(x + Math.cos(a) * s * 0.68, y + Math.sin(a) * s * 0.68); g.lineTo(x + Math.cos(a) * s * 0.95, y + Math.sin(a) * s * 0.95); g.stroke(); } },
  moon(g, x, y, s, c) { g.fillStyle = c; g.beginPath(); g.arc(x, y, s * 0.8, 0.35 * Math.PI, 1.65 * Math.PI, false);
    g.arc(x + s * 0.38, y - s * 0.1, s * 0.62, 1.55 * Math.PI, 0.45 * Math.PI, true); g.fill(); },
  crown(g, x, y, s, c) { g.fillStyle = c; g.beginPath(); g.moveTo(x - s * 0.85, y + s * 0.6); g.lineTo(x - s * 0.85, y - s * 0.4);
    g.lineTo(x - s * 0.4, y + s * 0.05); g.lineTo(x, y - s * 0.7); g.lineTo(x + s * 0.4, y + s * 0.05); g.lineTo(x + s * 0.85, y - s * 0.4);
    g.lineTo(x + s * 0.85, y + s * 0.6); g.closePath(); g.fill(); },
  flower(g, x, y, s, c) { g.fillStyle = c; for (let i = 0; i < 5; i++) { const a = i * Math.PI * 2 / 5 - Math.PI / 2; circle(g, x + Math.cos(a) * s * 0.45, y + Math.sin(a) * s * 0.45, s * 0.36); g.fill(); }
    g.fillStyle = C.yellow; circle(g, x, y, s * 0.28); g.fill(); },
  coin(g, x, y, s, c) { g.fillStyle = c; circle(g, x, y, s * 0.8); g.fill(); g.strokeStyle = "rgba(255,255,255,0.8)"; g.lineWidth = s * 0.12; circle(g, x, y, s * 0.55); g.stroke();
    g.font = `900 ${Math.round(s * 0.8)}px ${FONT}`; g.fillStyle = "#fff"; g.textAlign = "center"; g.textBaseline = "middle"; g.fillText("$", x, y + s * 0.05); },
  rainbow(g, x, y, s, c) { const cols = ["#e9536a", "#f2a33a", C.yellow, "#5cc58a", C.sky]; g.lineWidth = s * 0.17; g.lineCap = "butt";
    cols.forEach((col, i) => { g.strokeStyle = col; g.beginPath(); g.arc(x, y + s * 0.45, s * (0.95 - i * 0.17), Math.PI, 0); g.stroke(); }); g.lineCap = "round"; },
  sparkle(g, x, y, s, c) { sparkle(g, x, y, s, c); sparkle(g, x + s * 0.7, y - s * 0.6, s * 0.35, c); }
};
const ICON_ORDER = ["sun", "heart", "coin", "star", "crown", "flower", "moon", "rainbow", "sparkle"];
const ICON_COLORS = ["#f2a33a", "#e9536a", "#e0a81e", "#f2c230", "#e0a81e", "#f07fa0", "#7d8fd6", "#e9536a", "#6aa3f2"];

function miniCapsule(g, x, y, r, base, icon, iconColor, n) {
  g.fillStyle = "rgba(20,40,90,0.18)"; g.beginPath(); g.ellipse(x, y + r * 1.05, r * 0.9, r * 0.2, 0, 0, Math.PI * 2); g.fill();
  g.fillStyle = base; g.beginPath(); g.arc(x, y, r, 0, Math.PI); g.fill();
  g.fillStyle = "rgba(255,255,255,0.88)"; g.beginPath(); g.arc(x, y, r, Math.PI, 0); g.fill();
  g.lineWidth = r * 0.07; g.strokeStyle = "rgba(28,63,138,0.55)"; circle(g, x, y, r); g.stroke();
  g.beginPath(); g.moveTo(x - r, y); g.lineTo(x + r, y); g.stroke();
  ICONS[icon](g, x, y - r * 0.42, r * 0.42, iconColor);
  g.fillStyle = "rgba(255,255,255,0.75)"; g.beginPath(); g.ellipse(x - r * 0.45, y - r * 0.55, r * 0.16, r * 0.3, -0.6, 0, Math.PI * 2); g.fill();
  if (n) {
    g.fillStyle = C.navy; circle(g, x - r * 0.82, y - r * 0.78, r * 0.32); g.fill();
    text(g, String(n), x - r * 0.82, y - r * 0.76, Math.round(r * 0.38), 900, "#fff");
  }
}

/* ---------- mascots ---------- */
const MASCOTS = {
  capsule(g, x, y, s, base) {
    g.fillStyle = "rgba(10,30,80,0.22)"; g.beginPath(); g.ellipse(x, y + s * 1.08, s * 0.95, s * 0.16, 0, 0, Math.PI * 2); g.fill();
    // rolled message peeking out of the open dome
    g.save(); g.translate(x + s * 0.16, y - s * 0.62); g.rotate(-0.42);
    g.fillStyle = C.paper; rr(g, -s * 0.13, -s * 0.55, s * 0.26, s * 0.8, s * 0.11); g.fill();
    g.strokeStyle = "rgba(43,34,48,0.25)"; g.lineWidth = s * 0.02; g.stroke();
    g.fillStyle = C.navy; g.fillRect(-s * 0.13, -s * 0.28, s * 0.26, s * 0.06); g.restore();
    // body
    const grd = g.createLinearGradient(x - s, y, x + s, y + s);
    grd.addColorStop(0, base); grd.addColorStop(1, shade(base, -0.18));
    g.fillStyle = grd; g.beginPath(); g.arc(x, y, s, 0, Math.PI); g.closePath(); g.fill();
    g.fillStyle = shade(base, -0.25); g.fillRect(x - s, y - s * 0.03, s * 2, s * 0.1);
    // dome
    g.fillStyle = "rgba(255,255,255,0.55)"; g.beginPath(); g.arc(x, y - s * 0.02, s, Math.PI, 0); g.closePath(); g.fill();
    g.lineWidth = s * 0.045; g.strokeStyle = C.navy;
    g.beginPath(); g.arc(x, y, s, 0, Math.PI * 2); g.stroke();
    g.beginPath(); g.moveTo(x - s, y); g.lineTo(x + s, y); g.stroke();
    g.fillStyle = "rgba(255,255,255,0.9)"; g.beginPath(); g.ellipse(x - s * 0.5, y - s * 0.55, s * 0.13, s * 0.28, -0.7, 0, Math.PI * 2); g.fill();
    cuteFace(g, x, y + s * 0.4, s * 0.62, "#fff");
    // little arms
    g.strokeStyle = C.navy; g.lineWidth = s * 0.07;
    g.beginPath(); g.moveTo(x - s * 0.98, y + s * 0.25); g.quadraticCurveTo(x - s * 1.28, y + s * 0.1, x - s * 1.22, y - s * 0.22); g.stroke();
    g.beginPath(); g.moveTo(x + s * 0.98, y + s * 0.25); g.quadraticCurveTo(x + s * 1.25, y + s * 0.42, x + s * 1.36, y + s * 0.2); g.stroke();
  },
  donut(g, x, y, s) {
    g.fillStyle = "rgba(80,30,40,0.2)"; g.beginPath(); g.ellipse(x, y + s * 0.95, s, s * 0.17, 0, 0, Math.PI * 2); g.fill();
    g.fillStyle = "#e8b277"; circle(g, x, y, s); g.fill();
    g.fillStyle = "#f59bb8"; g.beginPath();
    for (let i = 0; i <= 28; i++) { const a = i / 28 * Math.PI * 2, r = s * (0.86 + 0.06 * Math.sin(i * 2.1)); g.lineTo(x + Math.cos(a) * r, y - s * 0.04 + Math.sin(a) * r); }
    g.fill();
    g.fillStyle = "#fbe7d0"; circle(g, x, y - s * 0.04, s * 0.3); g.fill();
    const r = rng(7), cols = ["#fff", C.yellow, "#6cc6f0", "#9be29b"];
    for (let i = 0; i < 26; i++) { const a = r() * Math.PI * 2, d = s * (0.4 + r() * 0.4);
      g.save(); g.translate(x + Math.cos(a) * d, y + Math.sin(a) * d); g.rotate(r() * 3); g.fillStyle = cols[i % 4]; rr(g, -s * 0.06, -s * 0.018, s * 0.12, s * 0.036, s * 0.02); g.fill(); g.restore(); }
    g.lineWidth = s * 0.045; g.strokeStyle = "#7a3d2a"; circle(g, x, y, s); g.stroke();
    cuteFace(g, x, y + s * 0.5, s * 0.5, "#7a3d2a");
  },
  cloud(g, x, y, s) {
    g.fillStyle = "rgba(40,30,80,0.18)"; g.beginPath(); g.ellipse(x, y + s * 0.85, s * 1.05, s * 0.15, 0, 0, Math.PI * 2); g.fill();
    g.fillStyle = "#ffffff";
    for (const [dx, dy, r] of [[-0.6, 0.15, 0.55], [0, -0.2, 0.7], [0.62, 0.12, 0.55], [0, 0.32, 0.55]]) { circle(g, x + dx * s, y + dy * s, r * s); g.fill(); }
    g.lineWidth = s * 0.045; g.strokeStyle = "#6b5fb0";
    for (const [dx, dy, r] of [[-0.6, 0.15, 0.55], [0, -0.2, 0.7], [0.62, 0.12, 0.55]]) { g.beginPath(); g.arc(x + dx * s, y + dy * s, r * s, Math.PI * 0.85, Math.PI * 2.15); g.stroke(); }
    g.beginPath(); g.moveTo(x - 1.12 * s, y + 0.3 * s); g.quadraticCurveTo(x, y + 1.0 * s, x + 1.14 * s, y + 0.3 * s); g.stroke();
    // sleeping face
    g.strokeStyle = "#6b5fb0"; g.lineWidth = s * 0.05;
    for (const sx of [-1, 1]) { g.beginPath(); g.arc(x + sx * 0.25 * s, y + 0.12 * s, 0.09 * s, 0.1 * Math.PI, 0.9 * Math.PI); g.stroke(); }
    g.fillStyle = "rgba(255,140,170,0.5)"; for (const sx of [-1, 1]) { g.beginPath(); g.ellipse(x + sx * 0.45 * s, y + 0.3 * s, 0.1 * s, 0.06 * s, 0, 0, Math.PI * 2); g.fill(); }
    text(g, "z", x + 0.85 * s, y - 0.75 * s, Math.round(s * 0.3), 900, "#6b5fb0");
    text(g, "z", x + 1.1 * s, y - 1.05 * s, Math.round(s * 0.22), 900, "#6b5fb0");
  }
};
function shade(hex, amt) {
  const n = parseInt(hex.slice(1), 16), f = (c) => Math.max(0, Math.min(255, Math.round(c + 255 * amt)));
  return "#" + [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => f(c).toString(16).padStart(2, "0")).join("");
}

/* ---------- display cards ---------- */
const CARDS = {
  hero: { title: ["Daily", "Affirmations"], series: "SERIES 01", tag: "Collect all 9 messages", kinds: "ALL 9 KINDS",
    bg1: "#8fbaf7", bg2: "#76a8f3", mascot: "capsule", base: "#2f6fd0", stroke: C.navy, shadow: "#163172",
    lineup: ICON_ORDER.map((ic, i) => ({ icon: ic, color: ICON_COLORS[i], base: ["#2f6fd0", "#5c94e3", "#1c4a94"][i % 3] })) },
  snack: { title: ["Snack", "Pals"], series: "SERIES 03", tag: "Sweet little friends", kinds: "ALL 6 KINDS",
    bg1: "#ffc9d6", bg2: "#ffb3c6", mascot: "donut", stroke: "#a3344f", shadow: "#6e1f33",
    lineup: ["heart", "star", "flower", "heart", "sun", "sparkle"].map((ic, i) => ({ icon: ic, color: ["#e9536a", "#f2a33a", "#f07fa0", "#d84b8f", "#f2a33a", "#e9536a"][i], base: ["#f59bb8", "#f7c66a", "#9be29b"][i % 3] })) },
  cloud: { title: ["Sleepy", "Clouds"], series: "SERIES 02", tag: "Soft and dreamy", kinds: "ALL 6 KINDS",
    bg1: "#c9c2f5", bg2: "#b8aff0", mascot: "cloud", stroke: "#4b3f99", shadow: "#2c2466",
    lineup: ["moon", "star", "sparkle", "moon", "rainbow", "star"].map((ic, i) => ({ icon: ic, color: ["#7d8fd6", "#f2c230", "#6aa3f2", "#9b7fd6", "#e9536a", "#f2c230"][i], base: ["#b8aff0", "#a8dcd1", "#ffffff"][i % 3] })) }
};

function paintCard(canvas, variant) {
  const v = CARDS[variant] || CARDS.hero;
  const W = 1024, H = 783, g = logical(canvas, W, H);
  // rays and a soft vignette, like a printed blister card
  sunburst(g, 300, 470, 22, 1400, v.bg1, v.bg2, 0.05);
  const vg = g.createRadialGradient(300, 430, 120, 300, 430, 900);
  vg.addColorStop(0, "rgba(255,255,255,0.35)"); vg.addColorStop(1, "rgba(0,0,0,0.12)");
  g.fillStyle = vg; g.fillRect(0, 0, W, H);
  halftone(g, 560, 0, 470, 260, 22, 7, "rgba(255,255,255,0.45)", "tr");
  halftone(g, 0, 470, 330, 220, 20, 6, "rgba(255,255,255,0.35)", "bl");
  // series pill
  g.fillStyle = v.stroke; rr(g, 34, 28, 190, 46, 23); g.fill();
  text(g, v.series, 129, 52, 24, 900, "#fff");
  // title, set at a slight hand-placed angle
  g.save(); g.translate(300, 168); g.rotate(-0.06);
  bigText(g, v.title[0], -20, -46, 104, "#ffffff", v.stroke, v.shadow, 20);
  bigText(g, v.title[1], 12, 52, v.title[1].length > 8 ? 86 : 104, "#ffffff", v.stroke, v.shadow, 20);
  g.restore();
  // tagline ribbon
  g.save(); g.translate(300, 285); g.rotate(-0.03);
  g.fillStyle = "#fff"; rr(g, -190, -24, 380, 48, 24); g.fill();
  g.lineWidth = 4; g.strokeStyle = v.stroke; g.stroke();
  text(g, v.tag, 0, 1, 27, 700, v.stroke); g.restore();
  // mascot and sparkles
  MASCOTS[v.mascot](g, 290, 520, 150, v.base || C.sky);
  const sr = rng(variant.length * 31 + 5);
  for (let i = 0; i < 7; i++) sparkle(g, 70 + sr() * 450, 330 + sr() * 330, 10 + sr() * 18, i % 2 ? "#fff" : C.yellow);
  // lineup panel
  const px = 566, py = 96, pw = 430, ph = 512;
  g.fillStyle = "rgba(0,0,0,0.14)"; rr(g, px + 8, py + 10, pw, ph, 26); g.fill();
  g.fillStyle = "#ffffff"; rr(g, px, py, pw, ph, 26); g.fill();
  g.lineWidth = 6; g.strokeStyle = v.stroke; g.stroke();
  g.fillStyle = v.stroke; rr(g, px + 24, py - 22, 230, 50, 25); g.fill();
  text(g, v.kinds, px + 139, py + 3, 26, 900, "#fff");
  const n = v.lineup.length, cols = 3, rows = Math.ceil(n / cols);
  const cellW = (pw - 40) / cols, cellH = (ph - 70) / rows;
  v.lineup.forEach((it, i) => {
    const cx = px + 20 + cellW * (i % cols) + cellW / 2, cy = py + 60 + cellH * Math.floor(i / cols) + cellH / 2 - 6;
    miniCapsule(g, cx, cy, Math.min(cellW, cellH) * 0.34, it.base, it.icon, it.color, i + 1);
  });
  // price burst
  g.save(); g.translate(930, 610); g.rotate(0.18);
  burst(g, 0, 0, 74, 14, C.yellow, v.stroke);
  text(g, "1", 0, -14, 46, 900, v.stroke); text(g, "TURN", 0, 26, 22, 900, v.stroke);
  g.restore();
  // fine print strip
  g.fillStyle = "#ffffff"; g.fillRect(0, H - 100, W, 100);
  g.fillStyle = v.stroke; g.fillRect(0, H - 100, W, 5);
  g.fillStyle = C.yellow; g.beginPath(); g.moveTo(52, H - 80); g.lineTo(82, H - 28); g.lineTo(22, H - 28); g.closePath(); g.fill();
  g.lineWidth = 3; g.strokeStyle = C.ink; g.stroke();
  text(g, "!", 52, H - 44, 28, 900, C.ink);
  text(g, "Contains small parts. Open the capsule with care.", 104, H - 72, 18, 700, "#4a4450", "left");
  g.fillStyle = "rgba(60,56,70,0.32)";
  const fr = rng(variant.length * 97 + 3);
  for (let i = 0; i < 3; i++) g.fillRect(104, H - 50 + i * 13, 420 + fr() * 160, 5);
  // age mark, barcode and maker mark
  g.lineWidth = 3; g.strokeStyle = C.ink; circle(g, 700, H - 50, 28); g.stroke();
  text(g, "15+", 700, H - 49, 20, 900, C.ink);
  g.fillStyle = C.ink;
  for (let i = 0, x = 752; i < 22 && x < 862; i++) { const w = [2, 3, 5][Math.floor(fr() * 3)]; g.fillRect(x, H - 82, w, 52); x += w + 2 + Math.floor(fr() * 3); }
  text(g, "Gotcha", 990, H - 50, 30, 900, v.stroke, "right");
}

/* ---------- printed face of the mechanism unit ---------- */
function paintFace(canvas, L) {
  const LCW = 1024, LCH = Math.round(1024 * L.LH / L.LW);
  const g = logical(canvas, LCW, LCH);
  g.clearRect(0, 0, LCW, LCH);
  const toX = (x) => (x + L.LW / 2) / L.LW * LCW, toY = (y) => (L.LY + L.LH / 2 - y) / L.LH * LCH, px = (u) => u / L.LW * LCW;
  const kx = toX(0), ky = toY(L.KNOB_Y);

  // moulded recess the dial sits in (the blue ring itself is 3D)
  const rWell = px(0.43);
  const well = g.createRadialGradient(kx, ky - rWell * 0.25, rWell * 0.2, kx, ky, rWell);
  well.addColorStop(0, "#e4ddcd"); well.addColorStop(0.8, "#d3cab6"); well.addColorStop(1, "#b9af99");
  g.fillStyle = well; circle(g, kx, ky, rWell); g.fill();
  // soft occlusion around the ring
  const ao = g.createRadialGradient(kx, ky, px(0.5), kx, ky, px(0.62));
  ao.addColorStop(0, "rgba(60,50,30,0.16)"); ao.addColorStop(1, "rgba(60,50,30,0)");
  g.fillStyle = ao; circle(g, kx, ky, px(0.62)); g.fill();

  // yellow turn-direction sticker: an arc that ends in an arrowhead (clockwise, like the handle)
  const rY = px(0.56), a0 = Math.PI * 0.62, a1 = Math.PI * 2.32;
  g.lineCap = "butt";
  g.strokeStyle = "rgba(80,60,0,0.22)"; g.lineWidth = px(0.05); g.beginPath(); g.arc(kx + 1.5, ky + 2.5, rY, a0, a1); g.stroke();
  g.strokeStyle = C.yellow; g.beginPath(); g.arc(kx, ky, rY, a0, a1); g.stroke();
  g.strokeStyle = "rgba(255,255,255,0.45)"; g.lineWidth = px(0.008); g.beginPath(); g.arc(kx, ky, rY - px(0.018), a0, a1); g.stroke();
  g.lineCap = "round";
  {
    const ax = kx + rY * Math.cos(a1), ay = ky + rY * Math.sin(a1), ang = a1 + Math.PI / 2, s = px(0.1);
    g.save(); g.translate(ax, ay); g.rotate(ang); g.fillStyle = C.yellow;
    g.beginPath(); g.moveTo(s, 0); g.lineTo(-s * 0.6, -s * 0.85); g.lineTo(-s * 0.6, s * 0.85); g.closePath(); g.fill(); g.restore();
  }
  // "start here" arrow
  g.fillStyle = C.blue;
  rr(g, kx - rY - px(0.24), ky - px(0.028), px(0.14), px(0.056), 4); g.fill();
  g.beginPath(); g.moveTo(kx - rY - px(0.04), ky); g.lineTo(kx - rY - px(0.12), ky - px(0.07)); g.lineTo(kx - rY - px(0.12), ky + px(0.07)); g.closePath(); g.fill();

  // COIN IN badge with an arrow toward the slot
  {
    const bx = toX(-0.46), by = toY(2.35), bw = px(0.88), bh = px(0.2);
    g.fillStyle = "rgba(0,0,0,0.12)"; rr(g, bx + 2, by + 4, bw, bh, bh / 2); g.fill();
    const bg = g.createLinearGradient(0, by, 0, by + bh); bg.addColorStop(0, "#3a63c0"); bg.addColorStop(1, C.blue);
    g.fillStyle = bg; rr(g, bx, by, bw, bh, bh / 2); g.fill();
    for (let i = 0; i < 3; i++) {
      const cx = bx + px(0.13) + i * px(0.065), cy = by + bh / 2, r = px(0.07);
      g.fillStyle = "#ffffff"; circle(g, cx, cy, r); g.fill();
      g.lineWidth = 3; g.strokeStyle = C.blue; g.stroke();
      g.strokeStyle = "rgba(42,79,168,0.35)"; g.lineWidth = 2; circle(g, cx, cy, r * 0.7); g.stroke();
    }
    text(g, "COIN IN", bx + px(0.34), by + bh / 2 + 1, Math.round(px(0.1)), 900, "#fff", "left");
    g.fillStyle = C.blue; g.beginPath();
    g.moveTo(bx + bw + px(0.13), by + bh / 2); g.lineTo(bx + bw + px(0.03), by + bh / 2 - px(0.06)); g.lineTo(bx + bw + px(0.03), by + bh / 2 + px(0.06)); g.closePath(); g.fill();
  }
  // coin badge and counter window, top left
  {
    const x = toX(-1.05), y = toY(2.36), s = px(0.26);
    g.fillStyle = C.blue; rr(g, x, y, s, s, 8); g.fill();
    g.fillStyle = "#fff"; circle(g, x + s / 2, y + s / 2, s * 0.33); g.fill();
    g.strokeStyle = C.blue; g.lineWidth = 2; circle(g, x + s / 2, y + s / 2, s * 0.25); g.stroke();
    text(g, "1", x + s / 2, y + s / 2 + 1, Math.round(s * 0.3), 900, C.blue);
    const wx = toX(-1.06), wy = toY(1.98), ww = px(0.4), wh = px(0.16);
    g.fillStyle = "#24272d"; rr(g, wx, wy, ww, wh, 6); g.fill();
    const lcd = g.createLinearGradient(0, wy, 0, wy + wh); lcd.addColorStop(0, "#6fe597"); lcd.addColorStop(1, "#2ea95b");
    g.fillStyle = lcd; rr(g, wx + 5, wy + 5, ww - 10, wh - 10, 4); g.fill();
    text(g, "1 TURN", wx + ww / 2, wy + wh / 2 + 1, Math.round(px(0.072)), 900, "#0c3a1d");
    g.fillStyle = "rgba(255,255,255,0.28)"; g.beginPath(); g.moveTo(wx + 5, wy + 5); g.lineTo(wx + ww * 0.55, wy + 5); g.lineTo(wx + ww * 0.35, wy + wh - 5); g.lineTo(wx + 5, wy + wh - 5); g.closePath(); g.fill();
  }
  // instruction sticker with a tiny diagram
  {
    const sx = toX(-1.06), sy = toY(1.52), sw = px(0.36), sh = px(0.36);
    g.fillStyle = "rgba(0,0,0,0.1)"; rr(g, sx + 2, sy + 3, sw, sh, 8); g.fill();
    g.fillStyle = "#ffffff"; rr(g, sx, sy, sw, sh, 8); g.fill();
    g.lineWidth = 3; g.strokeStyle = C.blue; g.stroke();
    const dx = sx + sw / 2, dy = sy + sh * 0.3, dr = sh * 0.16;
    g.strokeStyle = C.ink; g.lineWidth = 3; circle(g, dx, dy, dr); g.stroke();
    g.fillStyle = C.ink; rr(g, dx - dr * 0.85, dy - dr * 0.18, dr * 1.7, dr * 0.36, dr * 0.18); g.fill();
    g.strokeStyle = C.red; g.lineWidth = 4; g.beginPath(); g.arc(dx, dy, dr * 1.45, -0.9 * Math.PI, -0.15 * Math.PI); g.stroke();
    g.fillStyle = C.red; g.save(); g.translate(dx + dr * 1.45 * Math.cos(-0.15 * Math.PI), dy + dr * 1.45 * Math.sin(-0.15 * Math.PI)); g.rotate(-0.15 * Math.PI + Math.PI / 2);
    g.beginPath(); g.moveTo(9, 0); g.lineTo(-6, -8); g.lineTo(-6, 8); g.closePath(); g.fill(); g.restore();
    ["Turn the handle", "slowly, one", "full turn."].forEach((t, i) => text(g, t, dx, sy + sh * 0.6 + i * px(0.05), Math.round(px(0.04)), 700, C.ink));
  }
  // notice sticker
  {
    const nx = toX(0.58), ny = toY(1.32), nw = px(0.48), nh = px(0.46);
    g.fillStyle = "rgba(0,0,0,0.1)"; rr(g, nx + 2, ny + 3, nw, nh, 8); g.fill();
    g.fillStyle = "#ffffff"; rr(g, nx, ny, nw, nh, 8); g.fill();
    g.fillStyle = C.yellow; rr(g, nx + 7, ny + 7, nw - 14, 24, 4); g.fill();
    text(g, "NOTICE", nx + nw / 2, ny + 20, 17, 900, C.ink);
    const r = rng(41); g.fillStyle = "rgba(43,34,48,0.32)";
    for (let y = ny + 44; y < ny + nh - 10; y += 12) g.fillRect(nx + 12, y, (nw - 24) * (0.55 + 0.45 * r()), 4);
  }
  // coin return pocket
  {
    const x = toX(0.62), y = toY(0.72), w = px(0.24), h = px(0.32);
    const pg = g.createLinearGradient(0, y, 0, y + h); pg.addColorStop(0, "#b7ae9a"); pg.addColorStop(1, "#ddd6c6");
    g.fillStyle = pg; rr(g, x, y, w, h, 10); g.fill();
    g.fillStyle = "rgba(40,30,20,0.35)"; rr(g, x + w * 0.2, y + h * 0.18, w * 0.6, h * 0.5, 6); g.fill();
  }
  // dark take-out mouth behind the flap
  {
    const ex = toX(-L.EXIT_W / 2), ey = toY(L.EXIT_Y + L.EXIT_H / 2), ew = px(L.EXIT_W), eh = px(L.EXIT_H);
    rr(g, ex, ey, ew, eh, px(0.06));
    const dg = g.createLinearGradient(0, ey, 0, ey + eh); dg.addColorStop(0, "#050608"); dg.addColorStop(1, "#202329");
    g.fillStyle = dg; g.fill();
  }
  // years of hands: faint grime around the dial and the exit
  const gr = rng(1234);
  for (let i = 0; i < 40; i++) {
    const near = i < 24 ? [kx, ky + px(0.25), px(0.5)] : [toX(0), toY(L.EXIT_Y - 0.25), px(0.5)];
    const x = near[0] + (gr() - 0.5) * near[2] * 2, y = near[1] + (gr() - 0.5) * near[2], r = 8 + gr() * 26;
    const sm = g.createRadialGradient(x, y, 0, x, y, r); sm.addColorStop(0, "rgba(90,75,50,0.05)"); sm.addColorStop(1, "rgba(90,75,50,0)");
    g.fillStyle = sm; circle(g, x, y, r); g.fill();
  }
}

/* ---------- badge on the cap, moulding on the flap ---------- */
function paintBadge(canvas) {
  const w = 512, h = 114, g = logical(canvas, w, h);
  g.clearRect(0, 0, w, h);
  const bg = g.createLinearGradient(0, 0, 0, h); bg.addColorStop(0, "#ffffff"); bg.addColorStop(1, "#e9eef8");
  g.fillStyle = bg; rr(g, 6, 6, w - 12, h - 12, 20); g.fill();
  g.lineWidth = 7; g.strokeStyle = C.blue; g.stroke();
  g.font = `900 66px ${FONT}`; g.textAlign = "center"; g.textBaseline = "middle";
  g.fillStyle = "rgba(0,0,0,0.12)"; g.fillText("GOTCHA", w / 2 + 2, h / 2 + 6);
  g.fillStyle = C.blue; g.fillText("GOTCHA", w / 2, h / 2 + 3);
  g.fillStyle = "rgba(255,255,255,0.5)"; rr(g, 16, 12, w - 32, 18, 9); g.fill();
}
function paintFlap(canvas) {
  const w = 512, h = 440, g = logical(canvas, w, h);
  g.clearRect(0, 0, w, h);
  g.font = `900 124px ${FONT}`; g.textAlign = "center"; g.textBaseline = "middle";
  for (const [t, dy] of [["GOT", -66], ["CHA", 66]]) {
    g.fillStyle = "rgba(0,0,0,0.45)"; g.fillText(t, w / 2 + 3, h / 2 + dy + 4);
    g.fillStyle = "rgba(255,255,255,0.09)"; g.fillText(t, w / 2, h / 2 + dy);
  }
  const sheen = g.createLinearGradient(0, 0, w, h);
  sheen.addColorStop(0, "rgba(255,255,255,0.12)"); sheen.addColorStop(0.35, "rgba(255,255,255,0)"); sheen.addColorStop(1, "rgba(255,255,255,0.04)");
  g.fillStyle = sheen; g.fillRect(0, 0, w, h);
}

/* ---------- surfaces ---------- */
// Plastic grain: mid-grey noise for roughness and bump, with a few faint scratches.
function paintGrain(canvas) {
  const S = canvas.width, g = canvas.getContext("2d"), img = g.createImageData(S, S), d = img.data, r = rng(99);
  const N = 64, lat = new Float32Array(N * N).map(() => r());
  const at = (x, y) => lat[((y % N + N) % N) * N + ((x % N + N) % N)];
  const smooth = (t) => t * t * (3 - 2 * t);
  const vnoise = (x, y) => { const xi = Math.floor(x), yi = Math.floor(y), xf = smooth(x - xi), yf = smooth(y - yi);
    return (at(xi, yi) * (1 - xf) + at(xi + 1, yi) * xf) * (1 - yf) + (at(xi, yi + 1) * (1 - xf) + at(xi + 1, yi + 1) * xf) * yf; };
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    const u = x / S * N, v = y / S * N;
    const n = vnoise(u, v) * 0.5 + vnoise(u * 2.1, v * 2.1) * 0.3 + vnoise(u * 4.3, v * 4.3) * 0.2;
    const val = 108 + (n - 0.5) * 34 + (r() - 0.5) * 14;
    const i = (y * S + x) * 4; d[i] = d[i + 1] = d[i + 2] = val; d[i + 3] = 255;
  }
  g.putImageData(img, 0, 0);
  g.strokeStyle = "rgba(170,170,170,0.35)"; g.lineWidth = 1;
  for (let i = 0; i < 22; i++) { const x = r() * S, y = r() * S, a = r() * Math.PI, l = 20 + r() * 90;
    g.beginPath(); g.moveTo(x, y); g.lineTo(x + Math.cos(a) * l, y + Math.sin(a) * l); g.stroke(); }
}
// Large vinyl floor tiles with a terrazzo fleck.
function paintFloor(canvas) {
  const S = 1024, g = logical(canvas, S, S), r = rng(5), n = 4, t = S / n;
  for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
    const v = 214 + Math.round((r() - 0.5) * 10);
    g.fillStyle = `rgb(${v},${v + 1},${v + 3})`; g.fillRect(i * t, j * t, t, t);
  }
  for (let k = 0; k < 2600; k++) {
    const x = r() * S, y = r() * S, s = 0.6 + r() * 2.2, c = r();
    g.fillStyle = c < 0.5 ? "rgba(120,124,132,0.45)" : c < 0.8 ? "rgba(255,255,255,0.6)" : "rgba(180,160,130,0.45)";
    g.fillRect(x, y, s, s);
  }
  g.fillStyle = "rgba(170,172,176,0.7)";
  for (let i = 0; i <= n; i++) { g.fillRect(i * t - 1, 0, 2, S); g.fillRect(0, i * t - 1, S, 2); }
}
// Painted shop wall with a faint roller texture and a skirting board at the bottom of the image.
function paintWall(canvas) {
  const S = 1024, g = logical(canvas, S, S), r = rng(17);
  g.fillStyle = "#efece6"; g.fillRect(0, 0, S, S);
  for (let k = 0; k < 9000; k++) { const x = r() * S, y = r() * S; g.fillStyle = r() < 0.5 ? "rgba(255,255,255,0.35)" : "rgba(150,140,125,0.10)"; g.fillRect(x, y, 2, 2); }
  for (let k = 0; k < 40; k++) { const y = r() * S; g.fillStyle = "rgba(160,150,135,0.015)"; g.fillRect(0, y, S, 6 + r() * 20); }
}
// Equirectangular "shop" environment: rows of ceiling fluorescents, bright walls, darker floor.
function paintEnv(canvas) {
  const W = 1024, H = 512, g = logical(canvas, W, H);
  const sky = g.createLinearGradient(0, 0, 0, H);
  sky.addColorStop(0, "#bdbcb8"); sky.addColorStop(0.42, "#9f9e9a"); sky.addColorStop(0.5, "#86857f"); sky.addColorStop(0.58, "#5f5e5a"); sky.addColorStop(1, "#3c3b39");
  g.fillStyle = sky; g.fillRect(0, 0, W, H);
  g.fillStyle = "#ffffff";
  for (let row = 0; row < 4; row++) for (let i = 0; i < 6; i++) {
    const y = 26 + row * 34, x = i * (W / 6) + row * 40;
    g.globalAlpha = 1 - row * 0.15; g.fillRect(x % W, y, 110, 12);
  }
  g.globalAlpha = 1;
  // big soft window/softbox behind the viewer and one to the side
  for (const [x, y, w, h, a] of [[430, 150, 170, 110, 0.95], [120, 170, 120, 80, 0.6], [780, 175, 120, 70, 0.55]]) {
    const gr = g.createRadialGradient(x + w / 2, y + h / 2, 0, x + w / 2, y + h / 2, w * 0.75);
    gr.addColorStop(0, `rgba(255,255,255,${a})`); gr.addColorStop(1, "rgba(255,255,255,0)");
    g.fillStyle = gr; g.fillRect(x - w * 0.3, y - h * 0.3, w * 1.6, h * 1.6);
    g.fillStyle = `rgba(255,255,255,${a})`; rr(g, x, y, w, h, 10); g.fill();
  }
}
// Soft contact shadow: a rounded rectangle fading out, for under the machines.
function paintAO(canvas) {
  const S = 256, g = canvas.getContext("2d"), img = g.createImageData(S, S), d = img.data;
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    const u = Math.abs(x / (S - 1) * 2 - 1), v = Math.abs(y / (S - 1) * 2 - 1);
    const q = Math.max(0, Math.hypot(Math.max(0, u - 0.55), Math.max(0, v - 0.55)) / 0.45);
    const a = Math.pow(Math.max(0, 1 - q), 2.2);
    const i = (y * S + x) * 4; d[i] = d[i + 1] = d[i + 2] = 0; d[i + 3] = Math.round(a * 255);
  }
  g.putImageData(img, 0, 0);
}

const SIZES = {
  card: [2048, 1566], face: [2048, 2104], badge: [1024, 228], flap: [512, 440],
  grain: [512, 512], floor: [1024, 1024], wall: [1024, 1024], env: [1024, 512], ao: [256, 256]
};
function make(kind, arg) {
  const c = document.createElement("canvas");
  [c.width, c.height] = SIZES[kind];
  ({ card: () => paintCard(c, arg), face: () => paintFace(c, arg), badge: () => paintBadge(c), flap: () => paintFlap(c),
     grain: () => paintGrain(c), floor: () => paintFloor(c), wall: () => paintWall(c), env: () => paintEnv(c), ao: () => paintAO(c) })[kind]();
  return c;
}
function repaint(kind, canvas, arg) {
  ({ card: () => paintCard(canvas, arg), face: () => paintFace(canvas, arg), badge: () => paintBadge(canvas), flap: () => paintFlap(canvas) })[kind]();
}

root.GotchaTextures = { make, repaint, SIZES, CARDS: Object.keys(CARDS) };
})(window);
