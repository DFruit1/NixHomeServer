import { component$, type QRL } from '@builder.io/qwik';
export const Feedback = component$<{error?:string;notice?:string;pending?:string}>(({error,notice,pending}) => <>
  <div role="status" aria-live="polite" aria-atomic="true">{pending && <p class="notice">{pending}</p>}{notice && <p class="notice">{notice}</p>}</div>
  {error && <p class="error" role="alert">{error}</p>}
</>);
export const Pager = component$<{offset:number;limit:number;total:number;busy:boolean;onPage$:QRL<(offset:number)=>void>}>(({offset,limit,total,busy,onPage$}) => <nav class="pager" aria-label="Result pages">
  <button type="button" disabled={busy||offset===0} onClick$={()=>onPage$(Math.max(0,offset-limit))}>Previous</button>
  <span>{total===0?'0 results':`${offset+1}–${Math.min(offset+limit,total)} of ${total}`}</span>
  <button type="button" disabled={busy||offset+limit>=total} onClick$={()=>onPage$(offset+limit)}>Next</button>
</nav>);
