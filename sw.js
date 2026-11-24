// Agenda Inicial — service worker. Rede primeiro (sempre a versão mais nova quando há internet),
// cópia local quando está offline. Os dados do usuário nunca passam por aqui.
const CACHE = 'agenda-inicial-1.12.0';
const CORE = ['./', 'index.html', 'manifest.webmanifest', 'assets/icone-192.png', 'assets/icone-512.png', 'assets/icone.svg'];
self.addEventListener('install', e => e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting())));
self.addEventListener('activate', e => e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin || u.pathname.endsWith('versao.json')) return;
  e.respondWith(fetch(e.request).then(r => { if (r.ok){ const c = r.clone(); caches.open(CACHE).then(x => x.put(e.request, c)); } return r; })
    .catch(() => caches.match(e.request, { ignoreSearch: true }).then(r => r || (e.request.mode === 'navigate' ? caches.match('index.html') : undefined))));
});
