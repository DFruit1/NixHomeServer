import type { Archive, ArchiveReport, ComparisonReport, CreateJobRequest, CurrentUser, Estimate, Job, PageRecord, Paginated, Preflight, Profile, Recipe, ResourceRecord, Schedule, SearchHit, SelectorRule, Verification, ZimListing } from './types';

type Guard<T> = (value: unknown) => value is T;
const obj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);
const str = (v: unknown): v is string => typeof v === 'string';
const num = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v) && v >= 0;
const bool = (v: unknown): v is boolean => typeof v === 'boolean';
const strings = (v: unknown): v is string[] => Array.isArray(v) && v.every(str);
const id = (v: unknown): v is string => str(v) && /^[A-Za-z0-9_-]{1,200}$/.test(v);
const optional = (v: unknown, guard: (v: unknown) => boolean) => v === undefined || v === null || guard(v);
const fields = (v: unknown, ss: string[], ns: string[] = []) => obj(v) && ss.every(k => str(v[k])) && ns.every(k => num(v[k]));
export const listOf = <T>(guard: Guard<T>): Guard<T[]> => (v): v is T[] => Array.isArray(v) && v.every(guard);
export const pageOf = <T>(guard: Guard<T>): Guard<Paginated<T>> => (v): v is Paginated<T> => obj(v) && listOf(guard)(v.items) && [v.total, v.offset, v.limit].every(n => num(n) && Number.isInteger(n)) && (v.limit as number) > 0 && (v.limit as number) <= 100 && (v.items as unknown[]).length <= (v.limit as number) && (v.total as number) >= (v.items as unknown[]).length;
const isOptions = (v:unknown):boolean => {
  if(!obj(v))return false;
  const check=(key:string,guard:(v:unknown)=>boolean)=>v[key]===undefined||guard(v[key]);
  return ['seeds','include','exclude','blockRules','allowRules','behaviors'].every(k=>check(k,strings))
    && ['blockAds','deduplicate','alternateImages'].every(k=>check(k,bool))
    && ['clickSelector','language'].every(k=>check(k,str))
    && ['behaviorTimeoutSeconds','postLoadDelaySeconds','viewportWidth','viewportHeight','diskReserveBytes'].every(k=>check(k,num))
    && check('depth',n=>typeof n==='number'&&Number.isInteger(n)&&n>=-1)
    && check('preset',n=>['faithful','balanced','reader'].includes(String(n)))
    && check('media',n=>['full','posters','none'].includes(String(n)))
    && optional(v.profileId,str)&&optional(v.sizeLimitBytes,num)&&optional(v.maxResourceBytes,num)
    && check('selectors',n=>Array.isArray(n)&&n.every(isRule))
    && check('interactions',n=>Array.isArray(n)&&n.length<=20&&n.every(step=>obj(step)&&str(step.selector)&&str(step.expected)&&['visible','hidden','text'].includes(String(step.assertion))));
};
export const isRequest: Guard<CreateJobRequest> = (v): v is CreateJobRequest => obj(v) && str(v.url) && ['page', 'page-spa', 'prefix', 'host', 'domain'].includes(String(v.scope)) && num(v.pageLimit) && num(v.timeLimitMinutes) && optional(v.options, isOptions);
export const isUser: Guard<CurrentUser> = (v): v is CurrentUser => obj(v) && str(v.username) && strings(v.groups) && optional(v.email, str);
export const isRule: Guard<SelectorRule> = (v): v is SelectorRule => obj(v) && str(v.selector) && ['hide', 'block'].includes(String(v.action)) && optional(v.urlPrefix, str);
export const isEstimate: Guard<Estimate> = (v): v is Estimate => obj(v) && fields(v, [], ['lowerBytes','upperBytes','expectedBytes','samplePages','discoveredPages','sharedBytes','marginalPageBytes','peakDiskBytes']) && bool(v.unknownScope) && strings(v.assumptions) && strings(v.warnings) && optional(v.measured, bool) && optional(v.method, str);
export const isJob: Guard<Job> = (v): v is Job => obj(v) && id(v.id) && fields(v, ['createdAt','updatedAt','createdBy']) && ['queued','starting','running','cancelling','packaging','paused','partial','completed','failed','cancelled'].includes(String(v.status)) && isRequest(v.request) && optional(v.progress, p => fields(p, [], ['pagesDone','pagesQueued','pagesFailed'])) && ['archiveFile','archiveId','error','stopReason'].every(k => optional(v[k], str)) && ['archiveBytes','bytesStored','bytesDownloaded'].every(k => optional(v[k], num)) && optional(v.canResume, bool) && optional(v.estimate, isEstimate);
export const isZims: Guard<ZimListing> = (v): v is ZimListing => obj(v) && Array.isArray(v.zims) && v.zims.every(z => fields(z, ['name'], ['bytes'])) && optional(v.readerUrl, str);
export const isPage: Guard<PageRecord> = (v): v is PageRecord => obj(v) && fields(v, ['url','title','ts','text'], ['bytes','status']) && strings(v.resourceUrls);
export const isResource: Guard<ResourceRecord> = (v): v is ResourceRecord => obj(v) && fields(v, ['url','mime','digest','domain'], ['status','bytes']) && strings(v.pages);
export const isVerification: Guard<Verification> = (v): v is Verification => obj(v) && bool(v.valid) && str(v.checkedAt) && Array.isArray(v.checks) && v.checks.every(c => fields(c,['name','status','details'])) && strings(v.warnings);
export const isReport: Guard<ArchiveReport> = (v): v is ArchiveReport => obj(v) && fields(v, ['sha256','title','description'], ['archiveBytes','uniquePayloadBytes','duplicatePayloadBytes','metadataBytes']) && optional(v.pages,listOf(isPage)) && optional(v.resources,listOf(isResource)) && strings(v.warnings) && strings(v.dependencies);
export const isArchive: Guard<Archive> = (v): v is Archive => obj(v) && id(v.id) && fields(v,['createdAt','updatedAt','createdBy','url','title','archiveFile','sha256','collection','notes'], ['archiveBytes']) && strings(v.tags) && bool(v.favorite) && bool(v.trashed) && ['complete','partial','imported','derived','repair'].includes(String(v.captureStatus)) && strings(v.dependencies) && listOf(isRule)(v.cleanRules) && optional(v.request,isRequest) && optional(v.report,isReport) && optional(v.verification,isVerification) && optional(v.parentId,id) && optional(v.stopReason,str);
export const isPreflight: Guard<Preflight> = (v): v is Preflight => obj(v) && strings(v.urls) && Array.isArray(v.groups) && v.groups.every(g => fields(g,['prefix'],['pages'])) && isEstimate(v.estimate) && strings(v.warnings);
export const isComparison: Guard<ComparisonReport> = (v): v is ComparisonReport => obj(v) && ['addedPages','removedPages','changedPages','unchangedPages','addedResources','removedResources','changedResources','warnings'].every(k=>strings(v[k]));
export const isHit: Guard<SearchHit> = (v): v is SearchHit => obj(v) && id(v.archiveId) && fields(v,['url','title','snippet','replayUrl']) && optional(v.ts,str) && optional(v.captureTimestamp,str);
export const isRecipe: Guard<Recipe> = (v): v is Recipe => obj(v) && id(v.id) && fields(v,['name','createdAt','updatedAt'],['version']) && isRequest(v.request);
export const isSchedule: Guard<Schedule> = (v): v is Schedule => obj(v) && id(v.id) && id(v.recipeId) && fields(v,['nextRunAt'],['intervalMinutes']) && bool(v.enabled) && ['lastRunAt','lastJobId','lastError'].every(k=>optional(v[k],str));
export const isProfile: Guard<Profile> = (v): v is Profile => obj(v) && id(v.id) && fields(v,['name','createdAt','updatedAt']) && bool(v.available) && optional(v.expiresAt,str);
export const isJobResult: Guard<{jobId:string}> = (v): v is {jobId:string} => obj(v) && id(v.jobId);
export const isExportResult: Guard<{archiveId?:string;downloadUrl?:string}> = (v): v is {archiveId?:string;downloadUrl?:string} => obj(v) && ((id(v.archiveId)) || (str(v.downloadUrl) && safeDownload(v.downloadUrl) !== undefined));
export const isObject: Guard<Record<string,unknown>> = obj;
export const message = (e: unknown) => e instanceof Error ? e.message : String(e);
export const segment = (value: string) => encodeURIComponent(value);
export const archivePath = (id: string) => `/api/archives/${segment(id)}`;
export const detailLink = (id: string, url?: string, ts?: string) => `/?${new URLSearchParams({archive:id,...(url?{url}:{}),...(ts?{ts}:{})})}`;
export const safeDownload = (value: string): string | undefined => {
  try { const u = new URL(value, window.location.origin); return u.origin === window.location.origin && u.pathname.startsWith('/api/') && !u.username && !u.password ? u.pathname+u.search+u.hash : undefined; } catch { return undefined; }
};
export const safeExternal = (value: string | null | undefined): string | undefined => {
  try { const u = new URL(value || ''); return ['http:','https:'].includes(u.protocol) && !u.username && !u.password ? u.href : undefined; } catch { return undefined; }
};
export async function api<T>(path: string, guard: Guard<T>, init: RequestInit = {}): Promise<T> {
  const response = await fetch(path, {credentials:'same-origin', ...init});
  if (!response.ok) {
    const body: unknown = await response.json().catch(()=>null);
    throw new Error(obj(body) && str(body.error) ? body.error : `Request failed (${response.status})`);
  }
  const value: unknown = await response.json().catch(()=>{throw new Error('Server returned invalid JSON');});
  if (!guard(value)) throw new Error('Server returned an unexpected response shape. Previous data is retained.');
  return value;
}
export function json(method: string, value: unknown = {}): RequestInit { return {method, headers:{'content-type':'application/json'},body:JSON.stringify(value)}; }
export async function mutate(path: string, init: RequestInit = json('POST')): Promise<void> {
  const response = await fetch(path, {credentials:'same-origin', ...init});
  if (!response.ok) { const b: unknown = await response.json().catch(()=>null); throw new Error(obj(b) && str(b.error) ? b.error : `Request failed (${response.status})`); }
  if (response.status !== 204) { const b: unknown = await response.json().catch(()=>null); if (!obj(b)) throw new Error('Unexpected action response; refresh to confirm the result.'); }
}
export const bytes = (n: number | undefined): string => {
  if (n === undefined) return 'Not reported';
  const units = ['B','KiB','MiB','GiB','TiB']; let v=n,i=0;
  while(v>=1024&&i<units.length-1){v/=1024;i++;}
  return `${i===0?Math.round(v):v.toFixed(v>=10?0:1)} ${units[i]}`;
};
export const stamp = (v: string | undefined) => { if(!v) return 'Not reported'; const d=new Date(v); return Number.isNaN(d.valueOf())?v:d.toLocaleString(); };
export const isSummary: Guard<import('./types').ArchiveSummary> = (v): v is import('./types').ArchiveSummary => obj(v) && id(v.id) && fields(v,['createdAt','updatedAt','url','title','collection'],['archiveBytes']) && strings(v.tags) && bool(v.favorite) && bool(v.trashed) && ['complete','partial','imported','derived','repair'].includes(String(v.captureStatus)) && optional(v.visibility,str) && optional(v.pageCount,num) && optional(v.resourceCount,num);
export const isOperation: Guard<import('./types').OperationResult> = (v): v is import('./types').OperationResult => isJobResult(v) || isExportResult(v);
