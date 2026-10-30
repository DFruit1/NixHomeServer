/* Keep the replay proxy limited to the local display-rule script. */
(() => {
  const asset = new URL('./clean.js', self.location.href);
  const proxy = new URL('./static/proxy/' + asset.href, self.location.href);
  self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
  self.addEventListener('fetch', event => {
    const request = new URL(event.request.url);
    if (request.origin !== proxy.origin || request.pathname !== proxy.pathname || request.search || event.request.method !== 'GET') return;
    event.respondWith(fetch(asset.href, {credentials: 'same-origin', redirect: 'error', cache: 'no-store'}));
    event.stopImmediatePropagation();
  });
})();
importScripts('./sw.js');
