// Starts Tables: strings, the engine worker, the window, and the service worker
// that keeps everything available offline.

import "../design/base.js";
import { loadStrings, t } from "./i18n.js";
import { EngineClient } from "./engine-client.js";
import { WorkbookWindow } from "./window.js";

const root = document.getElementById("app");

async function start() {
  const strings = await loadStrings();
  const engine = new EngineClient();
  const locale = new URLSearchParams(location.search).get("lang") || navigator.language || "en-US";
  await engine.call("init", { strings, locale });
  const app = new WorkbookWindow(root, engine);
  app.showStart();
  registerServiceWorker(app);
}

function registerServiceWorker(app) {
  if (!("serviceWorker" in navigator)) return;
  // While developing, files change faster than builds: on this machine the
  // offline cache is only used when asked for with ?offline.
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(location.hostname);
  if (local && !new URLSearchParams(location.search).has("offline")) return;
  const firstInstall = !navigator.serviceWorker.controller;
  let restarting = false;
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (restarting) location.reload();
  });
  navigator.serviceWorker.register(new URL("../sw.js", import.meta.url), { scope: "../" }).then((registration) => {
    const offerRestart = (worker) => app.showMessage(t("Web.Update.Ready"), "info", {
      sticky: true,
      action: {
        label: t("Web.Update.Restart"),
        run: async () => {
          await app.flushAutosave();
          restarting = true;
          worker.postMessage("activate");
        },
      },
    });
    if (registration.waiting && navigator.serviceWorker.controller) offerRestart(registration.waiting);
    registration.addEventListener("updatefound", () => {
      const worker = registration.installing;
      worker?.addEventListener("statechange", () => {
        if (worker.state !== "installed") return;
        if (navigator.serviceWorker.controller) offerRestart(worker);
        else if (firstInstall) app.showMessage(t("Web.Offline.Ready"), "success");
      });
    });
  }).catch(() => {
    // Without a service worker Tables still works; it just needs the network to load.
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
