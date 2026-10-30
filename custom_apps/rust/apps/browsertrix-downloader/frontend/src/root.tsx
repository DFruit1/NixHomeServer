import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { CurrentUser, Job, Recipe, ZimListing } from './shared/types';
import { api, bytes, isJob, isUser, isZims, listOf, message, safeExternal, segment } from './shared/api';
import { CaptureForm } from './components/CaptureForm';
import { Library } from './components/Library';
import { Jobs } from './components/Jobs';
import { ArchiveDetail } from './components/ArchiveDetail';
import { Automation } from './components/Automation';
import './client/styles.css';

export default component$(()=>{
  const me=useSignal<CurrentUser>(),jobs=useSignal<Job[]>([]),zims=useSignal<ZimListing>();
  const busy=useSignal(false),authError=useSignal(''),jobError=useSignal(''),zimError=useSignal(''),booted=useSignal(false);
  const view=useSignal('library'),archiveId=useSignal(''),targetUrl=useSignal(''),targetTs=useSignal(''),editing=useSignal<Recipe>();
  const refresh=$(async()=>{
    if(busy.value)return;busy.value=true;
    try{
      const user=await api('/api/me',isUser);
      if(me.value?.username!==user.username){jobs.value=[];zims.value=undefined;editing.value=undefined;}
      me.value=user;authError.value='';
      const results=await Promise.allSettled([api('/api/jobs',listOf(isJob)),api('/api/zims',isZims)]);
      const [j,z]=results;
      if(j.status==='fulfilled'){jobs.value=j.value;jobError.value='';}else jobError.value=message(j.reason);
      if(z.status==='fulfilled'){zims.value=z.value;zimError.value='';}else zimError.value=message(z.reason);
    }catch(e){authError.value=message(e);me.value=undefined;jobs.value=[];zims.value=undefined;}
    finally{busy.value=false;booted.value=true;}
  });
  useVisibleTask$(({cleanup})=>{
    const params=new URLSearchParams(window.location.search);
    view.value=['capture','automation'].includes(params.get('view')||'')?params.get('view')!:'library';
    const id=params.get('archive')||'';archiveId.value=/^[a-zA-Z0-9_-]{1,200}$/.test(id)?id:'';
    targetUrl.value=params.get('url')||'';targetTs.value=params.get('ts')||'';
    let live=true,timer:number|undefined;
    const poll=async()=>{await refresh();if(live)timer=window.setTimeout(poll,5000);};
    void poll();cleanup(()=>{live=false;window.clearTimeout(timer);});
  });
  return <main class="shell" id="main"><a class="skip-link" href="#workspace">Skip to workspace</a>
    <header class="toolbar"><a class="brand" href="/"><h1><span>Web</span> Archives</h1></a><div class="toolbar-user"><span>{me.value?.username||''}</span><a href="/oauth2/sign_out">Log out</a></div></header>
    <nav class="main-nav" aria-label="Main"><a class="button" href="/" aria-current={!archiveId.value&&view.value==='library'?'page':undefined}>Library</a><a class="button primary" href="/?view=capture" aria-current={!archiveId.value&&view.value==='capture'?'page':undefined}>New capture</a><a class="button" href="/?view=automation" aria-current={!archiveId.value&&view.value==='automation'?'page':undefined}>Recipes & schedules</a></nav>
    {!booted.value&&<p role="status">Loading your archive workspace…</p>}
    {authError.value&&<section class="panel"><p class="error" role="alert">Authentication or session refresh failed: {authError.value}</p><p>Archive data is hidden until your session is verified.</p><button type="button" disabled={busy.value} onClick$={refresh}>Retry session</button></section>}
    {me.value&&<div id="workspace" class="workspace" key={me.value.username}>
      {archiveId.value?<ArchiveDetail id={archiveId.value} username={me.value.username} initialUrl={targetUrl.value} initialTs={targetTs.value}/>:view.value==='capture'?<CaptureForm key={editing.value?.id||'new'} initial={editing.value?.request} recipe={editing.value} onQueued$={refresh}/>:view.value==='automation'?<Automation onQueued$={refresh} onEdit$={$((recipe:Recipe)=>{editing.value=recipe;view.value='capture';window.history.replaceState({},'','/?view=capture');window.scrollTo({top:0,behavior:'instant'});})}/>:<Library/>}
      <Jobs jobs={jobs.value} error={jobError.value} loading={busy.value} onRefresh$={refresh}/>
      {(zims.value||zimError.value)&&<section class="panel" aria-labelledby="kiwix-title"><div class="section-head"><h2 id="kiwix-title">Kiwix archives</h2>{safeExternal(zims.value?.readerUrl)&&<a class="button" href={safeExternal(zims.value?.readerUrl)} target="_blank" rel="noopener noreferrer">Open Kiwix reader</a>}</div>{zimError.value&&<p class="warning" role="alert">Kiwix refresh failed: {zimError.value}. {zims.value?'Showing last received listing.':'No listing available.'}</p>}{zims.value?.zims.length===0&&<p class="hint">No ZIM archives are available.</p>}{zims.value?.zims.map(z=><article class="list-row" key={z.name}><div class="row-head"><strong class="break">{z.name}</strong><span>{bytes(z.bytes)}</span></div><a class="button" href={`/api/zims/${segment(z.name)}?download=1`}>Download ZIM</a></article>)}</section>}
    </div>}
    <footer><p>Archived content can be incomplete. File integrity, replay fidelity and coverage are separate checks.</p></footer>
  </main>;
});
