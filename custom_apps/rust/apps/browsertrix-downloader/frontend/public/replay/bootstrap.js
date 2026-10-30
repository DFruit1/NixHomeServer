/* The pinned viewer fetches collection JSON before waiting for SW activation.
 * Navigate into it only after this in-scope client is controlled by our worker. */
(async () => {
  const retry = document.getElementById('replay-retry');
  retry.addEventListener('click', () => window.location.reload());
  let timer, changed;
  try {
    if (!navigator.serviceWorker) throw new Error('This browser requires service worker support and HTTPS (or localhost).');
    const worker = new URL('./sw-clean.js?serveIndex=1', window.location.href);
    const controlled = new Promise(resolve => {
      changed = () => {
        if (navigator.serviceWorker.controller?.scriptURL === worker.href) resolve();
      };
      navigator.serviceWorker.addEventListener('controllerchange', changed);
      changed();
    });
    const registration = navigator.serviceWorker.register(worker.href, {scope: './'});
    await Promise.race([
      Promise.all([registration, controlled]),
      new Promise((_, reject) => {timer = window.setTimeout(() => reject(new Error('Offline replay preparation timed out.')), 20000);})
    ]);
    const viewer = new URL('./index.html', window.location.href);
    viewer.search = window.location.search;
    viewer.hash = window.location.hash;
    window.location.replace(viewer.href);
  } catch (error) {
    document.getElementById('replay-status').textContent = 'Unable to prepare offline replay. ' + (error instanceof Error ? error.message : String(error));
    retry.hidden = false;
  } finally {
    window.clearTimeout(timer);
    if (changed) navigator.serviceWorker.removeEventListener('controllerchange', changed);
  }
})();
