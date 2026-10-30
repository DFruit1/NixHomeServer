import type { CaptureOptions, CreateJobRequest, SelectorRule } from './types';
import { parseCrawlUrl, MAX_PAGE_LIMIT, MAX_TIME_LIMIT_MINUTES } from './url';
export const lines = (v: string) => v.split(/\r?\n/).map(s=>s.trim()).filter(Boolean);
export const preset = (name: CaptureOptions['preset']): CaptureOptions => ({
  preset:name, depth:1, seeds:[], include:[], exclude:[], blockAds:name!=='faithful', blockRules:[], allowRules:[],
  media:name==='reader'?'none':name==='balanced'?'posters':'full',
  behaviors:name==='faithful'?['autoscroll','autoplay','autofetch','siteSpecific']:name==='reader'?['autoscroll']:['autoscroll','siteSpecific'],
  clickSelector:'a', behaviorTimeoutSeconds:90, postLoadDelaySeconds:0, viewportWidth:1280, viewportHeight:900,
  language:'en', sizeLimitBytes:2147483648,maxResourceBytes:null,diskReserveBytes:536870912, selectors:[], deduplicate:false, alternateImages:name==='faithful', interactions:[],
});
export const defaultRequest = (): CreateJobRequest => ({url:'',scope:'page',pageLimit:25,timeLimitMinutes:10,options:preset('faithful')});
export function rulesFromText(value: string): SelectorRule[] {
  return lines(value).map(line=>{
    const match=line.match(/^(hide|block)\s+(.+?)(?:\s+@\s+(https?:\/\/\S+))?$/);
    if(!match) throw new Error('Each selector rule must be “hide CSS-selector” or “block CSS-selector”, optionally followed by “ @ https://site/path”.');
    if(match[2].length>1000 || /[\u0000-\u001f]/.test(match[2])) throw new Error('Selector is too long or contains control characters.');
    try { document.createDocumentFragment().querySelector(match[2]); } catch { throw new Error(`Invalid CSS selector: ${match[2]}`); }
    return {action:match[1] as 'hide'|'block',selector:match[2],...(match[3]?{urlPrefix:match[3]}:{})};
  });
}
export const rulesToText = (rules: SelectorRule[]) => rules.map(r=>`${r.action} ${r.selector}${r.urlPrefix?` @ ${r.urlPrefix}`:''}`).join('\n');
export function validatedRequest(input: CreateJobRequest): CreateJobRequest {
  const parsed=parseCrawlUrl(input.url); if(!parsed) throw new Error('Enter a valid HTTP(S) URL without credentials.');
  const request: CreateJobRequest=JSON.parse(JSON.stringify(input));
  request.url=input.scope==='page-spa'?new URL(input.url.trim()).href:parsed.url;
  if(!Number.isInteger(request.pageLimit)||request.pageLimit<1||request.pageLimit>MAX_PAGE_LIMIT) throw new Error(`Page limit must be 1–${MAX_PAGE_LIMIT}.`);
  if(!Number.isInteger(request.timeLimitMinutes)||request.timeLimitMinutes<1||request.timeLimitMinutes>MAX_TIME_LIMIT_MINUTES) throw new Error(`Time limit must be 1–${MAX_TIME_LIMIT_MINUTES} minutes.`);
  if(request.options){
    const o=request.options;
    for(const key of ['seeds','include','exclude','blockRules','allowRules'] as const)o[key]=o[key].map(v=>v.trim()).filter(Boolean);
    if(!Number.isInteger(o.depth)||o.depth< -1||o.depth>100) throw new Error('Depth must be -1–100.');
    o.seeds=o.seeds.map(v=>{const p=parseCrawlUrl(v);if(!p)throw new Error(`Invalid seed URL: ${v}`);return input.scope==='page-spa'?new URL(v).href:p.url;});
    for(const rule of [...o.include,...o.exclude]){if(rule.length>1000)throw new Error('URL rule exceeds 1000 characters.');try{new RegExp(rule);}catch{throw new Error(`Invalid URL expression: ${rule}`);}}
    if(o.profileId==='')delete o.profileId;
    if(o.interactions.length>20)throw new Error('At most 20 interaction checks are allowed.');
    for(const step of o.interactions){try{document.querySelectorAll(step.selector);if(step.assertion!=='text')document.querySelectorAll(step.expected);}catch{throw new Error('Interaction checks need valid CSS selectors.');}if(!step.selector||!step.expected)throw new Error('Every interaction needs a click selector and expected result.');}
    for(const n of [o.behaviorTimeoutSeconds,o.postLoadDelaySeconds,o.viewportWidth,o.viewportHeight,o.diskReserveBytes,o.sizeLimitBytes??0,o.maxResourceBytes??0])if(!Number.isFinite(n)||n<0)throw new Error('Budgets, dimensions and delays must be nonnegative numbers.');
    if(o.viewportWidth<320||o.viewportWidth>7680||o.viewportHeight<240||o.viewportHeight>4320)throw new Error('Viewport must be 320–7680 by 240–4320 pixels.');
    if(o.behaviorTimeoutSeconds<1||o.behaviorTimeoutSeconds>600||o.postLoadDelaySeconds>120)throw new Error('Behavior timeout must be 1–600 seconds; load delay at most 120 seconds.');
  }
  return request;
}
