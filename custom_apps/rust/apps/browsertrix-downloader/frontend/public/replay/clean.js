/* Replay-only display rules. This asset never fetches data or changes archive bytes. */
(() => {
  'use strict';
  let rules;
  try {
    const script = document.currentScript;
    if (!script || script.src.length > 100000) return;
    rules = JSON.parse(decodeURIComponent(new URL(script.src).hash.slice(1)));
    if (!Array.isArray(rules) || rules.length > 100) return;
    rules = rules.filter(rule => rule && rule.action === 'hide' && typeof rule.selector === 'string' && rule.selector.length <= 1000 && (rule.urlPrefix === undefined || rule.urlPrefix === null || typeof rule.urlPrefix === 'string'));
  } catch { return; }
  let scheduled = false;
  const apply = () => {
    scheduled = false;
    const location = window.WB_wombat_location || window._WB_wombat_location;
    // Fail closed if the pinned replay runtime cannot identify the original URL.
    if (!location || typeof location.href !== 'string') return;
    for (const rule of rules) {
      if (rule.urlPrefix && !location.href.startsWith(rule.urlPrefix)) continue;
      try {
        const elements = document.querySelectorAll(rule.selector);
        if (elements.length > 10000) continue;
        for (const element of elements) {
          if (element instanceof HTMLElement || element instanceof SVGElement) element.style.setProperty('display', 'none', 'important');
        }
      } catch { /* Invalid selectors never become CSS or script source. */ }
    }
  };
  const schedule = () => { if (!scheduled) { scheduled = true; window.setTimeout(apply, 100); } };
  new MutationObserver(schedule).observe(document.documentElement, {childList:true,subtree:true});
  window.addEventListener('hashchange', schedule);
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', apply, {once:true});
  apply();
})();
