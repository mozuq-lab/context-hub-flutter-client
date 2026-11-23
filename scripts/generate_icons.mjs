// アプリのアイコンを、1つの形の定義からMac・Androidの両方へ書き出す。
//
//   node scripts/generate_icons.mjs
//
// - Android: アダプティブアイコン（地とマーク）をベクターで書き出す。テーマアイコン（単色）には
//   マークをそのまま使う（端末が色を付け替え、透明度だけが残る）。
//   Android 7.x（API 24・25）向けの画像（mipmap-*/ic_launcher.png）も書き出す。
// - Mac: AppIcon.appiconsetの各サイズの画像を書き出す。小さいサイズは線を太くした形で描く。
//
// 画像（PNG）の描画にはPlaywrightのChromiumを使う。開発時だけの道具なので、
// package.jsonには入れていない。Playwrightが見つからないときは、何も書き換えずに止まる。
// 全部を描き終えてからファイルを書くので、途中で失敗しても新旧の画像が混ざらない。
// Playwright 1.63.0（Chromium headless shell 1243）で、何度書き出しても同じ画像になることを確かめた。
// 版が変わると、線の縁の描き方の差で画像の中身が少し変わることがある。
import { mkdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

// ---- 形の定義（1000×1000の枠、中心は500,500） --------------------------------
// 散らばったメモ（左の3本の線）が、1つの点（いまの文脈）にまとまる形。
const background = { from: '#6470E6', to: '#3A43B8' }; // 左上から右下への藍のグラデーション
// size: 'normal'（64px以上）、'small'（32px前後。線を太く）、
// 'tiny'（16px。上下の線を広げて濃くし、3本が1つの塊に見えないようにする）。
const mark = (size = 'normal') => {
  const tiny = size === 'tiny';
  const width = { normal: 64, small: 92, tiny: 120 }[size];
  const top = tiny ? 230 : 290, bottom = tiny ? 770 : 710, side = tiny ? 0.85 : 0.55;
  return [
    { kind: 'stroke', d: `M190,${top} C430,${top} 470,500 640,500`, width, alpha: side },
    { kind: 'stroke', d: `M190,${bottom} C430,${bottom} 470,500 640,500`, width, alpha: side },
    { kind: 'stroke', d: 'M190,500 L640,500', width, alpha: 1 },
    { kind: 'circle', cx: 720, cy: 500, r: { normal: 92, small: 112, tiny: 130 }[size], alpha: 1 },
  ];
};
const markColor = '#FFFFFF';

// ---- SVG --------------------------------------------------------------------
// macOSの角の形（連続的な曲率の角丸）に近い超楕円。
function superellipse(x, y, size, n = 5, steps = 720) {
  const a = size / 2, cx = x + a, cy = y + a;
  let d = '';
  for (let i = 0; i < steps; i++) {
    const t = (i / steps) * Math.PI * 2, c = Math.cos(t), s = Math.sin(t);
    const px = cx + a * Math.sign(c) * Math.abs(c) ** (2 / n);
    const py = cy + a * Math.sign(s) * Math.abs(s) ** (2 / n);
    d += `${i ? 'L' : 'M'}${px.toFixed(2)},${py.toFixed(2)}`;
  }
  return `${d}Z`;
}

const svgMark = (size) => mark(size).map((m) => m.kind === 'stroke'
  ? `<path d="${m.d}" fill="none" stroke="${markColor}" stroke-width="${m.width}" stroke-linecap="round" opacity="${m.alpha}"/>`
  : `<circle cx="${m.cx}" cy="${m.cy}" r="${m.r}" fill="${markColor}" opacity="${m.alpha}"/>`).join('');

const svgBackground = `<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">`
  + `<stop offset="0" stop-color="${background.from}"/><stop offset="1" stop-color="${background.to}"/>`
  + `</linearGradient></defs><rect width="1000" height="1000" fill="url(#bg)"/>`;

// Macのアイコン: 1024の枠に824の本体（Appleのアイコンの格子）と下向きの影。
function macSvg(size) {
  const body = superellipse(100, 100, 824);
  const small = size <= 32;
  const variant = size <= 16 ? 'tiny' : small ? 'small' : 'normal';
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 1024 1024">`
    + `<defs><clipPath id="clip"><path d="${body}"/></clipPath>`
    + `<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">`
    + `<feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity="0.28"/></filter></defs>`
    // 16・32pxでは影が灰色の縁に見えるため描かない。
    + (small ? '' : `<path d="${body}" fill="#000" filter="url(#shadow)"/>`)
    + `<g clip-path="url(#clip)"><g transform="translate(100,100) scale(0.824)">${svgBackground}${svgMark(variant)}</g></g>`
    + `</svg>`;
}

// Android 7.x向け: 角丸の四角に収めた、影のない画像。
function legacySvg(size) {
  const body = superellipse(48, 48, 928, 4.2);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 1024 1024">`
    + `<defs><clipPath id="clip"><path d="${body}"/></clipPath></defs>`
    + `<g clip-path="url(#clip)"><g transform="translate(48,48) scale(0.928)">${svgBackground}${svgMark(size <= 72 ? 'small' : 'normal')}</g></g>`
    + `</svg>`;
}

// ---- Androidのベクター --------------------------------------------------------
// アダプティブアイコンは108dpの枠で、どの形に切り抜かれても欠けないのは中心の直径66dp。
// マークは1000の枠を0.62倍して置く（中心から一番遠い上下の線の端でも約27dp）。
// ベクターに書く値と中心の位置がずれないよう、丸めた拡大率から平行移動を出す。
const scale = Number(((108 * 0.62) / 1000).toFixed(4));
const shift = 54 - 500 * scale;
const n = (v) => Number(v.toFixed(4)).toString();
const circlePath = (cx, cy, r) => `M${cx - r},${cy}a${r},${r} 0,1 1,${2 * r},0a${r},${r} 0,1 1,${-2 * r},0`;

function vectorMark() {
  const color = markColor;
  const items = mark().map((m) => m.kind === 'stroke'
    ? `        <path\n            android:pathData="${m.d}"\n            android:strokeColor="${color}"\n            android:strokeAlpha="${m.alpha}"\n            android:strokeWidth="${m.width}"\n            android:strokeLineCap="round" />`
    : `        <path\n            android:pathData="${circlePath(m.cx, m.cy, m.r)}"\n            android:fillColor="${color}"\n            android:fillAlpha="${m.alpha}" />`).join('\n');
  return `<?xml version="1.0" encoding="utf-8"?>
<!-- scripts/generate_icons.mjs が書き出す。直接編集しない。 -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <group
        android:scaleX="${n(scale)}"
        android:scaleY="${n(scale)}"
        android:translateX="${n(shift)}"
        android:translateY="${n(shift)}">
${items}
    </group>
</vector>
`;
}

const vectorBackground = `<?xml version="1.0" encoding="utf-8"?>
<!-- scripts/generate_icons.mjs が書き出す。直接編集しない。 -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="0"
                android:startY="0"
                android:endX="108"
                android:endY="108"
                android:startColor="${background.from}"
                android:endColor="${background.to}" />
        </aapt:attr>
    </path>
</vector>
`;

const adaptiveIcon = `<?xml version="1.0" encoding="utf-8"?>
<!-- scripts/generate_icons.mjs が書き出す。直接編集しない。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>
`;

// ---- 書き出し -------------------------------------------------------------------
let playwright;
try {
  // グローバルに入れたPlaywright（NODE_PATH）も見つけられるよう、requireで読む。
  playwright = createRequire(import.meta.url)('playwright');
} catch {
  console.error('Playwrightが見つからないため、何も書き出していません。');
  process.exit(1);
}

const res = 'android/app/src/main/res';
const files = [
  [`${res}/mipmap-anydpi-v26/ic_launcher.xml`, adaptiveIcon],
  [`${res}/drawable/ic_launcher_background.xml`, vectorBackground],
  [`${res}/drawable/ic_launcher_foreground.xml`, vectorMark()],
];
const browser = await playwright.chromium.launch();
try {
  const page = await browser.newPage({ deviceScaleFactor: 1 });
  const png = async (svg, size) => {
    await page.setViewportSize({ width: size, height: size });
    await page.setContent(`<html><body style="margin:0">${svg}</body></html>`);
    return page.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
  };
  for (const size of [16, 32, 64, 128, 256, 512, 1024]) {
    files.push([`macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png`, await png(macSvg(size), size)]);
  }
  for (const [density, size] of [['mdpi', 48], ['hdpi', 72], ['xhdpi', 96], ['xxhdpi', 144], ['xxxhdpi', 192]]) {
    files.push([`${res}/mipmap-${density}/ic_launcher.png`, await png(legacySvg(size), size)]);
  }
} finally {
  await browser.close();
}

for (const [path, data] of files) {
  const full = join(root, path);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, data);
}
