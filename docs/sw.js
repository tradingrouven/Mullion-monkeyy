// Offline support: pages come from the network first (so updates show at once), cache when offline.
const CACHE = 'bullion-monkey-v4';
const SHELL = ['./', 'index.html', 'manifest.webmanifest', 'icon-180.png', 'icon-192.png', 'icon-512.png', 'news.json'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL))); self.skipWaiting(); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))); self.clients.claim(); });
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.origin !== location.origin) return;   // MT5 gist and fonts go straight to the network
  const key = url.pathname.endsWith('/news.json') ? new Request(url.pathname) : e.request;
  e.respondWith(caches.open(CACHE).then(async c => {
    try {
      const r = await fetch(e.request);
      if (r.ok || r.type === 'opaque') c.put(key, r.clone());
      return r;
    } catch {
      return (await c.match(key)) || (await c.match('index.html'));
    }
  }));
});
