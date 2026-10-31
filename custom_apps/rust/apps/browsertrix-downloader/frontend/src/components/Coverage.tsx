import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { CoverageRecord, Paginated } from '../shared/types';
import { api, archivePath, isCoverage, message, pageOf } from '../shared/api';
import { Feedback, Pager } from './Feedback';

export const Coverage = component$<{id:string}>(({id})=>{
  const data=useSignal<Paginated<CoverageRecord>>(),offset=useSignal(0),revision=useSignal(0),busy=useSignal(false),error=useSignal('');
  useVisibleTask$(({track,cleanup})=>{
    const off=track(()=>offset.value);track(()=>revision.value);const abort=new AbortController();cleanup(()=>abort.abort());busy.value=true;error.value='';
    api(`${archivePath(id)}/coverage?${new URLSearchParams({offset:String(off),limit:'25'})}`,pageOf(isCoverage),{signal:abort.signal})
      .then(result=>{if(!abort.signal.aborted)data.value=result;})
      .catch(e=>{if(!abort.signal.aborted)error.value=message(e);})
      .finally(()=>{if(!abort.signal.aborted)busy.value=false;});
  });
  return <section aria-labelledby="coverage-title"><h3 id="coverage-title">Coverage & omissions</h3>
    <p class="hint">Skipped pages, omitted resources and captured errors. This list may not include every missed page.</p>
    <Feedback error={error.value} pending={busy.value?'Loading coverage…':''}/>
    {error.value&&<button type="button" disabled={busy.value} onClick$={()=>revision.value++}>Retry coverage</button>}
    {error.value&&data.value&&<p class="warning">Coverage is stale; the latest request failed.</p>}
    {data.value?.items.map((row,i)=><article class="list-row" key={`${data.value?.offset}:${i}`}><h4>{row.kind.replaceAll('-',' ')}</h4>{row.url&&<p class="break">{row.url}</p>}<p>{row.reason}</p>{row.status!=null&&<p class="hint">Captured HTTP status: {row.status}</p>}</article>)}
    {data.value&&!data.value.items.length&&<p>No coverage information recorded for this capture.</p>}
    {data.value&&<Pager offset={data.value.offset} limit={data.value.limit} total={data.value.total} busy={busy.value} onPage$={$((n:number)=>offset.value=n)}/>}
  </section>;
});
