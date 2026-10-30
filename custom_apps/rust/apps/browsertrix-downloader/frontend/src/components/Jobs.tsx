import { $, component$, useSignal, useStore, type QRL } from '@builder.io/qwik';
import type { Job } from '../shared/types';
import { bytes, detailLink, json, message, mutate, segment, stamp } from '../shared/api';
import { Feedback } from './Feedback';
export const ACTIVE = ['queued','starting','running','cancelling','packaging','paused'];
export const Jobs = component$<{jobs:Job[];error:string;loading:boolean;onRefresh$:QRL<()=>void>}>(({jobs,error,loading,onRefresh$})=>{
  const pending=useStore<Record<string,string>>({}), errors=useStore<Record<string,string>>({}), notices=useStore<Record<string,string>>({});
  const resume=useSignal(''), pages=useSignal(0),minutes=useSignal(0),additionalBytes=useSignal(0);
  const clearBusy=useSignal(false),clearError=useSignal(''),clearNotice=useSignal('');
  const action=$(async(job:Job,command:'pause'|'stop'|'resume'|'cancel'|'retry'|'delete')=>{
    if(pending[job.id])return;
    if(command==='cancel'&&!window.confirm('Discard this job’s unfinished capture and checkpoint? Saved archives remain in the library.'))return;
    pending[job.id]=command; errors[job.id]='';notices[job.id]='';
    try{
      if(command==='resume'&&(![pages.value,minutes.value,additionalBytes.value].every(n=>Number.isInteger(n)&&n>=0)||pages.value>500||minutes.value>120))throw new Error('Extensions must be nonnegative integers: at most 500 pages and 120 minutes.');
      const body=command==='resume'?{additionalPages:pages.value,additionalMinutes:minutes.value,additionalBytes:additionalBytes.value*1048576}:{};
      await mutate(`/api/jobs/${segment(job.id)}${command==='delete'?'':`/${command}`}`,json(command==='delete'?'DELETE':'POST',body));
      notices[job.id]=command==='delete'?'History entry removed; archives retained.':`${command==='cancel'?'Discard':command} requested. Refreshing status…`;
      if(command==='resume')resume.value=''; await onRefresh$();
    }catch(e){errors[job.id]=message(e);}finally{pending[job.id]='';}
  });
  const row=(job:Job)=><article class="list-row" key={job.id}>
    <div class="row-head"><strong class="break">{job.request.url}</strong><span class="badge">{job.status}</span></div>
    <p class="hint">{job.progress?`${job.progress.pagesDone} pages captured · ${job.progress.pagesQueued} remaining in discovered queue · ${job.progress.pagesFailed} failed`:'Page progress not reported'}{job.bytesDownloaded!==undefined?` · ${bytes(job.bytesDownloaded)} transferred`:''}{job.bytesStored!==undefined?` · ${bytes(job.bytesStored)} stored`:''}</p>
    {job.stopReason&&<p>Stop reason: {job.stopReason}</p>}{job.error&&<p class="error">{job.error}</p>}
    {job.status==='packaging'&&<p class="hint">Packaging and publication are in progress. A finished crawl is not yet a validated archive.</p>}
    {job.status==='paused'&&<p class="hint">Checkpoint retained. Resume continues with explicit remaining or extended budgets.</p>}
    {job.coverage!==undefined&&<details><summary>Reported coverage</summary><pre>{JSON.stringify(job.coverage,null,2).slice(0,16000)}</pre></details>}
    {job.estimate&&<details><summary>{job.estimate.measured?'Browser-sampled estimate':'Reported estimate (measurement not established)'}</summary><p>{bytes(job.estimate.lowerBytes)}–{bytes(job.estimate.upperBytes)} stored · {job.estimate.samplePages} sample pages · peak disk {bytes(job.estimate.peakDiskBytes)}</p><ul>{[...job.estimate.assumptions,...job.estimate.warnings].map((w,i)=><li key={i}>{w}</li>)}</ul></details>}
    <div class="actions">
      {job.archiveId&&<a class="button" href={detailLink(job.archiveId)}>Open saved archive</a>}
      {['queued','starting','running'].includes(job.status)&&<><button type="button" disabled={!!pending[job.id]} onClick$={()=>action(job,'pause')}>Pause</button><button type="button" disabled={!!pending[job.id]} onClick$={()=>action(job,'stop')}>Stop & save partial</button></>}
      {(job.canResume||['paused','partial'].includes(job.status))&&<button type="button" disabled={!!pending[job.id]} onClick$={()=>{resume.value=resume.value===job.id?'':job.id;pages.value=0;minutes.value=0;additionalBytes.value=0;}}>Resume…</button>}
      {['failed','cancelled'].includes(job.status)&&<button type="button" disabled={!!pending[job.id]} onClick$={()=>action(job,'retry')}>Retry as new job</button>}
      {['queued','starting','running','paused','partial'].includes(job.status)&&<button class="danger" type="button" disabled={!!pending[job.id]} onClick$={()=>action(job,'cancel')}>Discard unfinished work…</button>}
      {!ACTIVE.includes(job.status)&&<button type="button" disabled={!!pending[job.id]} onClick$={()=>action(job,'delete')}>Remove history entry</button>}
    </div>
    {resume.value===job.id&&<form class="subform" preventdefault:submit onSubmit$={()=>action(job,'resume')}><h4>Extend cumulative budgets, if needed</h4><p class="hint">Zero adds no budget. Exhausted limits need an explicit extension. Saved partial versions remain unchanged.</p><div class="form-grid"><label>Additional pages<input type="number" min={0} max={500} required value={pages.value} onInput$={(_,el)=>pages.value=el.valueAsNumber}/></label><label>Additional minutes<input type="number" min={0} max={120} required value={minutes.value} onInput$={(_,el)=>minutes.value=el.valueAsNumber}/></label><label>Additional MiB<input type="number" min={0} required value={additionalBytes.value} onInput$={(_,el)=>additionalBytes.value=el.valueAsNumber}/></label></div><button class="primary" type="submit" disabled={!!pending[job.id]}>Resume saved checkpoint</button></form>}
    <Feedback error={errors[job.id]} notice={notices[job.id]} pending={pending[job.id]?`${pending[job.id]} pending…`:''}/><small>Updated {stamp(job.updatedAt)} · {job.id}</small>
  </article>;
  return <section aria-labelledby="active-title" class="panel"><div class="section-head"><h2 id="active-title">Active work</h2><button type="button" disabled={loading} onClick$={onRefresh$}>{loading?'Refreshing…':'Refresh'}</button></div>
    {error&&<p class="warning" role="alert">Status refresh failed: {error}. {jobs.length?'Showing last received jobs.':'No job data available.'}</p>}
    {jobs.filter(j=>ACTIVE.includes(j.status)).length?jobs.filter(j=>ACTIVE.includes(j.status)).map(row):<p class="hint">{loading?'Loading active work…':'No active captures or queued operations.'}</p>}
    <details><summary>Job history ({jobs.filter(j=>!ACTIVE.includes(j.status)).length} loaded)</summary>
      <p class="hint">Job history is disposable. Saved archives and their stable links remain in the library.</p>
      {jobs.filter(j=>!ACTIVE.includes(j.status)).map(row)}
      <button type="button" disabled={clearBusy.value} onClick$={async()=>{if(clearBusy.value)return;clearBusy.value=true;clearError.value='';try{await mutate('/api/jobs',json('DELETE'));clearNotice.value='Terminal history cleared; saved archives retained.';await onRefresh$();}catch(e){clearError.value=message(e);}finally{clearBusy.value=false;}}}>{clearBusy.value?'Clearing…':'Clear terminal history'}</button><Feedback error={clearError.value} notice={clearNotice.value}/>
    </details>
  </section>;
});
