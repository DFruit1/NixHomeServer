import { $, component$, noSerialize, useSignal, useStore, useVisibleTask$, type NoSerialize, type QRL } from '@builder.io/qwik';
import type { Profile, Recipe, Schedule } from '../shared/types';
import { api, isJobResult, isObject, isProfile, isRecipe, isSchedule, json, listOf, message, mutate, segment, stamp } from '../shared/api';
import { Feedback } from './Feedback';
export const Automation = component$<{onEdit$:QRL<(r:Recipe)=>void>;onQueued$:QRL<()=>void>}>(({onEdit$,onQueued$})=>{
  const recipes=useSignal<Recipe[]>([]),schedules=useSignal<Schedule[]>([]),profiles=useSignal<Profile[]>([]);
  const pending=useStore<Record<string,boolean>>({}),errors=useStore<Record<string,string>>({}),notices=useStore<Record<string,string>>({});
  const recipeId=useSignal(''),interval=useSignal(1440),enabled=useSignal(false),profileName=useSignal(''),profileFile=useSignal<NoSerialize<File>>();
  const scheduleEdit=useSignal(''),editMinutes=useSignal(1440);
  const load=$(async()=>{
    const results=await Promise.allSettled([api('/api/recipes',listOf(isRecipe)),api('/api/schedules',listOf(isSchedule)),api('/api/profiles',listOf(isProfile))]);
    const [r,s,p]=results;
    if(r.status==='fulfilled'){recipes.value=r.value;errors.recipes='';}else errors.recipes=message(r.reason);
    if(s.status==='fulfilled'){schedules.value=s.value;errors.schedules='';}else errors.schedules=message(s.reason);
    if(p.status==='fulfilled'){profiles.value=p.value;errors.profiles='';}else errors.profiles=message(p.reason);
  });
  useVisibleTask$(()=>{void load();});
  const act=$(async(kind:string,id='')=>{
    const key=kind+id;if(pending[key])return;pending[key]=true;errors[key]='';notices[key]='';
    try{
      if(kind==='refresh'){await load();}
      else if(kind==='run'){
        const r=await api(`/api/recipes/${segment(id)}/run`,isJobResult,json('POST'));notices[key]=`Queued frozen recipe (${r.jobId}).`;await onQueued$();
      }else if(kind==='delete-recipe'){
        if(!window.confirm('Delete this recipe? Saved archives are retained. Schedules may still refer to it and must be removed or changed.'))return;
        await mutate(`/api/recipes/${segment(id)}`,json('DELETE'));notices[key]='Recipe deleted.';await load();
      }else if(kind==='schedule'){
        if(!recipeId.value)throw new Error('Select a saved recipe.');
        if(!Number.isInteger(interval.value)||interval.value<60)throw new Error('Schedule interval must be at least 60 whole minutes.');
        await api('/api/schedules',isObject,json('POST',{recipeId:recipeId.value,intervalMinutes:interval.value,enabled:enabled.value}));notices[key]=enabled.value?'Opt-in schedule created and enabled.':'Disabled schedule saved. It will not run until enabled.';enabled.value=false;await load();
      }else if(kind==='save-schedule'){
        if(!Number.isInteger(editMinutes.value)||editMinutes.value<60)throw new Error('Interval must be at least 60 whole minutes.');
        await mutate(`/api/schedules/${segment(id)}`,json('PATCH',{intervalMinutes:editMinutes.value}));notices[key]='Schedule interval updated.';scheduleEdit.value='';await load();
      }else if(kind==='toggle'){
        const s=schedules.value.find(s=>s.id===id);if(!s)throw new Error('Schedule is no longer loaded.');
        await mutate(`/api/schedules/${segment(id)}`,json('PATCH',{enabled:!s.enabled}));notices[key]=s.enabled?'Schedule disabled; no future runs will be started.':'Schedule enabled.';await load();
      }else if(kind==='delete-schedule'){
        await mutate(`/api/schedules/${segment(id)}`,json('DELETE'));notices[key]='Schedule removed; existing captures remain.';await load();
      }else if(kind==='profile-metadata'){
        if(!profileName.value.trim())throw new Error('Enter a profile name.');
        const p=await api('/api/profiles',isProfile,json('POST',{name:profileName.value.trim()}));notices[key]=p.available?'Profile metadata created; server reports accepted material available.':'Metadata saved. This profile is not usable until material is imported and validated.';await load();
      }else if(kind==='profile-import'){
        if(!profileName.value.trim()||!profileFile.value)throw new Error('Enter a name and choose a profile archive.');
        const r=await api(`/api/profiles/import?${new URLSearchParams({name:profileName.value.trim()})}`,isJobResult,{method:'POST',headers:{'content-type':'application/octet-stream'},body:profileFile.value});notices[key]=`Private validation queued (${r.jobId}). Availability will change only after accepted material exists.`;await onQueued$();await load();
      }else if(kind==='revoke'){
        if(!window.confirm('Revoke this private profile reference? Future captures, resumes, repairs and schedules using it will fail closed.'))return;
        await mutate(`/api/profiles/${segment(id)}`,json('DELETE'));notices[key]='Profile revoked.';await load();
      }
    }catch(e){errors[key]=message(e);}finally{pending[key]=false;}
  });
  return <section class="panel" aria-labelledby="automation-title"><div class="section-head"><h2 id="automation-title">Recipes, schedules & profiles</h2><button type="button" disabled={pending.refresh} onClick$={()=>act('refresh')}>Refresh references</button></div><Feedback error={errors.refresh}/>
    <h3>Saved recipes</h3><p class="hint">Recipes freeze bounded capture settings and profile references. New capture can submit several seeds as one bounded batch.</p><Feedback error={errors.recipes}/>
    {!recipes.value.length&&<p class="hint">No saved recipes received. Save a configuration in New capture.</p>}
    {recipes.value.map(r=><article class="list-row" key={r.id}><div class="row-head"><strong>{r.name}</strong><span class="badge">v{r.version}</span></div><p class="hint break">{r.request.url} · {r.request.pageLimit} pages · {r.request.timeLimitMinutes} minutes · {r.request.options?.profileId?'private profile reference':'public capture'}</p><details><summary>Frozen request & version</summary><pre>{JSON.stringify(r.request,null,2)}</pre><p class="hint">Updated {stamp(r.updatedAt)}. Credential material is stored separately.</p></details><div class="actions"><button type="button" disabled={pending['run'+r.id]} onClick$={()=>act('run',r.id)}>{pending['run'+r.id]?'Queueing…':'Run recipe'}</button><button type="button" onClick$={()=>onEdit$(r)}>Edit settings</button><button type="button" disabled={pending['delete-recipe'+r.id]} onClick$={()=>act('delete-recipe',r.id)}>Delete recipe…</button></div><Feedback error={errors['run'+r.id]||errors['delete-recipe'+r.id]} notice={notices['run'+r.id]}/></article>)}
    <h3>Scheduled updates</h3><Feedback error={errors.schedules}/><p class="hint">Schedules use the recipe’s explicit budgets. New schedules are disabled by default. Enabling is an opt-in; disabling prevents future runs.</p>
    {schedules.value.map(s=><article class="list-row" key={s.id}><div class="row-head"><strong>{recipes.value.find(r=>r.id===s.recipeId)?.name||`Recipe ${s.recipeId}`}</strong><span class="badge">{s.enabled?'enabled':'disabled'}</span></div><p class="hint">Every {s.intervalMinutes} minutes · next {stamp(s.nextRunAt)} · last {stamp(s.lastRunAt)}</p>{s.lastJobId&&<p>Last job: {s.lastJobId}</p>}{s.lastError&&<p class="error">Last run: {s.lastError}</p>}<div class="actions"><button type="button" disabled={pending['toggle'+s.id]} onClick$={()=>act('toggle',s.id)}>{s.enabled?'Disable':'Enable'}</button><button type="button" onClick$={()=>{scheduleEdit.value=scheduleEdit.value===s.id?'':s.id;editMinutes.value=s.intervalMinutes;}}>Edit interval</button><button type="button" disabled={pending['delete-schedule'+s.id]} onClick$={()=>act('delete-schedule',s.id)}>Remove schedule</button></div>{scheduleEdit.value===s.id&&<form class="inline-form" preventdefault:submit onSubmit$={()=>act('save-schedule',s.id)}><label>Interval (minutes)<input type="number" min={60} required value={editMinutes.value} onInput$={(_,el)=>editMinutes.value=el.valueAsNumber}/></label><button type="submit" disabled={pending['save-schedule'+s.id]}>Save interval</button></form>}<Feedback error={errors['toggle'+s.id]} notice={notices['toggle'+s.id]}/><Feedback error={errors['delete-schedule'+s.id]}/><Feedback error={errors['save-schedule'+s.id]} notice={notices['save-schedule'+s.id]}/></article>)}
    <form class="subform" preventdefault:submit onSubmit$={()=>act('schedule')}><h4>New schedule</h4><div class="form-grid"><label>Recipe<select required value={recipeId.value} onChange$={(_,el)=>recipeId.value=el.value}><option value="">Choose recipe</option>{recipes.value.map(r=><option key={r.id} value={r.id}>{`${r.name} (v${r.version})`}</option>)}</select></label><label>Interval (minutes)<input type="number" min={60} required value={interval.value} onInput$={(_,el)=>interval.value=el.valueAsNumber}/></label><label class="check"><input type="checkbox" checked={enabled.value} onChange$={(_,el)=>enabled.value=el.checked}/>Enable future captures</label></div><button type="submit" disabled={pending.schedule}>{pending.schedule?'Saving…':'Save schedule'}</button><Feedback error={errors.schedule} notice={notices.schedule}/></form>
    <h3>Private profile references</h3><Feedback error={errors.profiles}/><p class="hint">Accepted material is isolated by owner, immutable and checked at execution. Profile-backed captures and all their descendants remain private. Metadata alone cannot supply a working browser session.</p>
    {profiles.value.map(p=><article class="list-row" key={p.id}><div class="row-head"><strong>{p.name}</strong><span class="badge">{p.available?'material available':'material unavailable'}</span></div><p class="hint">{p.id} · updated {stamp(p.updatedAt)}{p.expiresAt?` · expires ${stamp(p.expiresAt)}`:''}</p><button type="button" disabled={pending['revoke'+p.id]} onClick$={()=>act('revoke',p.id)}>Revoke profile…</button><Feedback error={errors['revoke'+p.id]}/></article>)}
    <form class="subform" preventdefault:submit onSubmit$={()=>act('profile-import')}><h4>Import profile material</h4><label>Profile name<input maxLength={200} required value={profileName.value} onInput$={(_,el)=>profileName.value=el.value}/></label><label>Private profile archive<input type="file" onChange$={(_,el)=>profileFile.value=el.files?.[0]?noSerialize(el.files[0]):undefined}/></label><p class="hint">Material is uploaded as raw bytes to the private import endpoint. Never paste credentials into names, notes or recipes. Validation does not create a live profile.</p><div class="actions"><button type="submit" disabled={pending['profile-import']||!profileFile.value}>{pending['profile-import']?'Uploading…':'Upload & queue private validation'}</button><button type="button" disabled={pending['profile-metadata']} onClick$={()=>act('profile-metadata')}>Create metadata only</button></div><Feedback error={errors['profile-import']} notice={notices['profile-import']}/><Feedback error={errors['profile-metadata']} notice={notices['profile-metadata']}/></form>
  </section>;
});
