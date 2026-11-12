#!/usr/bin/env node
// Renders the scenes of the guide's map pictures (tools/guide/README.md, "The map pictures").
//
//   node tools/guide/maps/render.mjs            from the repository root, after `npm ci` in tools/guide/maps
//
// A scene (app/test_shots/guide/scenes/<scene>.json, written by app/test_shots/guide_shots_test.dart with GUIDE_MAPS=export) is
// the app's own map style, a camera, a size, the GeoJSON the Maps screen put on the map and the images it added. Each scene is
// drawn with MapLibre GL JS in headless Chrome and saved as app/test_shots/guide_maps/<theme>/<scene>.png; the scene's SHA-256
// goes into app/test_shots/guide_maps/scenes.lock.json, and a scene whose picture is already there with the same SHA-256 is not
// rendered again (and asks for nothing).
//
// The style is used as the app made it. Only its addresses are replaced: the test's stand-in tile address of each layer by this
// script's own server on 127.0.0.1, and the fonts by the app's own glyph files (app/assets/map/fonts). The page never talks to
// another host. This script fetches the tiles itself, from the sources sources.json names: the app's published catalogue says
// where the base map and public lands archives are (PMTiles, read by byte range), and elevation comes from the public tile
// address the app's hillshade uses. Every request is counted per host, a host that is not listed is refused, and the run fails
// above the ceilings in sources.json. The counts are printed at the end.
//
// The step fails (and no picture is noted as rendered) when: WebGL does not start, a tile cannot be fetched, the style names a
// font the app does not ship or no font file was read, a picture is blank, or the map reports an error. With
// GUIDE_MAPS_MAP_ERRORS=warn the map's own error reports are printed and kept in the report but do not fail the step (for
// looking at what a new style or a new MapLibre says, with the pictures in hand).

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { brotliDecompressSync, gunzipSync } from 'node:zlib';

import { chromium } from 'playwright-core';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../../..');
const SCENES = join(ROOT, 'app/test_shots/guide/scenes');
const OUT = join(ROOT, 'app/test_shots/guide_maps');
const LOCK = join(OUT, 'scenes.lock.json');
const REPORT = join(SCENES, 'render-report.json');
const FONTS = join(ROOT, 'app/assets/map/fonts');
const MAPLIBRE = join(HERE, 'node_modules/maplibre-gl/dist');

// The app adds its images (the heading marker, the pins) to the map as PNGs, and the phone's map draws an image at its pixels
// divided by the screen's own scale. The pictures stand for a 3x phone (430 x 932 points), whatever scale they are drawn at.
// The app draws its pin images for the screen it is on, so the guide test tells it this same scale (kGuidePhoneScale in
// app/test_shots/guide_map_kit.dart): the two numbers go together.
const IMAGE_PIXEL_RATIO = 3;

const config = JSON.parse(readFileSync(join(HERE, 'sources.json'), 'utf8'));
const MAP_ERRORS_FAIL = process.env.GUIDE_MAPS_MAP_ERRORS !== 'warn';

// The same form as the app's own requests (Cache/<version>, packages/cache_search/native/cache_layers/src/http.rs).
const USER_AGENT = `Cache/${/^version\s*=\s*"([^"]+)"/m.exec(readFileSync(join(ROOT, 'packages/cache_search/native/cache_layers/Cargo.toml'), 'utf8'))?.[1] ?? '0'} guide-maps`;

/** What went wrong, in order; any entry fails the run. */
const problems = [];
const problem = (text) => {
  if (!problems.includes(text)) problems.push(text);
  console.error(`PROBLEM: ${text}`);
};

// ---- requests to outside hosts: counted, capped, and only to the listed hosts ---------------------------------------

const counts = new Map();
const elevationHosts = new Set(Object.values(config.layers).filter((l) => l.elevation).map((l) => new URL(l.url.replace(/[{}]/g, '')).host));
const totalRequests = () => [...counts.values()].reduce((a, b) => a + b, 0);

async function outside(url, headers = {}) {
  let at = url;
  for (let hop = 0; hop < 3; hop++) {
    const host = new URL(at).host;
    if (!config.hosts.includes(host)) throw new Error(`refused a request to ${host}: it is not a host in sources.json`);
    if (totalRequests() + 1 > config.limits.total) throw new Error(`the ceiling of ${config.limits.total} requests is reached`);
    if (elevationHosts.has(host) && (counts.get(host) ?? 0) + 1 > config.limits.elevation) {
      throw new Error(`the ceiling of ${config.limits.elevation} requests to the elevation host ${host} is reached`);
    }
    counts.set(host, (counts.get(host) ?? 0) + 1);
    const res = await fetch(at, { headers: { 'User-Agent': USER_AGENT, ...headers }, redirect: 'manual', signal: AbortSignal.timeout(60000) });
    if (res.status >= 300 && res.status < 400 && res.headers.get('location')) {
      at = new URL(res.headers.get('location'), at).href;
      continue;
    }
    return res;
  }
  throw new Error(`too many redirects from ${url}`);
}

/** One more try after a short wait when the host is busy or the connection drops (each try is counted). */
async function outsideTwice(url, headers = {}) {
  try {
    const res = await outside(url, headers);
    if (res.status < 500 && res.status !== 429) return res;
  } catch (e) {
    if (/refused a request|ceiling/.test(String(e.message))) throw e;
  }
  await new Promise((r) => setTimeout(r, 1500));
  return outside(url, headers);
}

// ---- PMTiles (version 3) by byte range --------------------------------------------------------------------------------

function unpack(buf, compression, what) {
  if (compression === 2) return gunzipSync(buf);
  if (compression === 3) return brotliDecompressSync(buf);
  if (compression === 0 || compression === 1) return buf;
  throw new Error(`${what}: compression ${compression} is not read here`);
}

function readDirectory(buf) {
  let pos = 0;
  const varint = () => {
    let result = 0;
    let scale = 1;
    for (;;) {
      const b = buf[pos++];
      result += (b & 0x7f) * scale;
      if (b < 0x80) return result;
      scale *= 128;
    }
  };
  const n = varint();
  const ids = new Array(n);
  const runs = new Array(n);
  const lengths = new Array(n);
  const offsets = new Array(n);
  let last = 0;
  for (let i = 0; i < n; i++) {
    last += varint();
    ids[i] = last;
  }
  for (let i = 0; i < n; i++) runs[i] = varint();
  for (let i = 0; i < n; i++) lengths[i] = varint();
  for (let i = 0; i < n; i++) {
    const v = varint();
    offsets[i] = v === 0 && i > 0 ? offsets[i - 1] + lengths[i - 1] : v - 1;
  }
  return { ids, runs, lengths, offsets };
}

/** The tile's place in the archive's order: the tiles of the zooms before it, then its place on the zoom's Hilbert curve. */
function tileId(z, x, y) {
  const n = 2 ** z;
  let d = 0;
  for (let s = n / 2; s >= 1; s /= 2) {
    const rx = (x & s) > 0 ? 1 : 0;
    const ry = (y & s) > 0 ? 1 : 0;
    d += s * s * ((3 * rx) ^ ry);
    if (ry === 0) {
      if (rx === 1) {
        x = n - 1 - x;
        y = n - 1 - y;
      }
      [x, y] = [y, x];
    }
  }
  return (4 ** z - 1) / 3 + d;
}

class Archive {
  constructor(url) {
    this.url = url;
    this.leaves = new Map();
  }

  async range(offset, length, exact = true) {
    const res = await outsideTwice(this.url, { Range: `bytes=${offset}-${offset + length - 1}`, 'Accept-Encoding': 'identity' });
    if (res.status !== 206) throw new Error(`${this.url}: HTTP ${res.status} for bytes ${offset}-${offset + length - 1}`);
    const buf = Buffer.from(await res.arrayBuffer());
    if (exact && buf.length !== length) throw new Error(`${this.url}: ${buf.length} of ${length} bytes came`);
    return buf;
  }

  async open() {
    const head = await this.range(0, 16384, false);
    if (head.length < 127 || head.subarray(0, 7).toString('latin1') !== 'PMTiles' || head[7] !== 3) throw new Error(`${this.url} is not a PMTiles version 3 archive`);
    const u64 = (at) => Number(head.readBigUInt64LE(at));
    const rootOffset = u64(8);
    const rootLength = u64(16);
    this.leafOffset = u64(40);
    this.dataOffset = u64(56);
    this.internalCompression = head[97];
    this.tileCompression = head[98];
    this.tileType = head[99];
    this.minZoom = head[100];
    this.maxZoom = head[101];
    const root = rootOffset + rootLength <= head.length ? head.subarray(rootOffset, rootOffset + rootLength) : await this.range(rootOffset, rootLength);
    this.root = readDirectory(unpack(root, this.internalCompression, this.url));
  }

  /** The tile's bytes as the archive holds them unpacked, or null when the archive has no such tile. */
  async tile(z, x, y) {
    if (z < this.minZoom || z > this.maxZoom) return null;
    const id = tileId(z, x, y);
    let dir = this.root;
    for (let depth = 0; depth < 4; depth++) {
      let lo = 0;
      let hi = dir.ids.length - 1;
      let at = -1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (dir.ids[mid] <= id) {
          at = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      if (at < 0) return null;
      if (dir.runs[at] === 0) {
        const key = `${dir.offsets[at]}+${dir.lengths[at]}`;
        if (!this.leaves.has(key)) {
          this.leaves.set(key, this.range(this.leafOffset + dir.offsets[at], dir.lengths[at]).then((b) => readDirectory(unpack(b, this.internalCompression, this.url))));
        }
        dir = await this.leaves.get(key);
        continue;
      }
      if (id - dir.ids[at] >= dir.runs[at]) return null;
      return unpack(await this.range(this.dataOffset + dir.offsets[at], dir.lengths[at]), this.tileCompression, this.url);
    }
    throw new Error(`${this.url}: the directories are nested too deep`);
  }
}

// ---- where each layer's tiles come from ---------------------------------------------------------------------------------

let catalogue = null;
const archives = new Map();
const tiles = new Map();
const tilesAsked = [];

async function catalogueLayer(id) {
  if (!catalogue) {
    catalogue = (async () => {
      const res = await outsideTwice(config.catalogue);
      if (res.status !== 200) throw new Error(`${config.catalogue}: HTTP ${res.status}`);
      return res.json();
    })();
  }
  const entry = ((await catalogue).layers ?? []).find((l) => l.id === id);
  if (!entry) throw new Error(`the published catalogue has no layer "${id}"`);
  if (entry.source?.type !== 'pmtiles' || !entry.source?.url) throw new Error(`the catalogue's "${id}" is not a PMTiles archive`);
  return entry;
}

async function archiveOf(id) {
  if (!archives.has(id)) {
    archives.set(id, (async () => {
      const entry = await catalogueLayer(id);
      const a = new Archive(entry.source.url);
      await a.open();
      console.log(`  ${id}: ${entry.source.url} (zoom ${a.minZoom} to ${a.maxZoom})`);
      return a;
    })());
  }
  return archives.get(id);
}

/** A tile for the page: { status, type, body }. Kept, so a tile two scenes share is fetched once. */
function tileOf(layer, z, x, y) {
  const key = `${layer}/${z}/${x}/${y}`;
  if (!tiles.has(key)) {
    tilesAsked.push(key);
    tiles.set(key, (async () => {
      const source = config.layers[layer];
      if (!source) throw new Error(`sources.json does not say where "${layer}" comes from`);
      if (source.from === 'catalogue') {
        const a = await archiveOf(layer);
        const body = await a.tile(z, x, y);
        // No such tile in the archive (nothing is there): an empty vector tile.
        return { status: 200, type: a.tileType === 1 ? 'application/x-protobuf' : 'application/octet-stream', body: body ?? Buffer.alloc(0) };
      }
      const res = await outsideTwice(source.url.replace('{z}', z).replace('{x}', x).replace('{y}', y));
      if (res.status !== 200) throw new Error(`${layer} tile ${z}/${x}/${y}: HTTP ${res.status}`);
      return { status: 200, type: res.headers.get('content-type') ?? 'application/octet-stream', body: Buffer.from(await res.arrayBuffer()) };
    })());
  }
  return tiles.get(key);
}

// ---- the local server the page reads from -------------------------------------------------------------------------------

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8">
<link rel="stylesheet" href="/lib/maplibre-gl.css">
<style>html, body { margin: 0; padding: 0; background: #fff; } #map { position: absolute; left: 0; top: 0; }</style>
<script src="/lib/maplibre-gl.js"></script>
</head><body><div id="map"></div></body></html>`;

const glyphsRead = new Set();
const glyphsMissing = new Set();

function serve() {
  const server = createServer(async (req, res) => {
    const send = (status, type, body) => {
      res.writeHead(status, { 'Content-Type': type, 'Content-Length': body.length, 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-store' });
      res.end(body);
    };
    try {
      const path = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname);
      if (path === '/') return send(200, 'text/html; charset=utf-8', Buffer.from(PAGE));
      if (path === '/lib/maplibre-gl.js') return send(200, 'text/javascript; charset=utf-8', readFileSync(join(MAPLIBRE, 'maplibre-gl.js')));
      if (path === '/lib/maplibre-gl.css') return send(200, 'text/css; charset=utf-8', readFileSync(join(MAPLIBRE, 'maplibre-gl.css')));
      let m = /^\/fonts\/([A-Za-z0-9 _-]+)\/(\d+-\d+)\.pbf$/.exec(path);
      if (m) {
        const [, stack, range] = m;
        if (!existsSync(join(FONTS, stack))) {
          problem(`the style names the font "${stack}", which is not in app/assets/map/fonts`);
          return send(404, 'text/plain', Buffer.from('no such font'));
        }
        const file = join(FONTS, stack, `${range}.pbf`);
        if (!existsSync(file)) {
          // The app ships three ranges of each font. A label with a character outside them is drawn without that character on
          // a phone; an empty range does the same here.
          glyphsMissing.add(`${stack} ${range}`);
          return send(200, 'application/x-protobuf', Buffer.alloc(0));
        }
        glyphsRead.add(`${stack} ${range}`);
        return send(200, 'application/x-protobuf', readFileSync(file));
      }
      m = /^\/t\/([a-z0-9_-]+)\/(\d+)\/(\d+)\/(\d+)$/.exec(path);
      if (m) {
        const t = await tileOf(m[1], Number(m[2]), Number(m[3]), Number(m[4]));
        return send(t.status, t.type, t.body);
      }
      return send(404, 'text/plain', Buffer.from('not here'));
    } catch (e) {
      problem(`${req.url}: ${e.message}`);
      return send(502, 'text/plain', Buffer.from(String(e.message)));
    }
  });
  return new Promise((done) => server.listen(0, '127.0.0.1', () => done(server)));
}

// ---- a scene's style, with this run's addresses ---------------------------------------------------------------------------

function styleOf(scene, base) {
  const style = structuredClone(scene.style);
  style.glyphs = `${base}/fonts/{fontstack}/{range}.pbf`;
  const data = scene.sources ?? {};
  for (const id of Object.keys(data)) {
    if (style.sources?.[id]?.type !== 'geojson') throw new Error(`the scene sets "${id}", which is not a GeoJSON source of its style`);
  }
  for (const [id, source] of Object.entries(style.sources ?? {})) {
    if (source.type === 'geojson') {
      if (data[id]) source.data = data[id];
      continue;
    }
    const address = Array.isArray(source.tiles) ? source.tiles[0] : '';
    const m = /\/layers\/([a-z0-9_-]+)\/\{z\}\/\{x\}\/\{y\}/.exec(address ?? '');
    if (!m) throw new Error(`source "${id}" is not at one of the app's tile addresses: ${address || source.url}`);
    if (!config.layers[m[1]]) throw new Error(`the style draws "${m[1]}", and sources.json does not say where it comes from`);
    source.tiles = [`${base}/t/${m[1]}/{z}/{x}/{y}`];
  }
  return style;
}

// ---- the page's side: draw one scene and hand back its picture --------------------------------------------------------------

/* global maplibregl, document, window, atob, Blob, createImageBitmap */
async function drawScene({ scene, style, imagePixelRatio, wait }) {
  const errors = [];
  const mapErrors = [];
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const el = document.getElementById('map');
  el.style.width = `${scene.width}px`;
  el.style.height = `${scene.height}px`;

  const images = {};
  for (const [name, b64] of Object.entries(scene.images ?? {})) {
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    images[name] = await createImageBitmap(new Blob([bytes], { type: 'image/png' }));
  }

  let map;
  try {
    map = new maplibregl.Map({
      container: el,
      style,
      center: [scene.camera.lon, scene.camera.lat],
      zoom: scene.camera.zoom,
      bearing: scene.camera.bearing ?? 0,
      pitch: 0,
      interactive: false,
      attributionControl: false,
      fadeDuration: 0,
      pixelRatio: scene.pixelRatio,
      preserveDrawingBuffer: true,
      canvasContextAttributes: { preserveDrawingBuffer: true },
      localIdeographFontFamily: false,
      refreshExpiredTiles: false,
    });
  } catch (e) {
    return { errors: [`the map did not start: ${e.message}`], mapErrors };
  }
  let idles = 0;
  map.on('idle', () => {
    idles++;
  });
  map.on('error', (e) => mapErrors.push(String(e?.error?.message ?? e?.error ?? e?.message ?? 'a map error')));
  const add = (name) => {
    if (images[name] && !map.hasImage(name)) map.addImage(name, images[name], { pixelRatio: imagePixelRatio });
  };
  map.on('styleimagemissing', (e) => {
    if (images[e.id]) add(e.id);
    else errors.push(`the style asks for the image "${e.id}", which the scene does not have`);
  });

  const until = async (test, ms, what) => {
    const end = Date.now() + ms;
    while (!test()) {
      if (Date.now() > end) {
        errors.push(what);
        return false;
      }
      await sleep(50);
    }
    return true;
  };
  let loaded = false;
  map.once('load', () => {
    loaded = true;
  });
  if (await until(() => loaded, wait, 'the style did not load')) {
    for (const name of Object.keys(images)) add(name);
    // At rest: every tile is in, the labels are placed and nothing is left to draw. Then once more after a repaint, so images
    // added late are in the picture.
    if (await until(() => idles > 0 && map.loaded() && map.areTilesLoaded(), wait, 'the map did not come to rest')) {
      const seen = idles;
      map.triggerRepaint();
      await until(() => idles > seen && map.loaded() && map.areTilesLoaded(), wait, 'the map did not come to rest after a repaint');
    }
  }

  // The picture is copied off the map's own canvas as a frame ends, so it is exactly what was drawn.
  const canvas = map.getCanvas();
  const copy = document.createElement('canvas');
  copy.width = canvas.width;
  copy.height = canvas.height;
  const ctx = copy.getContext('2d', { willReadFrequently: true });
  await new Promise((done) => {
    map.once('render', () => {
      ctx.drawImage(canvas, 0, 0);
      done();
    });
    map.triggerRepaint();
  });
  const pixels = ctx.getImageData(0, 0, copy.width, copy.height).data;
  const colours = new Set();
  for (let i = 0; i < pixels.length && colours.size < 4096; i += 4 * 7) colours.add((pixels[i] << 16) | (pixels[i + 1] << 8) | pixels[i + 2]);
  const png = copy.toDataURL('image/png');
  map.remove();
  return { errors, mapErrors, png, width: copy.width, height: copy.height, colours: colours.size };
}

/** Whether a page of this browser gets a WebGL context, and from what. */
async function webgl(page) {
  return page.evaluate(() => {
    const c = document.createElement('canvas');
    const gl = c.getContext('webgl2') ?? c.getContext('webgl');
    if (!gl) return null;
    const info = gl.getExtension('WEBGL_debug_renderer_info');
    return String(info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER));
  });
}

// ---- the run ----------------------------------------------------------------------------------------------------------------

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

function chromePath() {
  const tried = [process.env.CHROME_BIN, '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser'].filter(Boolean);
  const found = tried.find((p) => existsSync(p));
  if (!found) throw new Error(`no Chrome on this machine (looked at ${tried.join(', ')}); set CHROME_BIN`);
  return found;
}

/** Chrome with software WebGL: the first set of switches that gives a page a WebGL context. */
async function launch() {
  const executablePath = chromePath();
  const sets = [
    ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'],
    ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'],
    ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'],
    ['--ignore-gpu-blocklist'],
    [],
  ];
  for (const args of sets) {
    let browser;
    try {
      browser = await chromium.launch({ executablePath, headless: true, args });
      const page = await browser.newPage();
      const renderer = await webgl(page);
      await page.close();
      if (renderer) {
        console.log(`Chrome ${browser.version()} at ${executablePath}, WebGL by ${renderer} (${args.join(' ') || 'no switches'})`);
        return browser;
      }
      console.log(`no WebGL with: ${args.join(' ') || 'no switches'}`);
    } catch (e) {
      console.log(`Chrome did not start with: ${args.join(' ') || 'no switches'} (${String(e.message).split('\n')[0]})`);
    }
    await browser?.close();
  }
  throw new Error('headless Chrome gave no WebGL context, so no map can be drawn');
}

function printCounts() {
  const total = totalRequests();
  console.log('\nRequests to outside hosts:');
  for (const [host, n] of [...counts.entries()].sort()) console.log(`  ${host.padEnd(28)} ${String(n).padStart(4)}${elevationHosts.has(host) ? `   (elevation, ceiling ${config.limits.elevation})` : ''}`);
  console.log(`  ${'total'.padEnd(28)} ${String(total).padStart(4)}   (ceiling ${config.limits.total})`);
  return total;
}

async function main() {
  if (!existsSync(SCENES)) throw new Error(`no scenes at ${SCENES}: run the guide test with GUIDE_MAPS=export first`);
  const names = readdirSync(SCENES).filter((f) => f.endsWith('.json') && f !== 'index.json' && f !== 'render-report.json').sort();
  if (!names.length) throw new Error(`no scenes in ${SCENES}`);
  const index = existsSync(join(SCENES, 'index.json')) ? JSON.parse(readFileSync(join(SCENES, 'index.json'), 'utf8')) : null;
  const lock = existsSync(LOCK) ? JSON.parse(readFileSync(LOCK, 'utf8')) : {};
  const report = { userAgent: USER_AGENT, scenes: {} };

  const todo = [];
  for (const name of names) {
    const bytes = readFileSync(join(SCENES, name));
    const hash = sha256(bytes);
    const scene = JSON.parse(bytes.toString('utf8'));
    if (index && index[scene.scene] !== hash) throw new Error(`${name} is not the scene the test wrote (its SHA-256 is not the one in index.json)`);
    const key = `${scene.theme}/${scene.scene}`;
    const file = join(OUT, scene.theme, `${scene.scene}.png`);
    if (lock[key] === hash && existsSync(file)) {
      console.log(`${key}: already rendered from this scene`);
      report.scenes[key] = { sha256: hash, rendered: false };
      continue;
    }
    todo.push({ key, hash, scene, file });
  }

  if (todo.length) {
    console.log(`MapLibre GL JS ${JSON.parse(readFileSync(join(MAPLIBRE, '../package.json'), 'utf8')).version}, Node ${process.version}, requests as "${USER_AGENT}"`);
    const server = await serve();
    const base = `http://127.0.0.1:${server.address().port}`;
    const browser = await launch();
    try {
      for (const { key, hash, scene, file } of todo) {
        const before = tilesAsked.length;
        const context = await browser.newContext({ viewport: { width: Math.ceil(scene.width), height: Math.ceil(scene.height) }, deviceScaleFactor: scene.pixelRatio });
        // The page reads from this script's server only.
        await context.route('**/*', (route) => {
          const url = route.request().url();
          if (url.startsWith(`${base}/`) || url.startsWith('data:') || url.startsWith('blob:')) return route.continue();
          problem(`${key}: the page asked for ${url}`);
          return route.abort();
        });
        const page = await context.newPage();
        page.on('pageerror', (e) => problem(`${key}: ${e.message}`));
        page.on('console', (m) => {
          if (m.type() === 'error' || m.type() === 'warning') console.log(`  [page ${m.type()}] ${m.text()}`);
        });
        let result;
        try {
          await page.goto(`${base}/`, { waitUntil: 'load' });
          result = await page.evaluate(drawScene, { scene, style: styleOf(scene, base), imagePixelRatio: IMAGE_PIXEL_RATIO, wait: 120000 });
        } catch (e) {
          result = { errors: [String(e.message).split('\n')[0]] };
        }
        await context.close();

        const errors = [...(result.errors ?? [])];
        const said = [...new Set(result.mapErrors ?? [])];
        for (const e of said) {
          if (MAP_ERRORS_FAIL) errors.push(`the map said: ${e}`);
          else console.log(`  WARNING, the map said: ${e}`);
        }
        const asked = tilesAsked.slice(before);
        const width = Math.round(scene.width * scene.pixelRatio);
        const height = Math.round(scene.height * scene.pixelRatio);
        if (result.png) {
          if (result.width !== width || result.height !== height) errors.push(`the picture is ${result.width} x ${result.height}, not ${width} x ${height}`);
          if (result.colours < 32) errors.push(`the picture is blank (${result.colours} colours)`);
          mkdirSync(dirname(file), { recursive: true });
          writeFileSync(file, Buffer.from(result.png.slice(result.png.indexOf(',') + 1), 'base64'));
        }
        report.scenes[key] = { sha256: hash, rendered: errors.length === 0, colours: result.colours, newTiles: asked, errors, mapSaid: said };
        if (errors.length) {
          for (const e of errors) problem(`${key}: ${e}`);
        } else {
          lock[key] = hash;
          console.log(`${key}: ${width} x ${height}, zoom ${Number(scene.camera.zoom).toFixed(2)}, ${result.colours}${result.colours >= 4096 ? '+' : ''} colours, ${asked.length} new tiles (${asked.join(' ') || 'none'})`);
        }
      }
    } finally {
      await browser.close();
      server.close();
    }
    if (glyphsRead.size === 0) problem('no map font was read, so the pictures have no labels');
    if (glyphsMissing.size) console.log(`Font ranges the app does not ship (their characters are left out, as on a phone): ${[...glyphsMissing].sort().join(', ')}`);
    console.log(`Font files read: ${[...glyphsRead].sort().join(', ') || 'none'}`);
  }

  mkdirSync(OUT, { recursive: true });
  writeFileSync(LOCK, `${JSON.stringify(Object.fromEntries(Object.entries(lock).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))), null, 1)}\n`);
  report.requests = Object.fromEntries(counts);
  report.problems = problems;
  writeFileSync(REPORT, `${JSON.stringify(report, null, 1)}\n`);
}

let failed = false;
try {
  await main();
} catch (e) {
  problem(e.message);
  failed = true;
}
const total = printCounts();
if (total > config.limits.total) problem(`${total} requests, above the ceiling of ${config.limits.total}`);
if (problems.length || failed) {
  console.error(`\n${problems.length} problem(s); the map pictures are not complete:`);
  for (const p of problems) console.error(`  ${p}`);
  process.exit(1);
}
console.log('\nThe map pictures are rendered.');
