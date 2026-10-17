"use strict";

const token = Date.now().toString(36) + "-" + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
let polling = null;
let pending = null;
let latest = null;
let lastID = "";
let launching = false;

function read(name) {
  try {
    if (!iina.file.exists("@data/" + name)) return null;
    const raw = iina.file.read("@data/" + name, {});
    return typeof raw === "string" && raw.length < 65536 ? JSON.parse(raw) : null;
  } catch (_) { return null; }
}
function remove(name) {
  if (iina.file.exists("@data/" + name)) iina.file.delete("@data/" + name);
}
function finish(request, ok) {
  iina.file.write("@data/result.json", JSON.stringify({id: request.id, token, ok}));
  if (pending && pending.id === request.id) pending = null;
}
function poll() {
  const cancellation = read("cancel.json");
  if (cancellation && cancellation.token === token) {
    if (latest && latest.id === cancellation.id) {
      iina.global.postMessage(latest.player, "cancel-cloud", {id: latest.id, token});
      if (pending && pending.id === latest.id) finish(pending, false);
    }
    remove("cancel.json");
  }
  const closed = read("closed.json");
  if (closed && closed.token === token) {
    remove("closed.json");
    clearInterval(polling);
    polling = null;
    return;
  }
  if (pending && Date.now() > pending.deadline) {
    iina.global.postMessage(pending.player, "cancel-cloud", {id: pending.id, token});
    finish(pending, false);
  }
  const request = read("playback.json");
  if (!request || request.token !== token || request.id === lastID) return;
  if (typeof request.id !== "string" || request.id.length > 64) return;
  lastID = request.id;
  if (typeof request.url !== "string" || !/^https:\/\/[^\s]+$/i.test(request.url) ||
      !Number.isFinite(request.createdAt) || Math.abs(Date.now() - request.createdAt) > 60000) {
    finish(request, false);
    return;
  }
  if (pending) {
    iina.global.postMessage(pending.player, "cancel-cloud", {id: pending.id, token});
    finish(pending, false);
  }
  try {
    const player = iina.global.createPlayerInstance({enablePlugins: true});
    pending = {id: request.id, player, deadline: Date.now() + 60000};
    latest = pending;
    iina.global.postMessage(player, "play-cloud", request);
  } catch (_) { finish(request, false); }
}

iina.global.onMessage("cloud-loaded", result => {
  if (!pending || !result || result.id !== pending.id || result.token !== token ||
      String(result.label) !== String(pending.player)) return;
  finish(pending, result.ok === true);
});

async function openNative(page) {
  if (launching) return;
  launching = true;
  try {
    const app = iina.utils.resolvePath("companion/IINA Cloud.app");
    if (!app || !iina.file.exists(app)) throw new Error("missing companion");
    const launch = iina.utils.resolvePath("@data/launch.iina-cloud-request");
    const directory = launch.slice(0, launch.lastIndexOf("/"));
    const secured = await iina.utils.exec("/bin/chmod", ["700", directory]);
    if (!secured || secured.status !== 0) throw new Error("private directory unavailable");
    remove("closed.json");
    iina.file.write("@data/launch.iina-cloud-request", JSON.stringify({page, token, createdAt: Date.now()}));
    if (!polling) polling = setInterval(poll, 150);
    const result = await iina.utils.exec("/usr/bin/open", ["-a", app, launch]);
    if (!result || result.status !== 0) throw new Error("companion launch failed");
  } catch (_) {
    if (polling) { clearInterval(polling); polling = null; }
    iina.standaloneWindow.simpleMode();
    iina.standaloneWindow.setContent("<h2>无法打开原生网页窗口</h2><p>请安装包含 IINA Cloud.app 的完整插件包，并允许系统打开该应用。</p>");
    iina.standaloneWindow.open();
  } finally { launching = false; }
}

iina.menu.addItem(iina.menu.item("PikPak 网盘", () => openNative("pikpak")));
iina.menu.addItem(iina.menu.item("蜜柑计划", () => openNative("mikan")));
// No startup forceUpdate: let the official host populate plugin menus.
