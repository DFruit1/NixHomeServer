// Risk basis: an untrusted archive/sibling frame must not inject script/CSS into
// authenticated UI, or reuse private/clean replay state across viewers/owners.
import { describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { replayLink, selectionMessage } from '../replay';

const archive={id:'a1',sha256:'a'.repeat(64),cleanRules:[{action:'hide' as const,selector:`[title="it's <private>"]`,urlPrefix:'https://example.org/'}]};
describe('replay isolation',()=>{
  it('binds opaque preview messages to the actual source window and requested page',()=>{
    const frame={} as Window;
    const data={type:'web-archives:selection',selector:'.banner',url:'https://example.org/',matches:1};
    expect(selectionMessage({source:frame,origin:'null',data},frame,data.url)?.selector).toBe('.banner');
    expect(selectionMessage({source:{} as Window,origin:'null',data},frame,data.url)).toBeUndefined();
    expect(selectionMessage({source:frame,origin:'https://example.org',data},frame,data.url)).toBeUndefined();
    expect(selectionMessage({source:frame,origin:'null',data},frame,'https://other.org/')).toBeUndefined();
    expect(selectionMessage({source:frame,origin:'null',data:{...data,selector:'x'.repeat(1001)}},frame,data.url)).toBeUndefined();
  });
  it('separates original, clean and owner cache identities and encodes injected URLs safely',async()=>{
    const original=await replayLink(archive,'alice',false,'https://example.org/','2026-01-02T03:04:05Z','https://archives.test');
    const clean=await replayLink(archive,'alice',true,'https://example.org/','','https://archives.test');
    const originalAgain=await replayLink(archive,'alice',false,'https://example.org/','2026-01-02T03:04:05Z','https://archives.test');
    const otherOwner=await replayLink(archive,'bob',false,'https://example.org/','','https://archives.test');
    const p=(s:string)=>new URL(s,'https://archives.test').searchParams;
    expect(originalAgain).toBe(original);
    expect(p(original).get('customColl')).not.toBe(p(clean).get('customColl'));
    expect(p(original).get('customColl')).not.toBe(p(otherOwner).get('customColl'));
    expect(p(original).get('source')).toBe('https://archives.test/api/archives/a1/replay.json');
    expect(p(original).get('swName')).toBe('sw-clean.js');
    expect(JSON.parse(p(original).get('config')!).injectScripts).toEqual([]);
    const script=JSON.parse(p(clean).get('config')!).injectScripts[0] as string;
    expect(script).not.toMatch(/[<>']/);
    expect(JSON.parse(decodeURIComponent(new URL(script).hash.slice(1)))).toEqual(archive.cleanRules);
  });
  it('applies only validated matching selectors with style properties and never builds CSS source',()=>{
    const setProperty=vi.fn();
    class Element {style={setProperty};}
    const selectors:string[]=[];
    const rules=[{action:'hide',selector:'.banner',urlPrefix:'https://example.org/'},{action:'hide',selector:'body{background:url(https://leak.test)}'},{action:'hide',selector:'.private',urlPrefix:'https://other.org/'}];
    const document={currentScript:{src:'https://archives.test/replay/clean.js#'+encodeURIComponent(JSON.stringify(rules))},readyState:'complete',documentElement:{},querySelectorAll:(selector:string)=>{selectors.push(selector);if(selector.includes('{'))throw new Error('Invalid selector');return [new Element()];}};
    const window={WB_wombat_location:{href:'https://example.org/'},addEventListener:()=>{},setTimeout:()=>0};
    runInNewContext(readFileSync(new URL('../../../public/replay/clean.js',import.meta.url),'utf8'),{document,window,URL,MutationObserver:class {observe(){}},HTMLElement:Element,SVGElement:class {}});
    expect(selectors).toEqual(['.banner','body{background:url(https://leak.test)}']);
    expect(setProperty).toHaveBeenCalledExactlyOnceWith('display','none','important');
  });
  it('permits only the fixed local clean script through the replay proxy',()=>{
    const handlers:Record<string,(event:unknown)=>void>={};
    const fetch=vi.fn(()=>Promise.resolve({}));
    runInNewContext(readFileSync(new URL('../../../public/replay/sw-clean.js',import.meta.url),'utf8'),{
      URL,fetch,importScripts:vi.fn(),self:{location:{href:'https://archives.test/replay/sw-clean.js?serveIndex=1'},addEventListener:(type:string,handler:(event:unknown)=>void)=>{handlers[type]=handler;}}
    });
    const respondWith=vi.fn(),stopImmediatePropagation=vi.fn();
    const prefix='https://archives.test/replay/static/proxy/';
    for(const url of [prefix+'https://leak.test/clean.js',prefix+'https://archives.test/replay/clean.js/extra',prefix+'https://archives.test/replay/clean.js?url=https://leak.test'])handlers.fetch({request:{url,method:'GET'},respondWith,stopImmediatePropagation});
    expect(respondWith).not.toHaveBeenCalled();
    handlers.fetch({request:{url:prefix+'https://archives.test/replay/clean.js#encoded-rules',method:'GET'},respondWith,stopImmediatePropagation});
    expect(fetch).toHaveBeenCalledExactlyOnceWith('https://archives.test/replay/clean.js',{credentials:'same-origin',redirect:'error',cache:'no-store'});
    expect(respondWith).toHaveBeenCalledOnce();
    expect(stopImmediatePropagation).toHaveBeenCalledOnce();
  });
});
