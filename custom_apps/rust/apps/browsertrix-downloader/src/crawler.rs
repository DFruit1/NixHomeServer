use crate::model::{CrawlScope, CreateJobRequest, JobProgress};
use serde_json::Value;
use std::{ffi::OsString, path::Path};

pub fn build_crawl_args(
    request: &CreateJobRequest,
    collection: &str,
    crawl_dir: &Path,
    image: &str,
) -> Vec<OsString> {
    // Use custom collection name if provided, otherwise fall back to the provided collection (job ID)
    let collection_name = request.collection.as_deref().unwrap_or(collection);
    let mut args: Vec<OsString> = vec![
        "run".into(),
        "--rm".into(),
        "--name".into(),
        format!("web-archive-{collection}").into(),
        "--shm-size=1g".into(),
        "--cap-add=SYS_ADMIN".into(),
        "--security-opt=seccomp=unconfined".into(),
        "--pid=host".into(),
        "--uts=host".into(),
        "-v".into(),
        format!("{}:/crawls", crawl_dir.display()).into(),
        "--tmpfs".into(),
        format!("/crawls/collections/{collection_name}/profile:rw,nosuid,nodev,mode=0700").into(),
        "--tmpfs".into(),
        format!("/crawls/collections/{collection_name}/downloads:rw,nosuid,nodev,mode=0700").into(),
        "--network=slirp4netns:allow_host_loopback=false".into(),
        image.into(),
        "crawl".into(),
        "--url".into(),
        request.url.clone().into(),
        "--collection".into(),
        collection_name.into(),
        "--cwd".into(),
        "/crawls".into(),
        "--scopeType".into(),
        request.scope.as_str().into(),
        "--depth".into(),
        if request.scope == CrawlScope::Page {
            "0".into()
        } else {
            request.options.depth.to_string().into()
        },
        "--limit".into(),
        request.page_limit.to_string().into(),
        "--timeLimit".into(),
        (request.time_limit_minutes * 60).to_string().into(),
        "--workers".into(),
        "1".into(),
        "--generateWACZ".into(),
        "--screenshot".into(),
        "view".into(),
        "--text".into(),
        "to-pages,to-warc,final-to-warc".into(),
        "--saveState".into(),
        "always".into(),
        "--saveStateInterval".into(),
        "30".into(),
        "--saveStateHistory".into(),
        "3".into(),
        "--statsFilename".into(),
        "/crawls/stats.json".into(),
        "--serviceWorker".into(),
        "disabled".into(),
        "--behaviorTimeout".into(),
        request.options.behavior_timeout_seconds.to_string().into(),
        "--postLoadDelay".into(),
        request.options.post_load_delay_seconds.to_string().into(),
        "--lang".into(),
        request.options.language.clone().into(),
    ];
    if let Some(bytes) = request.options.size_limit_bytes {
        args.extend(["--sizeLimit".into(), bytes.to_string().into()]);
    }
    if request.scope == CrawlScope::PageSpa {
        args.push("--allowHashUrls".into());
    }
    if crawl_dir.join("capture.json").is_file() {
        args.extend(["--config".into(), "/crawls/capture.json".into()]);
    }
    args
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CrawlLogProgress {
    pub pages_done: Option<u64>,
    pub pages_queued: Option<u64>,
    pub pages_failed: Option<u64>,
}

pub fn parse_crawl_log_line(line: &str) -> Option<CrawlLogProgress> {
    let trimmed = line.trim();
    if !trimmed.starts_with('{') {
        return None;
    }
    let value = serde_json::from_str::<Value>(trimmed).ok()?;
    let mut progress = CrawlLogProgress::default();
    if let Some(stats) = value.get("stats").and_then(Value::as_object) {
        progress.pages_done = stats.get("done").and_then(json_u64);
        progress.pages_queued = stats.get("queued").and_then(json_u64);
        progress.pages_failed = stats.get("failed").and_then(json_u64);
    }
    if value.get("message").and_then(Value::as_str) == Some("Crawl statistics") {
        if let Some(details) = value.get("details") {
            progress.pages_done = details.get("crawled").and_then(json_u64);
            progress.pages_failed = details.get("failed").and_then(json_u64);
            progress.pages_queued = details.get("total").and_then(json_u64).map(|total| {
                total
                    .saturating_sub(progress.pages_done.unwrap_or(0))
                    .saturating_sub(progress.pages_failed.unwrap_or(0))
            });
        }
    }
    if value.get("message").and_then(Value::as_str) == Some("pageCrawled")
        && progress.pages_done.is_none()
    {
        progress.pages_done = Some(1);
    }
    (progress != CrawlLogProgress::default()).then_some(progress)
}

pub fn merge_progress(current: &JobProgress, update: &CrawlLogProgress) -> JobProgress {
    JobProgress {
        pages_done: update
            .pages_done
            .unwrap_or(current.pages_done)
            .max(current.pages_done),
        pages_queued: update.pages_queued.unwrap_or(current.pages_queued),
        pages_failed: update.pages_failed.unwrap_or(current.pages_failed),
    }
}

pub fn log_line_text(line: &str) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with('{') {
        let value = match serde_json::from_str::<Value>(trimmed) {
            Ok(value) => value,
            Err(_) => return Some(shorten(trimmed)),
        };
        let text = ["message", "details", "page"]
            .into_iter()
            .filter_map(|key| value.get(key).and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join(" ");
        return (!text.is_empty()).then(|| shorten(&text));
    }
    Some(shorten(trimmed))
}

fn json_u64(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
        .or_else(|| {
            value
                .as_f64()
                .filter(|number| number.is_finite() && *number >= 0.0)
                .map(|number| number as u64)
        })
}

fn shorten(value: &str) -> String {
    value.chars().take(240).collect()
}

/// Only flags present in Browsertrix Crawler v1.14.3/src/util/argParser.ts.
/// Policy requiring response interception is implemented by its supported driver.
pub fn write_capture_config(
    request: &CreateJobRequest,
    path: &Path,
    resume: Option<&str>,
) -> Result<(), String> {
    let options = &request.options;
    let mut seeds = vec![request.url.clone()];
    seeds.extend(options.seeds.iter().cloned());
    seeds.sort();
    seeds.dedup();
    let mut config = serde_json::json!({"seeds":seeds,"behaviors":options.behaviors,"clickSelector":options.click_selector,"blockAds":options.block_ads,"driver":"file:///crawls/policy.js","policy":options,"blockMessage":"Intentionally omitted by frozen capture policy","adBlockMessage":"Intentionally omitted advertisement"});
    // JS negative lookahead gives allow exceptions priority over each native block.
    let exception = options
        .allow_rules
        .iter()
        .map(|v| format!("(?:{v})"))
        .collect::<Vec<_>>()
        .join("|");
    let blocks = options
        .block_rules
        .iter()
        .map(|block| {
            if exception.is_empty() {
                block.clone()
            } else {
                format!("^(?!.*(?:{exception})).*(?:{block})")
            }
        })
        .collect::<Vec<_>>();
    config["blockRules"] = serde_json::json!(blocks);
    let mut excludes = options.exclude.clone();
    // Native includes extend scope by OR. Inclusion filters must restrict pages
    // while leaving resource dependencies independent, so use a page exclusion.
    if !options.include.is_empty() {
        excludes.push(format!(
            "^(?!(?:{})).*",
            options
                .include
                .iter()
                .map(|p| format!("(?:{p})"))
                .collect::<Vec<_>>()
                .join("|")
        ));
    }
    if !excludes.is_empty() {
        config["exclude"] = serde_json::json!(excludes);
    }
    // Saved YAML contains native crawler state. Yargs loads it first, then exact CLI
    // budget/recipe values override stale settings without --overwrite.
    if let Some(saved) = resume {
        config["resumeConfig"] = serde_json::json!(saved);
    }
    std::fs::write(
        path.join("capture.json"),
        serde_json::to_vec(&config).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    std::fs::write(path.join("policy.js"), POLICY_DRIVER).map_err(|e| e.to_string())
}

const POLICY_DRIVER: &str = r#"
import fs from 'node:fs';
const settings=JSON.parse(fs.readFileSync('/crawls/capture.json','utf8'));
const p=settings.policy;
const installed=new WeakSet();
export default async function({page,data,crawler,seed}) {
  await page.setViewport({width:p.viewportWidth,height:p.viewportHeight});
  if (!installed.has(page)) {
    installed.add(page);
    crawler.browser.interceptRequest(page,async request=>{if(p.allowRules.some(rule=>new RegExp(rule).test(request.url()))){try{await request.continue({},10);}catch{}}});
    const session=await page.createCDPSession();
    await session.send('Fetch.enable',{patterns:[{urlPattern:'*',requestStage:'Response'}]});
    session.on('Fetch.requestPaused',async e=>{
      const headers=e.responseHeaders||[];
      const length=Number(headers.find(h=>h.name.toLowerCase()==='content-length')?.value||0);
      const type=(headers.find(h=>h.name.toLowerCase()==='content-type')?.value||'').toLowerCase();
      const allow=p.allowRules.some(rule=>new RegExp(rule).test(e.request.url));
      const media=/^(video|audio)\//.test(type);
      const image=/^image\//.test(type);
      const block=!allow && ((p.maxResourceBytes && length>p.maxResourceBytes)||(media && p.media!=='full')||(image && p.media==='none'));
      try {if(block){await session.send('Fetch.failRequest',{requestId:e.requestId,errorReason:'BlockedByClient'});console.log(JSON.stringify({message:'policyOmission',details:e.request.url,reason:length>p.maxResourceBytes?'resource-size':'media-policy'}));}else{await session.send('Fetch.continueRequest',{requestId:e.requestId});}}catch{}
    });
    await page.evaluateOnNewDocument((p)=>{
      if(p.media!=='full') {HTMLMediaElement.prototype.play=function(){return Promise.resolve();};}
      if(!p.alternateImages){new MutationObserver(()=>{document.querySelectorAll('[srcset]').forEach(n=>n.removeAttribute('srcset'));}).observe(document,{subtree:true,childList:true});}
      const apply=()=>{for(const rule of p.selectors){if(rule.urlPrefix&&!location.href.startsWith(rule.urlPrefix))continue;for(const element of document.querySelectorAll(rule.selector)){element.style.setProperty('display','none','important');if(rule.action==='block'){element.querySelectorAll('img,video,audio,iframe,source').forEach(n=>{n.removeAttribute('src');n.removeAttribute('srcset');});}}}};
      new MutationObserver(apply).observe(document,{subtree:true,childList:true});
    },p);
  }
  await crawler.loadPage(page,data,seed);
  const results=[];
  const context=crawler.recording===false ? (page.frames().slice(2)[0]||page) : page;
  for(const step of p.interactions||[]) {
    try {
      const element=await context.waitForSelector(step.selector,{timeout:3000});
      if(!element)throw new Error('click target missing');
      await element.click({timeout:3000});
      let pass=false;
      if(step.assertion==='text'){pass=await element.evaluate((n,expected)=>n.textContent.includes(expected),step.expected);}
      else {const result=await context.$(step.expected);const visible=result?await result.isVisible():false;pass=step.assertion==='visible'?visible:!visible;}
      results.push({name:`interaction:${step.selector}`,status:pass?'pass':'fail',details:step.assertion});
    }catch {results.push({name:`interaction:${step.selector}`,status:'fail',details:'click or assertion failed'});}
  }
  if(results.length)fs.appendFileSync('/crawls/interactions.jsonl',JSON.stringify({url:data.url,checks:results})+'\n');
}
"#;
