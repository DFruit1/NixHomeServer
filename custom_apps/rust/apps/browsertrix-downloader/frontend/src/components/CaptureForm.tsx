import { $, component$, useSignal, useStore, useVisibleTask$, type QRL } from '@builder.io/qwik';
import type { CreateJobRequest, Preflight, Profile, Recipe } from '../shared/types';
import { api, bytes, isJobResult, isObject, isPreflight, isProfile, json, listOf, message, stamp } from '../shared/api';
import { defaultRequest, lines, preset, rulesFromText, rulesToText, validatedRequest } from '../shared/capture';
import { Feedback } from './Feedback';

const scopes = [ ['page','Single page'], ['page-spa','Page + SPA routes'], ['prefix','Path prefix'], ['host','This host'], ['domain','Domain + subdomains'] ];
export const CaptureForm = component$<{initial?:CreateJobRequest;recipe?:Recipe;onQueued$:QRL<()=>void>}>(({initial,recipe,onQueued$})=>{
  const draft=useStore<CreateJobRequest>({...defaultRequest(),...(initial?JSON.parse(JSON.stringify(initial)):{}),options:{...preset('faithful'),...(initial?.options?JSON.parse(JSON.stringify(initial.options)):{})}});
  const rules=useSignal(rulesToText(draft.options!.selectors));
  const profiles=useSignal<Profile[]>([]), profileError=useSignal('');
  const preflight=useSignal<Preflight>(), preflightRecipe=useSignal('');
  const busy=useSignal(''), error=useSignal(''), notice=useSignal(''), recipeName=useSignal(recipe?.name||'');
  const captureForm=useSignal<HTMLFormElement>();
  const o=draft.options!;
  useVisibleTask$(()=>{api('/api/profiles',listOf(isProfile)).then(p=>profiles.value=p).catch(e=>profileError.value=message(e));});
  useVisibleTask$(({cleanup})=>{
    const form=captureForm.value;
    const reveal=(event:Event)=>{
      if(!(event.target instanceof Element))return;
      for(let detail=event.target.closest('details');detail;detail=detail.parentElement?.closest('details')??null)detail.open=true;
    };
    // Native validation must reveal hidden controls before the browser focuses them.
    form?.addEventListener('invalid',reveal,true);
    cleanup(()=>form?.removeEventListener('invalid',reveal,true));
  });
  const request=$(()=>validatedRequest({...draft,options:{...draft.options!,selectors:rulesFromText(rules.value)}}));
  const act=$(async(action:'queue'|'preflight'|'sample'|'recipe')=>{
    if(busy.value)return; busy.value=action;error.value='';notice.value='';
    try{
      const r=await request();
      if(action==='preflight'){
        if(r.options?.profileId)throw new Error('Use Browser sample for a signed-in capture.');
        preflight.value=await api('/api/preflight',isPreflight,json('POST',r));preflightRecipe.value=JSON.stringify(r);
      }else if(action==='recipe'){
        if(!recipeName.value.trim())throw new Error('Enter a recipe name.');
        await api(recipe?`/api/recipes/${encodeURIComponent(recipe.id)}`:'/api/recipes',isObject,json(recipe?'PATCH':'POST',{name:recipeName.value.trim(),request:r}));notice.value='Recipe saved.';
      }else{
        await api(action==='sample'?'/api/samples':'/api/jobs',isJobResult,json('POST',r));
        notice.value=`${action==='sample'?'Browser sample':'Capture'} queued. Follow progress in Active work.`;await onQueued$();
      }
    }catch(e){error.value=message(e);}finally{busy.value='';}
  });
  const preview=useSignal(''), previewResult=useSignal('');
  return <section class="panel capture" aria-labelledby="capture-title">
    <h2 id="capture-title">New capture</h2>
    <form ref={captureForm} preventdefault:submit onSubmit$={()=>act('queue')}>
      <label>Website URL<input name="url" type="url" required maxLength={2048} placeholder="https://example.org/articles/" value={draft.url} onInput$={(_,el)=>draft.url=el.value}/></label>
      <div class="form-grid">
        <label>Scope<select value={draft.scope} onChange$={(_,el)=>draft.scope=el.value as CreateJobRequest['scope']}>{scopes.map(([v,label])=><option key={v} value={v}>{label}</option>)}</select></label>
        <label>Max pages<input type="number" required min={1} max={500} value={draft.pageLimit} onInput$={(_,el)=>draft.pageLimit=el.valueAsNumber}/></label>
        <label>Max minutes per attempt<input type="number" required min={1} max={120} value={draft.timeLimitMinutes} onInput$={(_,el)=>draft.timeLimitMinutes=el.valueAsNumber}/></label>
      </div>
      {draft.scope!=='page'&&<p class="hint">{draft.scope==='page-spa'?'Includes this page’s hash routes.':draft.scope==='prefix'?`Pages below ${draft.url||'the selected path'}`:draft.scope==='host'?'Captures pages on this host only.':'Includes subdomains.'}</p>}
      <details class="advanced-capture"><summary>Advanced capture settings</summary>
      <details><summary>Estimate capture size</summary>
        <p class="hint">Estimates may miss dynamic pages. Browser sample runs a small capture.</p>
        <div class="actions"><button type="button" disabled={!!busy.value||!!o.profileId} onClick$={()=>act('preflight')}>{busy.value==='preflight'?'Discovering…':'Discover & estimate'}</button><button type="button" disabled={!!busy.value} onClick$={()=>act('sample')}>{busy.value==='sample'?'Queueing sample…':'Browser sample'}</button></div>
        {preflight.value&&<div class="estimate"><h3>Discovery estimate</h3><p>{bytes(preflight.value.estimate.lowerBytes)}–{bytes(preflight.value.estimate.upperBytes)} stored · peak disk {bytes(preflight.value.estimate.peakDiskBytes)}</p><p>{preflight.value.estimate.discoveredPages} discovered pages · {preflight.value.estimate.samplePages} samples reported · {preflight.value.estimate.unknownScope?'scope remains unknown':'bounded discovered scope'}</p>
          <p>Shared storage {bytes(preflight.value.estimate.sharedBytes)} · marginal page {bytes(preflight.value.estimate.marginalPageBytes)}. Transfer bytes are separate.</p>
          {preflightRecipe.value!==JSON.stringify({...draft,options:{...o,selectors:preflight.value?rulesFromTextSafe(rules.value):[]}})&&<p class="warning">Settings changed; run the estimate again before relying on it.</p>}
          <ul>{[...preflight.value.estimate.assumptions,...preflight.value.estimate.warnings,...preflight.value.warnings].map((v,i)=><li key={i}>{v}</li>)}</ul>
          <details><summary>Discovered URLs & templates</summary><ul>{preflight.value.groups.map(g=><li key={g.prefix}>{g.prefix} ({g.pages})</li>)}</ul><ul>{preflight.value.urls.map(u=><li key={u} class="break">{u}</li>)}</ul></details>
        </div>}
      </details>
      <fieldset><legend>Preset & fidelity</legend><div class="actions">{(['faithful','balanced','reader'] as const).map(p=><button type="button" key={p} aria-pressed={o.preset===p} onClick$={()=>{draft.options={...preset(p),seeds:[...o.seeds],include:[...o.include],exclude:[...o.exclude],profileId:o.profileId};}}>{p[0].toUpperCase()+p.slice(1)}</button>)}</div>
        <p class="hint">Faithful includes media. Balanced blocks ads and keeps posters. Reader omits media.</p>
        <div class="form-grid"><label>Media<select value={o.media} onChange$={(_,el)=>o.media=el.value as typeof o.media}><option value="full">Full audio/video</option><option value="posters">Posters only</option><option value="none">No media</option></select></label><label class="check"><input type="checkbox" checked={o.blockAds} onChange$={(_,el)=>o.blockAds=el.checked}/>Block ads & trackers</label><label class="check"><input type="checkbox" checked={o.deduplicate} onChange$={(_,el)=>o.deduplicate=el.checked}/>Deduplicate across captures</label></div>
        <p class="hint">Deduplicated captures may need earlier archives. Use a standalone export for offline replay.</p>
      </fieldset>
      <details><summary>Pages, seeds & URL rules</summary>
        <label>Additional seed URLs (one per line; one bounded batch)<textarea rows={3} value={o.seeds.join('\n')} onInput$={(_,el)=>o.seeds=el.value.split(/\r?\n/)}/></label>
        <label>Link depth (-1 means other budgets only)<input type="number" min={-1} max={100} value={o.depth} onInput$={(_,el)=>o.depth=el.valueAsNumber}/></label>
        <div class="form-grid"><label>Include page URLs (regular expressions, one per line)<textarea rows={3} value={o.include.join('\n')} onInput$={(_,el)=>o.include=el.value.split(/\r?\n/)}/></label><label>Exclude page URLs (regular expressions, one per line)<textarea rows={3} value={o.exclude.join('\n')} onInput$={(_,el)=>o.exclude=el.value.split(/\r?\n/)}/></label></div>
        <div class="inline-form"><label>Test a page URL<input type="url" value={preview.value} onInput$={(_,el)=>preview.value=el.value}/></label><button type="button" onClick$={()=>{try{const u=new URL(preview.value),base=new URL(draft.url);const allowed=draft.scope==='domain'?(u.hostname===base.hostname||u.hostname.endsWith('.'+base.hostname)):u.hostname===base.hostname;const scopeOk=draft.scope==='prefix'?u.pathname.startsWith(base.pathname):draft.scope==='page'?u.href.split('#')[0]===base.href.split('#')[0]:draft.scope==='page-spa'?u.pathname===base.pathname&&u.search===base.search:true;previewResult.value=allowed&&scopeOk&&(!o.include.length||o.include.some(r=>new RegExp(r).test(u.href)))&&!o.exclude.some(r=>new RegExp(r).test(u.href))?'Included by scope and page rules (asset dependencies are separate).':'Excluded by scope or page rules.';}catch{previewResult.value='Enter valid URLs and regular expressions first.';}}}>Test rules</button></div><p role="status">{previewResult.value}</p>
      </details>
      <details><summary>Resource rules & element rules</summary>
        <p class="hint">Page selection does not block asset dependencies. Resource rules may break shared assets. Allow exceptions explicitly.</p>
        <div class="form-grid"><label>Block resource URL patterns (one per line)<textarea rows={3} value={o.blockRules.join('\n')} onInput$={(_,el)=>o.blockRules=el.value.split(/\r?\n/)}/></label><label>Allow resource URL patterns (one per line)<textarea rows={3} value={o.allowRules.join('\n')} onInput$={(_,el)=>o.allowRules=el.value.split(/\r?\n/)}/></label></div>
        <label>Selector rules<textarea rows={4} placeholder={'hide .banner\nblock .video @ https://example.org/'} value={rules.value} onInput$={(_,el)=>rules.value=el.value}/></label><p class="hint">One “hide CSS-selector” or “block CSS-selector” per line; add “ @ URL-prefix” to limit a rule to part of the site.</p>
      </details>
      <details><summary>Browser behaviours & viewport</summary><div class="check-grid">{['autoscroll','autoplay','autofetch','autoclick','siteSpecific'].map(b=><label key={b} class="check"><input type="checkbox" checked={o.behaviors.includes(b)} onChange$={(_,el)=>o.behaviors=el.checked?[...o.behaviors,b]:o.behaviors.filter(v=>v!==b)}/>{b}</label>)}</div>
        <label class="check"><input type="checkbox" checked={o.alternateImages} onChange$={(_,el)=>o.alternateImages=el.checked}/>Capture alternate image variants</label><p class="hint">Automatic scrolling and playback can download more media.</p>
        <label>Click / load-more selector<input value={o.clickSelector} maxLength={1000} onInput$={(_,el)=>o.clickSelector=el.value}/></label>
        <div class="form-grid"><label>Behaviour timeout (seconds)<input type="number" min={1} max={600} value={o.behaviorTimeoutSeconds} onInput$={(_,el)=>o.behaviorTimeoutSeconds=el.valueAsNumber}/></label><label>Post-load delay (seconds)<input type="number" min={0} max={120} value={o.postLoadDelaySeconds} onInput$={(_,el)=>o.postLoadDelaySeconds=el.valueAsNumber}/></label><label>Language<input value={o.language} maxLength={40} onInput$={(_,el)=>o.language=el.value}/></label><label>Viewport width<input type="number" min={320} max={7680} value={o.viewportWidth} onInput$={(_,el)=>o.viewportWidth=el.valueAsNumber}/></label><label>Viewport height<input type="number" min={240} max={4320} value={o.viewportHeight} onInput$={(_,el)=>o.viewportHeight=el.valueAsNumber}/></label></div>
      </details>
      <details><summary>Offline interaction checks</summary><p class="hint">Click an element, then check visibility or text during offline verification.</p>
        {o.interactions.map((step,i)=><div class="subform" key={i}><div class="form-grid"><label>Click selector<input value={step.selector} onInput$={(_,el)=>step.selector=el.value}/></label><label>Assertion<select value={step.assertion} onChange$={(_,el)=>step.assertion=el.value as typeof step.assertion}><option value="visible">Expected selector is visible</option><option value="hidden">Expected selector is hidden</option><option value="text">Clicked text contains</option></select></label><label>Expected selector or text<input value={step.expected} onInput$={(_,el)=>step.expected=el.value}/></label></div><button type="button" onClick$={()=>o.interactions.splice(i,1)}>Remove check {i+1}</button></div>)}
        <button type="button" disabled={o.interactions.length>=20} onClick$={()=>o.interactions.push({selector:'',assertion:'visible',expected:''})}>Add interaction check</button>
      </details>
      <details><summary>Storage budgets & private profile</summary><div class="form-grid">
        <label>WARC limit (MiB; blank = no byte limit)<input type="number" min={1} value={o.sizeLimitBytes?o.sizeLimitBytes/1048576:''} onInput$={(_,el)=>o.sizeLimitBytes=el.value?el.valueAsNumber*1048576:null}/></label>
        <label>Resource limit (MiB; blank = unset)<input type="number" min={1} value={o.maxResourceBytes?o.maxResourceBytes/1048576:''} onInput$={(_,el)=>o.maxResourceBytes=el.value?el.valueAsNumber*1048576:null}/></label>
        <label>Disk reserve (MiB)<input type="number" min={0} required value={o.diskReserveBytes/1048576} onInput$={(_,el)=>o.diskReserveBytes=el.valueAsNumber*1048576}/></label>
      </div><p class="hint">Final archive size can exceed the WARC limit. Captures stopped at a limit are saved as partial archives.</p>
        <label>Private browser profile<select value={o.profileId||''} onChange$={(_,el)=>o.profileId=el.value||undefined}><option value="">Public capture (no profile)</option>{profiles.value.map(p=><option key={p.id} value={p.id} disabled={!p.available||!!p.expiresAt&&new Date(p.expiresAt).valueOf()<=Date.now()}>{`${p.name} — ${p.available?'available':'material unavailable'}${p.expiresAt?` · expires ${stamp(p.expiresAt)}`:''}`}</option>)}</select></label>
        {profileError.value&&<p class="warning">Profiles could not be loaded: {profileError.value}</p>}{o.profileId&&<p class="warning">This capture stays private and is excluded from shared Search.</p>}
      </details>
      <details><summary>{recipe?`Edit recipe v${recipe.version}`:'Save this configuration as a recipe'}</summary><div class="inline-form"><label>Recipe name<input maxLength={200} value={recipeName.value} onInput$={(_,el)=>recipeName.value=el.value}/></label><button type="button" disabled={!!busy.value} onClick$={()=>act('recipe')}>{recipe?'Save new recipe version':'Save recipe'}</button></div></details>
      </details>
      <Feedback error={error.value} notice={notice.value} pending={busy.value?`${busy.value==='queue'?'Queueing capture':busy.value==='recipe'?'Saving recipe':busy.value==='sample'?'Queueing browser sample':'Estimating capture'}…`:''}/>
      <div class="actions"><button class="primary" type="submit" disabled={!!busy.value}>{busy.value==='queue'?'Queueing…':'Queue capture'}</button></div>
    </form>
  </section>;
});
// A malformed draft must not throw during render; validation stays on action.
function rulesFromTextSafe(v:string){try{return rulesFromText(v);}catch{return [];}}
