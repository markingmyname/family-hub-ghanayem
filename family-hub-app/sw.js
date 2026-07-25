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
  // Network-first for the app shell so updates show up quickly;
  // falls back to cache if offline.
  event.respondWith(
    fetch(event.request).catch(() => caches.match(event.request))
  );
});
