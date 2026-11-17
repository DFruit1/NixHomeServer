# Search extraction and relevance

Search indexes source text in PostgreSQL and projects it to Solr. The existing
semantic search then selects passages from that text. No extraction network
requests run on the search request path.

HTML extraction reads each table cell as a block and omits visual borders and
link footnotes. This preserves phrases in layout emails and avoids embedding
padding. Named mail attachments have separate titles and bodies, but share a
result group with their message. Copies of the same message in different mail
folders retain that grouping. Important-folder mail and favourite photos receive
a small keyword-ranking preference.

PDF sections use Poppler outline destinations, preserving chapter names across
page boundaries and size-limited sections. The extractor invokes `pdftohtml`
beside the configured `pdftotext`; unavailable or unreadable outlines fall back
to page ranges. Scanned-page OCR remains in place.

Jellyfin exports series overviews, recurring cast and genres separately. Search
emits one series result per owner, while episodes retain their own synopsis,
guests, episode-specific genres and incidental subtitle text. Older snapshots
without series metadata retain episode details. Photos with at least 600 readable
OCR characters and 40 words retain the photo link but index that text at body
weight and occupy their own result slot. Other photos keep day/place grouping.

Book editions with an explicit `work_id`, or recognised complete Bible edition
titles, share one work result slot, showing the strongest matching edition.
Commentaries and study guides are excluded from automatic grouping. This uses
the existing grouping model rather than a new two-edition UI or an alternatives
count. Other editions remain indexed and can be selected by a more specific
query. Language preference is a mild keyword boost: explicit language names
select their language; ASCII queries otherwise prefer English, and other scripts
have no guessed preference. It is a library-language fallback, not automatic
language detection. Semantic ranking may reorder these candidates.

Personal-document discovery excludes common plain-text project note names and detects
projects from source files as well as build manifests. Transcript folders retain
their own rules. Browsertrix keeps the newest exact-URL capture, retaining query
strings and the replay link. The selection buffers at most 256 MB of body text;
exceeding that budget fails extraction and retains the previous source index.

Article fetching saves citation authors, abstracts, journal, DOI and publication
date beside the downloaded text. Existing text-only entries are refreshed once,
under the existing fetch budget, failure backoff and network restrictions. Feed
indexing reads those local files without fetching URLs.

Extraction revisions invalidate affected source fingerprints; projection revision
5 rebuilds the Solr mapping. The first indexing and embedding pass after deployment
can therefore take longer. No source files or original media are modified.
Deployment, authenticated searches and live timing remain separate verification
steps; local extraction fixtures do not establish production latency or ranking.
