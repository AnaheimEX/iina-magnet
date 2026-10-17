"use strict";

let pending = null;
let current = null;
function result(ok) {
  if (!pending) return;
  iina.global.postMessage("cloud-loaded", {
    id: pending.id, token: pending.token, label: iina.global.getLabel(), ok
  });
  pending = null;
}
iina.global.onMessage("play-cloud", request => {
  if (!request || typeof request.url !== "string" || !/^https:\/\//i.test(request.url)) return;
  pending = request;
  current = request;
  try {
    if (typeof request.userAgent === "string" && !/[\r\n]/.test(request.userAgent)) {
      iina.mpv.set("user-agent", request.userAgent);
    }
    // NSURLSession/WebKit already use the system proxy; pass the same explicit
    // HTTP proxy to mpv so API traffic and the video CDN use the same routing.
    if (typeof request.proxy === "string" && /^http:\/\/[^\s/@]+:\d+\/?$/.test(request.proxy)) {
      iina.mpv.set("http-proxy", request.proxy);
    }
    iina.mpv.set("network-timeout", 30);
    if (request.cache) {
      iina.mpv.set("cache", "yes");
      iina.mpv.set("cache-pause-initial", "no");
      iina.mpv.set("demuxer-lavf-probesize", 2 * 1024 * 1024);
      iina.mpv.set("demuxer-lavf-analyzeduration", 1);
      iina.mpv.set("demuxer-max-bytes", 256 * 1024 * 1024);
      iina.mpv.set("demuxer-max-back-bytes", 64 * 1024 * 1024);
      iina.mpv.set("demuxer-readahead-secs", 60);
      iina.mpv.set("stream-lavf-o", "multiple_requests=1,reconnect=1,reconnect_streamed=1,reconnect_delay_max=5");
    }
    iina.core.open(request.url);
  } catch (_) { result(false); }
});
iina.event.on("iina.file-loaded", () => {
  if (pending) result(iina.mpv.getString("path") === pending.url);
});
iina.event.on("mpv.end-file", () => result(false));
iina.event.on("iina.window-will-close", () => result(false));
iina.global.onMessage("cancel-cloud", request => {
  if (!current || request.id !== current.id || request.token !== current.token) return;
  pending = null;
  current = null;
  iina.core.stop();
});
