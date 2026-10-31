import { $, component$, noSerialize, useSignal, useStore, useVisibleTask$, type NoSerialize } from '@builder.io/qwik';
import type { ArchiveSummary, Paginated, SearchHit } from '../shared/types';
import { api, bytes, detailLink, isHit, isObject, isOperation, isSummary, json, message, pageOf, stamp } from '../shared/api';
import { Feedback, Pager } from './Feedback';
export const Library = component$(()=>{
  const filters=useStore({q:'',favorite:false,collection:'',tag:'',sort:'newest',trashed:false,text:false});
  const query=useSignal(''),offset=useSignal(0),revision=useSignal(0),busy=useSignal(false),error=useSignal(''),loaded=useSignal('');
  const data=useSignal<Paginated<ArchiveSummary>>(),hits=useSignal<Paginated<SearchHit>>();
  const upload=useSignal<NoSerialize<File>>(),pending=useSignal(''),actionError=useSignal(''),notice=useSignal(''),resultArchive=useSignal('');
  const reconcile=useSignal<Record<string,unknown>>();
  const apply=$(()=>{
    const params=new URLSearchParams({sort:filters.sort,trashed:String(filters.trashed),mode:filters.text?'text':'library'});
    for(const [name,value] of Object.entries({q:filters.q,collection:filters.collection,tag:filters.tag}))if(value.trim())params.set(name,value.trim());
    if(filters.favorite)params.set('favorite','true');
    offset.value=0;query.value=params.toString();
  });
  useVisibleTask$(({track,cleanup})=>{
    const qs=track(()=>query.value),off=track(()=>offset.value);track(()=>revision.value);
    const abort=new AbortController();cleanup(()=>abort.abort());busy.value=true;error.value='';
    const params=new URLSearchParams(qs);const text=params.get('mode')==='text';params.delete('mode');params.set('limit','25');params.set('offset',String(off));
    const run=async()=>{try{if(text){hits.value=await api(`/api/archives/search?${params}`,pageOf(isHit),{signal:abort.signal});}else{data.value=await api(`/api/archives?${params}`,pageOf(isSummary),{signal:abort.signal});}loaded.value=text?'text':'library';}catch(e){if(!abort.signal.aborted)error.value=message(e);}finally{if(!abort.signal.aborted)busy.value=false;}};void run();
  });
  const operation=$(async(action:'import'|'reconcile')=>{
    if(pending.value)return;pending.value=action;actionError.value='';notice.value='';resultArchive.value='';
    try{
      if(action==='import'){
        const file=upload.value;if(!file)throw new Error('Choose a WACZ file first.');if(!file.name.toLowerCase().endsWith('.wacz'))throw new Error('Choose a .wacz archive.');
        const r=await api(`/api/archives/import?${new URLSearchParams({filename:file.name})}`,isOperation,{method:'POST',headers:{'content-type':'application/octet-stream'},body:file});
        notice.value=r.jobId?'Import queued. Follow progress in Active work.':'Archive imported.';resultArchive.value=r.archiveId||'';
      }else{
        reconcile.value=await api('/api/archives/reconcile',isObject,json('POST'));notice.value='Storage reconciliation completed. Unclaimed files remain unassigned.';
      }
      revision.value++;
    }catch(e){actionError.value=message(e);}finally{pending.value='';}
  });
  const applied=new URLSearchParams(query.value);
  const activeFilters=[applied.get('collection')&&`Collection: ${applied.get('collection')}`,applied.get('tag')&&`Tag: ${applied.get('tag')}`,applied.has('favorite')&&'Favorites',applied.get('trashed')==='true'&&'Trash',({oldest:'Oldest first',title:'Title order',size:'Largest first'} as Record<string,string>)[applied.get('sort')||'']].filter(Boolean).join(' · ');
  return <section class="panel" aria-labelledby="library-title"><div class="section-head"><h2 id="library-title">Archive library</h2><button class="text-button" type="button" disabled={busy.value} onClick$={()=>revision.value++}>{busy.value?'Refreshing…':'Refresh'}</button></div>
    <form preventdefault:submit onSubmit$={apply}>
      <div class="library-search inline-form"><label class="grow">Search<input type="search" placeholder="Title or website URL" value={filters.q} onInput$={(_,el)=>filters.q=el.value}/></label><label>Search in<select value={filters.text?'text':'library'} onChange$={(_,el)=>filters.text=el.value==='text'}><option value="library">Titles & URLs</option><option value="text">Captured page text</option></select></label><button type="submit" disabled={busy.value}>Search</button></div>
      <details class="filter-options"><summary>Filters & sort</summary><div class="form-grid"><label>Collection<input value={filters.collection} onInput$={(_,el)=>filters.collection=el.value}/></label><label>Tag<input value={filters.tag} onInput$={(_,el)=>filters.tag=el.value}/></label><label>Sort<select value={filters.sort} onChange$={(_,el)=>filters.sort=el.value}><option value="newest">Newest first</option><option value="oldest">Oldest first</option><option value="title">Title</option><option value="size">Largest first</option></select></label></div><div class="actions"><label class="check"><input type="checkbox" checked={filters.favorite} onChange$={(_,el)=>filters.favorite=el.checked}/>Favorites only</label><label class="check"><input type="checkbox" checked={filters.trashed} onChange$={(_,el)=>filters.trashed=el.checked}/>Trash</label><button type="submit" disabled={busy.value}>Apply filters</button></div></details>
    </form>
    {activeFilters&&<p class="hint">{activeFilters}</p>}
    <Feedback error={error.value} pending={busy.value?'Loading requested results. Previously received results remain below.':''}/>
    {error.value&&loaded.value&&<p class="warning">Showing stale results from the last successful request.</p>}
    {loaded.value==='text'&&hits.value&&<>{hits.value.items.map((hit,i)=><article class="list-row" key={`${hit.archiveId}:${i}`}><h3><a href={detailLink(hit.archiveId,hit.url,hit.ts||hit.captureTimestamp)}>{hit.title||hit.url}</a></h3><p class="break hint">{hit.url} · {stamp(hit.ts||hit.captureTimestamp)}</p><p>{hit.snippet}</p></article>)}{!hits.value.items.length&&<p>No captured pages match this query.</p>}<Pager offset={hits.value.offset} limit={hits.value.limit} total={hits.value.total} busy={busy.value} onPage$={$((n:number)=>offset.value=n)}/></>}
    {loaded.value==='library'&&data.value&&<>{!data.value.items.length&&<p class="hint">{filters.trashed?'Trash is empty.':'No matching archives. Use New capture or import an existing WACZ.'}</p>}{data.value.items.map(a=><article class="list-row" key={a.id}><div class="row-head"><h3><a href={detailLink(a.id)}>{a.title||a.url}</a></h3><span class="badge">{a.trashed?'trashed':a.captureStatus}</span></div><p class="hint break">{a.url}</p><p class="hint">{stamp(a.createdAt)} · {bytes(a.archiveBytes)}{a.pageCount!==undefined?` · ${a.pageCount} ${a.pageCount===1?'page':'pages'}`:''}{a.visibility?` · ${a.visibility}`:''}{a.favorite?' · Favorite':''}</p>{(a.tags.length>0||a.collection)&&<p class="hint">{a.collection?`Collection: ${a.collection} · `:''}{a.tags.join(', ')}</p>}</article>)}<Pager offset={data.value.offset} limit={data.value.limit} total={data.value.total} busy={busy.value} onPage$={$((n:number)=>offset.value=n)}/></>}
    <details><summary>Import & recovery</summary><p class="hint">Import a .wacz file into your library.</p><label>WACZ file<input type="file" accept=".wacz,application/wacz,application/zip" onChange$={(_,el)=>{upload.value=el.files?.[0]?noSerialize(el.files[0]):undefined;}}/></label><div class="actions"><button type="button" disabled={!!pending.value||!upload.value} onClick$={()=>operation('import')}>{pending.value==='import'?'Uploading…':'Upload & queue import'}</button><button type="button" disabled={!!pending.value} onClick$={()=>operation('reconcile')}>Reconcile retained files</button></div><Feedback error={actionError.value} notice={notice.value} pending={pending.value?`${pending.value} pending…`:''}/>{resultArchive.value&&<a href={detailLink(resultArchive.value)}>Open imported archive</a>}{reconcile.value&&<pre>{JSON.stringify(reconcile.value,null,2).slice(0,16000)}</pre>}</details>
  </section>;
});
