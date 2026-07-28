// Family Hub — minimal service worker.
// This just lets the browser "install" the app and cache the shell for fast loading.
// It intentionally does NOT cache data — your calendar/chores/etc. always come fresh
// from shared storage so every device stays in sync.

const CACHE_NAME = 'family-hub-shell-v1';
const SHELL_FILES = ['./index.html', './manifest.json', './icon-192.png', './icon-512.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Only the app shell is ours to serve. Family sync talks to a cloud database
  // on another origin, and those calls must go straight to the network:
  // wrapping a POST here would hand back an empty cache miss instead of the
  // real network error, and the app would misread a failed save as a success.
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;

  // Network-first for the app shell so updates show up quickly;
  // falls back to cache if offline.
  event.respondWith(
    fetch(req).catch(() => caches.match(req))
  );
});
