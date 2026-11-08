// Keeps Tables working with no network. On install it stores every file the
// app needs, as listed by Web/build.sh in build/version.js; afterwards every
// request is answered from that store. A new build installs alongside and
// takes over only when the page asks, after it has saved its work.

importScripts("./build/version.js");

const CACHE = `tables-${self.TABLES_VERSION}`;
const FILES = self.TABLES_FILES;

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(FILES.map((file) => new Request(file, { cache: "reload" })))));
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) {
      if (name.startsWith("tables-") && name !== CACHE) await caches.delete(name);
    }
    await self.clients.claim();
  })());
});

self.addEventListener("message", (event) => {
  if (event.data === "activate") self.skipWaiting();
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    // The app is one page: any navigation inside it is the app.
    if (request.mode === "navigate") {
      return (await cache.match("./")) ?? (await cache.match("./index.html")) ?? fetch(request);
    }
    const cached = await cache.match(request, { ignoreSearch: true });
    if (cached) return cached;
    try {
      return await fetch(request);
    } catch {
      return new Response("", { status: 504, statusText: "Offline" });
    }
  })());
});
