import { $, component$, useSignal, useStore, useVisibleTask$, useComputed$, type QRL } from '@builder.io/qwik';
import type { PageRecord, Paginated, ResourceRecord } from '../shared/types';
import { api, archivePath, bytes, detailLink, isPage, isResource, message, pageOf, stamp } from '../shared/api';
import { Feedback, Pager } from './Feedback';
export const Inventory = component$<{id:string;kind:'pages'|'resources';onRepair$:QRL<(url:string)=>void>;onInclude$:QRL<(url:string)=>void>}>(({id,kind,onRepair$,onInclude$})=>{
  const filters=useStore({q:'',mime:'',domain:''}),query=useSignal(''),offset=useSignal(0),busy=useSignal(false),error=useSignal('');
  const pages=useSignal<Paginated<PageRecord>>(),resources=useSignal<Paginated<ResourceRecord>>();
  useVisibleTask$(({track,cleanup})=>{
    const q=track(()=>query.value),off=track(()=>offset.value);const abort=new AbortController();cleanup(()=>abort.abort());busy.value=true;error.value='';
    const params=new URLSearchParams(q);params.set('offset',String(off));params.set('limit','25');
    const run=async()=>{try{if(kind==='pages')pages.value=await api(`${archivePath(id)}/pages?${params}`,pageOf(isPage),{signal:abort.signal});else resources.value=await api(`${archivePath(id)}/resources?${params}`,pageOf(isResource),{signal:abort.signal});}catch(e){if(!abort.signal.aborted)error.value=message(e);}finally{if(!abort.signal.aborted)busy.value=false;}};void run();
  });
  const data=useComputed$(()=>kind==='pages'?pages.value:resources.value);
  const apply=$(()=>{
    const params=new URLSearchParams();
    for(const [name,value] of Object.entries(filters))if(value.trim())params.set(name,value.trim());
    offset.value=0;query.value=params.toString();
  });
  return <section aria-label={kind==='pages'?'Captured pages':'Captured resources'}><h3>{kind==='pages'?'Pages & captured text':'Resource inspector'}</h3><form class="library-filters" preventdefault:submit onSubmit$={apply}><label class="grow">Search {kind}<input type="search" value={filters.q} onInput$={(_,el)=>filters.q=el.value}/></label>{kind==='resources'&&<><label>MIME prefix<input placeholder="image/" value={filters.mime} onInput$={(_,el)=>filters.mime=el.value}/></label><label>Exact domain<input placeholder="cdn.example.org" value={filters.domain} onInput$={(_,el)=>filters.domain=el.value}/></label></>}<button type="submit" disabled={busy.value}>Apply</button></form><Feedback error={error.value} pending={busy.value?'Loading inventory. Previously received items remain below.':''}/>{error.value&&data.value&&<p class="warning">Inventory is stale; the latest request failed.</p>}
    {kind==='resources'&&<p class="hint">Record bytes may be shared across pages. They are not per-page storage savings, transfer totals or a count of unique payloads. Archive overview reports measured file totals.</p>}
    {pages.value&&kind==='pages'&&pages.value.items.map((p,i)=><article class="list-row" key={`${p.url}:${p.ts}:${i}`}><h4><a href={detailLink(id,p.url,p.ts)}>{p.title||p.url}</a></h4><p class="break hint">{p.url}</p><p class="hint">{stamp(p.ts)} · status {p.status||'not reported'} · {bytes(p.bytes)} attributed bytes</p><div class="actions"><a class="button" href={detailLink(id,p.url,p.ts)}>Open this captured page</a><button type="button" onClick$={()=>onInclude$(p.url)}>Include in export</button><button type="button" onClick$={()=>onRepair$(p.url)}>Select for repair</button></div><details><summary>Captured text & resource references</summary><p class="preserve">{p.text||'No captured text reported.'}</p><ul>{p.resourceUrls.map((u,j)=><li class="break" key={j}>{u}</li>)}</ul></details></article>)}
    {resources.value&&kind==='resources'&&resources.value.items.map((r,i)=><article class="list-row" key={`${r.digest}:${i}`}><h4 class="break">{r.url}</h4><p class="hint">{r.mime||'MIME unknown'} · {r.domain} · status {r.status||'not reported'} · {bytes(r.bytes)} record bytes</p><details><summary>Digest & shared page attribution</summary><p class="mono break">{r.digest||'Digest unavailable'}</p>{r.pages.length?<ul>{r.pages.map((p,j)=><li key={j} class="break"><a href={detailLink(id,p)}>{p}</a></li>)}</ul>:<p>No page attribution was reported.</p>}</details><div class="actions"><button type="button" onClick$={()=>onInclude$(r.url)}>Include URL in export</button><button type="button" onClick$={()=>onRepair$(r.url)}>Select for repair</button></div></article>)}
    {data.value&&!data.value.items.length&&<p class="hint">No matching {kind} reported.</p>}{data.value&&<Pager offset={data.value.offset} limit={data.value.limit} total={data.value.total} busy={busy.value} onPage$={$((n:number)=>offset.value=n)}/>}<p class="hint">Missing inventory is incomplete coverage evidence; it does not prove that the live website removed content.</p>
  </section>;
});
