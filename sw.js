const CACHE = 'voyage-v1';
const SHELL = [
  '/Voyage/',
  '/Voyage/index.html',
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  /* Only handle same-origin requests — let Supabase API calls pass through untouched */
  if (!e.request.url.startsWith(self.location.origin)) return;

  /* Network-first: always try to fetch fresh; fall back to cache */
  e.respondWith(
    fetch(e.request)
      .then(res => {
        if (res.ok && e.request.method === 'GET') {
          const clone = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, clone));
        }
        return res;
      })
      .catch(() => caches.match(e.request))
  );
});

/* Push notification handler — ready for when push is wired up */
self.addEventListener('push', e => {
  if (!e.data) return;
  const { title, body, url } = e.data.json();
  e.waitUntil(
    self.registration.showNotification(title, {
      body,
      icon: '/Voyage/icons/icon.svg',
      badge: '/Voyage/icons/icon.svg',
      data: { url: url || '/Voyage/' },
    })
  );
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
      const existing = list.find(c => c.url.includes('/Voyage/'));
      if (existing) return existing.focus();
      return clients.openWindow(e.notification.data.url);
    })
  );
});
