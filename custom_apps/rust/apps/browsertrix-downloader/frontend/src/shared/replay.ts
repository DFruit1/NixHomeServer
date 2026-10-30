import type { Archive, SelectorRule } from './types';
import { archivePath } from './api';
// Preview documents are untrusted and opaque. A sibling frame must never supply rules.
export function selectionMessage(event: Pick<MessageEvent,'origin'|'source'|'data'>, frame: Window | null | undefined, url: string): {selector:string;matches:number;url:string} | undefined {
  if(!frame||event.source!==frame||event.origin!=='null')return;
  const d:unknown=event.data;
  if(typeof d!=='object'||d===null)return;
  const v=d as Record<string,unknown>;
  if(v.type!=='web-archives:selection'||typeof v.selector!=='string'||!v.selector||v.selector.length>1000||v.url!==url||typeof v.matches!=='number'||!Number.isInteger(v.matches)||v.matches<1||v.matches>10000)return;
  return {selector:v.selector,matches:v.matches,url};
}
export async function replayLink(archive: Pick<Archive,'id'|'sha256'|'cleanRules'>, username:string, clean:boolean, url:string, ts:string, origin=window.location.origin): Promise<string> {
  const rules:SelectorRule[]=clean?archive.cleanRules.filter(r=>r.action==='hide'):[];
  if(rules.length>100||JSON.stringify(rules).length>32000)throw new Error('Clean replay rules exceed the bounded preview limit.');
  const identity=JSON.stringify([username,archive.id,archive.sha256,clean,archive.cleanRules]);
  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(identity));
  const hash=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');
  // Encode apostrophes too: the pinned viewer emits script src in single quotes.
  const fragment=encodeURIComponent(JSON.stringify(rules)).replace(/[!'()*]/g,c=>'%'+c.charCodeAt(0).toString(16).toUpperCase());
  const config={injectScripts:clean?[`${origin}/replay/clean.js#${fragment}`]:[],liveRedirectOnNotFound:false};
  const query=new URLSearchParams({source:new URL(archivePath(archive.id)+'/replay.json',origin).href,customColl:'wa-'+hash,config:JSON.stringify(config),noCache:'1',embed:'full',swName:'sw-clean.js'});
  const target=new URLSearchParams({view:'replay',...(url?{url}:{}),...(ts?{ts:ts.replace(/[^0-9]/g,'').slice(0,14)}:{})});
  return `/replay/index.html?${query}#${target}`;
}
