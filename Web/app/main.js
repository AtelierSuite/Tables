// Starts Tables: strings, the engine worker, the window, and the service worker
// that keeps everything available offline.

import "../design/base.js";
import { loadStrings, t, language } from "./i18n.js";
import { EngineClient } from "./engine-client.js";
import { WorkbookWindow } from "./window.js";

const root = document.getElementById("app");

// Safari zooms the whole page on a pinch unless told not to; the grid handles its own.
for (const type of ["gesturestart", "gesturechange"]) {
  document.addEventListener(type, (event) => event.preventDefault(), { passive: false });
}

async function start() {
  const strings = await loadStrings();
  const engine = new EngineClient({ keepForOffline: usesServiceWorker() && !navigator.serviceWorker.controller });
  showEngineProgress(engine);
  const locale = new URLSearchParams(location.search).get("lang") || navigator.language || "en-US";
  await engine.call("init", { strings, locale });
  const app = new WorkbookWindow(root, engine);
  app.showStart();
  registerServiceWorker(app);
}

// The spinner becomes a progress bar over the percentage while the engine
// downloads, and comes back while it compiles. Not when it loads at once, from
// the offline cache.
function showEngineProgress(engine) {
  const loading = root.querySelector(".app__loading");
  const spinner = loading?.querySelector(".ds-spinner");
  const bar = loading?.querySelector(".app__loading-progress");
  const caption = loading?.querySelector(".ds-caption");
  if (!bar) return;
  const name = caption.textContent;
  const format = new Intl.NumberFormat(language, { style: "percent" });
  let latest = null;
  let shown = false;
  const render = () => {
    if (!shown || !latest || !bar.isConnected) return;
    const downloading = latest.loaded < latest.total;
    spinner.hidden = downloading;
    bar.hidden = !downloading;
    loading.classList.toggle("is-downloading", downloading);
    const fraction = Math.floor((latest.loaded / latest.total) * 100) / 100;
    caption.textContent = downloading ? format.format(fraction) : name;
    // The bar already tells assistive technology how far along it is.
    if (downloading) caption.setAttribute("aria-hidden", "true");
    else caption.removeAttribute("aria-hidden");
    const percent = Math.round(fraction * 100);
    bar.style.setProperty("--ds-progress", `${percent}%`);
    bar.setAttribute("aria-valuenow", String(percent));
  };
  setTimeout(() => {
    shown = true;
    render();
  }, 300);
  engine.addEventListener("progress", (event) => {
    latest = event.detail;
    render();
  });
}

function usesServiceWorker() {
  if (!("serviceWorker" in navigator)) return false;
  // While developing, files change faster than builds: on this machine the
  // offline cache is only used when asked for with ?offline.
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(location.hostname);
  return !local || new URLSearchParams(location.search).has("offline");
}

function registerServiceWorker(app) {
  if (!usesServiceWorker()) return;
  const firstInstall = !navigator.serviceWorker.controller;
  navigator.serviceWorker.register(new URL("../sw.js", import.meta.url), { scope: "../" }).then(async (registration) => {
    const installing = Boolean(registration.installing);
    await navigator.serviceWorker.ready;
    if (firstInstall && installing) app.showMessage(t("Web.Offline.Ready"), "success");
    watchForUpdates(app, registration);
  }).catch(() => {
    // Without a service worker Tables still works; it just needs the network to load.
  });
}

// The service worker never updates by itself. The page asks it now and then
// whether a new version is published and, if so, offers the toolbar's Update
// button, which downloads it and reloads.
function watchForUpdates(app, registration) {
  const ask = (message, onReply) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = (event) => onReply(event.data);
    registration.active?.postMessage(message, [channel.port2]);
  };
  const download = (onProgress) => new Promise((resolve, reject) => ask({ type: "download" }, (reply) => {
    if (reply.type === "progress") onProgress(reply.total ? reply.loaded / reply.total : 0);
    else if (reply.type === "downloaded") resolve();
    else if (reply.type === "failed") reject(new Error(reply.message));
  }));
  let offered = false;
  let lastCheck = 0;
  const check = () => {
    if (offered || !navigator.onLine || Date.now() - lastCheck < 30 * 60 * 1000) return;
    lastCheck = Date.now();
    ask({ type: "check" }, (reply) => {
      if (!reply.available || offered) return;
      offered = true;
      app.offerUpdate(download);
    });
  };
  check();
  document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && check());
  window.addEventListener("online", () => {
    lastCheck = 0;
    check();
  });
}

start().catch((error) => {
  root.innerHTML = "";
  const message = document.createElement("div");
  message.className = "app__failure ds-notification ds-notification--error";
  message.setAttribute("role", "alert");
  // The strings may not have loaded, so this one message carries its own English.
  const localized = t("Web.Error.Start", error.message);
  message.textContent = localized.startsWith("Web.Error.Start") ? `Tables couldn't start: ${error.message}` : localized;
  root.append(message);
  console.error(error);
});
