// Keeps Tables working with no network. Every request is answered from the
// cache of the current version, a set of files listed by Web/build.sh in
// build/version.json. The first visit downloads that set; after that a new
// version is downloaded only when the page asks (the toolbar's Update button),
// and becomes current once all of it has arrived.
//
// This file doesn't change from build to build, so the browser has no reason
// to replace it and nothing updates on its own.

const META = "tables-meta";
const MANIFEST = "./build/version.json";
// The engine as the page downloaded it on a first visit (engine/worker.js),
// so installing doesn't download it a second time.
const FIRST_VISIT = "tables-first-visit";

let current; // the version being served; undefined until read from META
let downloading = null;

async function currentVersion() {
  if (current !== undefined) return current;
  const meta = await caches.open(META);
  const stored = await meta.match("current");
  if (stored) {
    current = await stored.text();
  } else {
    // A cache left by the service worker before this one, which named it after its version.
    const legacy = (await caches.keys()).find((name) => /^tables-[0-9a-f]{16}$/.test(name));
    current = legacy ? legacy.slice("tables-".length) : null;
    if (current) await meta.put("current", new Response(current));
  }
  return current;
}

async function latestManifest() {
  const response = await fetch(MANIFEST, { cache: "no-store" });
  if (!response.ok) throw new Error(`${MANIFEST}: ${response.status}`);
  return response.json();
}

/** Downloads every file of `manifest` that isn't kept yet, then makes it the current version. */
async function download(manifest, onProgress = () => {}) {
  const cache = await caches.open(`tables-${manifest.version}`);
  const total = manifest.files.reduce((sum, [, size]) => sum + size, 0);
  let loaded = 0;
  onProgress(loaded, total);
  for (const [path, size] of manifest.files) {
    // Kept by an earlier attempt that didn't finish.
    if (await cache.match(path)) {
      loaded += size;
      onProgress(loaded, total);
      continue;
    }
    const response = await fetchOrReuse(path);
    if (!response.ok) throw new Error(`${path}: ${response.status}`);
    const counted = response.clone().body.getReader();
    const stored = cache.put(path, response);
    let received = 0;
    for (let chunk = await counted.read(); !chunk.done; chunk = await counted.read()) {
      received += chunk.value.byteLength;
      onProgress(loaded + Math.min(received, size), total);
    }
    await stored;
    loaded += size;
  }
  await (await caches.open(META)).put("current", new Response(manifest.version));
  current = manifest.version;
  for (const name of await caches.keys()) {
    if (name.startsWith("tables-") && name !== META && name !== `tables-${current}`) await caches.delete(name);
  }
}

/**
 * The file from the server, or the page's copy of it if the server says that
 * one is still current. Checked with the server either way, and not sent
 * again when the browser's own cache has the same file.
 */
async function fetchOrReuse(path) {
  const early = await (await caches.open(FIRST_VISIT)).match(path);
  const etag = early?.headers.get("ETag");
  const modified = early?.headers.get("Last-Modified");
  if (etag || modified) {
    const headers = etag ? { "If-None-Match": etag } : { "If-Modified-Since": modified };
    const response = await fetch(new Request(path, { cache: "no-store", headers }));
    if (response.status === 304) return early;
    return response;
  }
  return fetch(new Request(path, { cache: "no-cache" }));
}

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    if (!(await currentVersion())) await download(await latestManifest());
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

// The page talks over a MessageChannel: { type: "check" } answers whether a
// newer version is published; { type: "download" } downloads it, reporting
// progress, and answers once it is current.
self.addEventListener("message", (event) => {
  const port = event.ports[0];
  if (!port) return;
  if (event.data?.type === "check") {
    event.waitUntil((async () => {
      try {
        const manifest = await latestManifest();
        port.postMessage({ type: "checked", available: manifest.version !== await currentVersion() });
      } catch {
        port.postMessage({ type: "checked", available: false });
      }
    })());
  } else if (event.data?.type === "download") {
    downloading ??= (async () => {
      const manifest = await latestManifest();
      if (manifest.version !== await currentVersion()) await download(manifest, (loaded, total) => port.postMessage({ type: "progress", loaded, total }));
    })().finally(() => { downloading = null; });
    event.waitUntil(downloading.then(
      () => port.postMessage({ type: "downloaded" }),
      (error) => port.postMessage({ type: "failed", message: error.message }),
    ));
  }
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  // Always asked of the network, to see whether there's a new version.
  if (url.pathname.endsWith("/build/version.json")) return;
  event.respondWith((async () => {
    const version = await currentVersion();
    const cache = version ? await caches.open(`tables-${version}`) : null;
    // The app is one page: any navigation inside it is the app.
    if (request.mode === "navigate") {
      return (await cache?.match("./")) ?? (await cache?.match("./index.html")) ?? fetch(request);
    }
    const cached = await cache?.match(request, { ignoreSearch: true });
    if (cached) return cached;
    try {
      return await fetch(request);
    } catch {
      return new Response("", { status: 504, statusText: "Offline" });
    }
  })());
});
