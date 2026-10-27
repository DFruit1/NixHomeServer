// The UI is intentionally dependency-free. Exercise async state transitions
// with a small DOM double; actual layout is checked in the browser separately.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const html = readFileSync(new URL('../src/ui.html', import.meta.url), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
class Element {
  constructor(tag = 'div') { this.tagName = tag.toUpperCase(); this.children = []; this.value = ''; this.hidden = false; this.attrs = {}; this.listeners = {}; this.textContent = ''; this.dataset = {}; }
  appendChild(node) { node.parentElement = this; this.children.push(node); return node; }
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children = nodes; }
  insertBefore(node, before) {
    node.remove();
    const index = before ? this.children.indexOf(before) : this.children.length;
    this.children.splice(index, 0, node); node.parentElement = this;
  }
  remove() { if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(node => node !== this); this.parentElement = null; }
  contains(node) { return this === node || this.children.some(child => child.contains(node)); }
  getBoundingClientRect() { return {top:0,bottom:0}; }
  setAttribute(key, value) { this.attrs[key] = value; }
  getAttribute(key) { return this.attrs[key]; }
  removeAttribute(key) { delete this.attrs[key]; }
  addEventListener(name, handler) { (this.listeners[name] ||= []).push(handler); }
  focus() { this.focused = true; }
  get options() { return this.children; }
}
function harness(search = '') {
  const elements = new Map([...html.matchAll(/id="([^"]+)"/g)].map(([, id]) => [id, new Element()]));
  const pending = [];
  const location = { origin: 'http://localhost', pathname: '/', search, href: '/' };
  const history = { pushState(_state, _unused, url) { location.search = url.includes('?') ? url.slice(url.indexOf('?')) : ''; } };
  const document = { getElementById(id) { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); }, createElement: tag => new Element(tag), querySelectorAll: () => [], activeElement: null, addEventListener() {} };
  const window = { addEventListener() {}, location, history, getSelection: () => null, scrollBy() {} };
  const context = vm.createContext({ document, window, location, history, URL, URLSearchParams, AbortController, console, setTimeout, clearTimeout,
    fetch(url, options) {
      if (url === '/api/sources') return Promise.resolve({ ok: true, status: 200, json: async () => ({ sources: [{ id: 'mail', displayName: 'Mail' }] }) });
      return new Promise((resolve, reject) => pending.push({ url, options, resolve: data => resolve({ok: true, status: 200, json: async () => data}), reject }));
    },
  });
  vm.runInContext(script, context);
  return { elements, pending, location, run: code => vm.runInContext(code, context) };
}
const flush = () => new Promise(resolve => setImmediate(resolve));
const response = title => ({ hits: [{id: title, title}], total: 1, hasMore: false });
function indexed(h) { return h.pending.filter(request => !request.url.includes('scope=live')); }

test('browser history clears select filters absent from the URL', () => {
  const h = harness();
  h.elements.get('source').value = 'mail';
  h.elements.get('owner').value = 'alice';
  h.elements.get('type').value = 'message/rfc822';
  h.run('readUrlState()');
  for (const key of ['source', 'owner', 'type']) assert.equal(h.elements.get(key).value, '');
});

test('a late response cannot overwrite the current search or busy state', async () => {
  const h = harness();
  h.elements.get('query').value = 'old'; h.run('runSearch()');
  h.elements.get('query').value = 'new'; h.run('runSearch()');
  indexed(h)[1].resolve(response('New result')); await flush();
  indexed(h)[0].resolve(response('Old result')); await flush();
  assert.equal(h.run('state.hits[0].title'), 'New result');
  assert.equal(h.run('state.hits.length'), 1);
});

test('clearing the query invalidates in-flight results', async () => {
  const h = harness();
  h.elements.get('query').value = 'old'; h.run('runSearch()');
  h.elements.get('query').value = ''; h.run('runSearch()');
  indexed(h)[0].resolve(response('Old result')); await flush();
  assert.equal(h.run('state.hits.length'), 0);
});

test('load more uses the submitted query even if the text is being edited', async () => {
  const h = harness();
  h.elements.get('query').value = 'original'; h.run('runSearch()');
  indexed(h)[0].resolve({ ...response('First'), hasMore: true, total: 2 }); await flush();
  const firstNode = h.elements.get('results').children[0];
  h.elements.get('query').value = 'unsubmitted edit';
  h.run('runSearch(null, {append: true})');
  const page = indexed(h)[1];
  assert.equal(new URL(page.url, 'http://localhost').searchParams.get('q'), 'original');
  page.resolve(response('Second')); await flush();
  assert.equal(h.elements.get('results').children[0], firstNode, 'existing result nodes retain focus and selection');
});

test('search URL updates when submitted, before a slow response', () => {
  const h = harness();
  h.elements.get('query').value = 'slow'; h.run('runSearch()');
  assert.equal(new URLSearchParams(h.location.search).get('q'), 'slow');
});

test('removing the last filter restores focus to the Filters control', () => {
  const h = harness();
  h.elements.get('source').value = 'mail';
  h.run('updateActiveFilters()');
  const chip = h.elements.get('activeFilters').children[0];
  chip.listeners.click[0]();
  assert.equal(h.elements.get('filterToggle').focused, true);
});

test('the mobile completion action closes filters and focuses the results', () => {
  const h = harness();
  h.run('toggleFilters(true)');
  h.elements.get('showResults').listeners.click[0]();
  assert.equal(h.elements.get('filtersPanel').hidden, true);
  assert.equal(h.elements.get('resultsRegion').focused, true);
});

test('library results render while live sources are pending', async () => {
  const h = harness();
  h.elements.get('query').value = 'books'; h.run('runSearch()');
  indexed(h)[0].resolve(response('Library match')); await flush();
  assert.equal(h.run('state.hits.length'), 1);
  assert.equal(h.run('state.liveLoading'), true);
  const live = h.pending.find(request => request.url.includes('scope=live'));
  live.resolve(response('Live match')); await flush();
  assert.equal(h.run('state.liveHits[0].title'), 'Live match');
  assert.equal(h.run('state.liveLoading'), false);
});

test('a library failure preserves successful live results', async () => {
  const h = harness();
  h.elements.get('query').value = 'books'; h.run('runSearch()');
  indexed(h)[0].reject(new Error('Library unavailable'));
  h.pending.find(request => request.url.includes('scope=live')).resolve(response('Live match'));
  await flush();
  assert.equal(h.elements.get('searchError').hidden, false);
  assert.equal(h.run('state.liveHits[0].title'), 'Live match');
  assert.equal(h.elements.get('results').getAttribute('aria-busy'), undefined);
});

test('a source failure remains visible when it returns no hits', async () => {
  const h = harness();
  h.elements.get('query').value = 'books'; h.run('runSearch()');
  h.pending.find(request => request.url.includes('scope=live')).resolve({hits:[], warnings:[{source:'kiwix',message:'Unavailable'}]});
  await flush();
  assert.equal(h.elements.get('searchCoverage').hidden, false);
  assert.equal(h.elements.get('liveError').hidden, false);
  assert.match(h.elements.get('liveErrorMessage').textContent, /kiwix: Unavailable/);
});

const renderedTitles = h => h.elements.get('results').children.map(item => item.children.find(child => child.tagName === 'H3')?.children[0].textContent);

test('one list interleaves live sources and library ranks with exact titles first', async () => {
  const h = harness(); h.elements.get('query').value = 'Topic'; h.run('runSearch()');
  indexed(h)[0].resolve({hits:[{id:'l1',source:'mail',title:'Library 1'}, {id:'l2',source:'mail',title:'Library 2'}, {id:'l3',source:'books',title:'Library 3'}],total:3}); await flush();
  h.pending.find(r => r.url.includes('scope=live')).resolve({hits:[{id:'d1',source:'documents',title:'Topic'}, {id:'d2',source:'documents',title:'Document 2'}, {id:'w1',source:'wiki',title:'Wiki 1'}]}); await flush();
  assert.deepEqual(renderedTitles(h), ['Topic','Library 1','Wiki 1','Library 2','Document 2','Library 3']);
});

test('newest sorts library and live hits together and places undated hits last', async () => {
  const h = harness('?sort=newest'); h.elements.get('query').value = 'Topic'; h.run('runSearch()');
  indexed(h)[0].resolve({hits:[{id:'l1',title:'Older',created:100}],total:1});
  h.pending.find(r => r.url.includes('scope=live')).resolve({hits:[{id:'d1',source:'docs',title:'Newer',created:200},{id:'w1',source:'wiki',title:'Undated'}]}); await flush();
  assert.deepEqual(renderedTitles(h), ['Newer','Older','Undated']);
});

test('live-only authors and literal comma-containing tags populate filters', async () => {
  const h = harness(); h.elements.get('query').value = 'Topic'; h.run('runSearch()');
  h.pending.find(r => r.url.includes('scope=live')).resolve({hits:[],authorFacets:[{name:'Ada',count:2}],tagFacets:[{name:'science, fiction',count:1}]}); await flush();
  indexed(h)[0].resolve({hits:[],total:0,authorFacets:[{name:'Bob',count:1}]}); await flush();
  assert.deepEqual(h.elements.get('author').options.map(node => node.value), ['', 'Ada', 'Bob']);
  assert.ok(h.elements.get('tag').options.some(node => node.value === 'science, fiction'));
});

test('the same source hit returned by both paths is displayed only once', async () => {
  const h = harness(); h.elements.get('query').value = 'Topic'; h.run('runSearch()');
  const hit = {id:'same',source:'documents',title:'Topic'};
  indexed(h)[0].resolve({hits:[hit],total:1});
  h.pending.find(r => r.url.includes('scope=live')).resolve({hits:[hit]}); await flush();
  assert.equal(h.elements.get('results').children.length,1);
});

test('retrying a failed library request retains the submitted query and successful live results', async () => {
  const h = harness(); h.elements.get('query').value = 'original'; h.run('runSearch()');
  indexed(h)[0].reject(new Error('Unavailable'));
  h.pending.find(r => r.url.includes('scope=live')).resolve(response('Live match')); await flush();
  h.elements.get('query').value = 'draft edit';
  h.elements.get('retrySearch').listeners.click[0]();
  assert.equal(new URL(indexed(h)[1].url, 'http://localhost').searchParams.get('q'),'original');
  assert.equal(h.run('state.liveHits.length'),1);
  assert.equal(h.pending.filter(r => r.url.includes('scope=live')).length,1);
});

test('a refreshed live result updates the existing row when its title or metadata changes', async () => {
  const h=harness();h.elements.get('query').value='Topic';h.run('runSearch()');
  h.pending.find(r=>r.url.includes('scope=live')).resolve({hits:[{id:'d1',source:'docs',title:'Old title',metadata:{}}]});await flush();
  const original=h.elements.get('results').children[0];
  h.elements.get('retryLive').listeners.click[0]();
  h.pending.filter(r=>r.url.includes('scope=live'))[1].resolve({hits:[{id:'d1',source:'docs',title:'New title',metadata:{tags:'Recovered tag'}}]});await flush();
  assert.equal(h.elements.get('results').children[0],original);
  assert.deepEqual(renderedTitles(h),['New title']);
  const details=original.children.find(child=>child.tagName==='DETAILS');
  assert.equal(details.hidden,false);
  assert.match(details.children.find(child=>child.tagName==='P').textContent,/Recovered tag/);
});

test('a total outage announces unavailability rather than zero matches', async () => {
  const h=harness();h.elements.get('query').value='Topic';h.run('runSearch()');
  for(const request of h.pending)request.reject(new Error('Offline'));await flush();
  assert.match(h.elements.get('status').textContent,/unavailable/i);
});
