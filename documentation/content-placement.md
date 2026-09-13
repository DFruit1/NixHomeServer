# Where Documents Go

This server has three different libraries for three different reading and
retrieval jobs. Picking the right one keeps each app's search, permissions, and
backups useful instead of mixing scanned paperwork into a book catalogue or
long-form reading into a document archive.

The short rule:

| You have… | Put it in | Why |
| --- | --- | --- |
| Loose/short documents, paperwork, scans, or one-off PDFs you need to find by keyword later | **Paperless** (`documents.<domain>`) | OCR, correspondents, tags, dates, and a document-centric workflow; federated into unified Search |
| A book you read continuously from cover to cover | **Kavita** (`books.<domain>`) | Reader-first UI for EPUB/PDF/CBZ/CBR with per-user progress, collections, and OPDS |
| A technical/reference book or manual you look things up in and want catalogued and full-text searched | **Calibre-Web** (`calibre.<domain>`) | Calibre library metadata (authors, series, tags, publishers) plus full-text indexing in unified Search |

## Paperless — personal documents, papers, and reports

Paperless is the filing cabinet. It is for documents that arrive or get scanned,
that are short relative to a book, and that you retrieve by searching a phrase,
a correspondent, or a date. It owns OCR and its own document index, and the
unified Search app federates Paperless results at query time.

Put these in Paperless:

- Household and financial paperwork: utility bills, bank and credit-card
  statements, mortgage statements, invoices, receipts, tax returns and
  notices of assessment, superannuation statements, payslips.
- Insurance and medical records: policy documents, claim correspondence,
  referrals, pathology and imaging reports, vaccination records.
- Legal and contractual documents: leases and rental agreements, employment
  contracts, NDAs, terms of service, warranty cards, purchase agreements.
- Identity and government records: passport and licence scans, visas,
  certificates, rates notices, vehicle registration.
- Personal correspondence and records: scanned letters, school and childcare
  notices, event tickets and itineraries, appliance manuals you want to find by
  model number.
- Technical papers and reports as documents: white papers, research papers,
  standards PDFs, vendor datasheets, consultancy reports, incident postmortems,
  meeting minutes, lab reports, and annual reports. These are usually short or
  reference-by-search, so the document archive fits better than a book library.
- Anything you scan or email to yourself that you never expect to read
  linearly.

Do **not** use Paperless for a novel or a textbook you read start to finish;
the reading experience and progress tracking live in Kavita and Calibre-Web.

How to add: drop files into the Paperless consume directory (or the Homepage
Files/SFTP surfaces that route there); Paperless OCRs, tags, and indexes them
automatically.

## Kavita — novels, comics, and books read continuously

Kavita is the reader. It is for books you open and read page by page, with
per-user progress, reading lists, and OPDS support for mobile reader apps. It
is not part of unified Search; use Kavita's own library search.

Put these in Kavita:

- Fiction and long-form non-fiction: novels, novellas, short-story
  collections, literary fiction, genre fiction (science fiction, fantasy,
  crime, romance, horror), historical fiction.
- Memoir, biography, autobiography, essays, and poetry.
- Manga, manhwa, manhua, light novels, and webtoon collections.
- Comics, graphic novels, and collected trade paperbacks in CBZ/CBR.
- Children's and young-adult books, picture books, and illustrated readers.
- General-interest ebooks (cooking, travel, gardening, self-help, history) that
  you read through rather than use as a lookup reference.
- Any EPUB/PDF/CBZ/CBR you want on your phone in a reader app with progress
  sync.

How to add: place books under the shared Kavita roots (`_Books/_Ebooks`,
`_Books/_Comics`, `_Books/_Manga`) or the per-user equivalents; Kavita's folder
watcher imports them.

## Calibre-Web — technical books and reference manuals

Calibre-Web is the technical reference catalogue. It serves a real Calibre
library, so books carry structured metadata (authors, series, tags, publisher,
identifiers, description) and can be browsed, filtered, and categorised.
Unlike Kavita, the Calibre library is indexed full-text by the unified Search
app: title, author, series, tags, description, and the extracted body text of
EPUB/PDF books all become searchable at `https://search.<domain>`.

Put these in Calibre-Web:

- Engineering and science textbooks: mechanical, electrical, civil, chemical,
  aerospace, materials, thermodynamics, fluid mechanics, control systems.
- University course and reference texts: calculus, linear algebra, statistics,
  discrete maths, physics, chemistry, biology.
- Software and computing references: programming-language books, framework and
  library guides, algorithms and data-structures texts, database and
  distributed-systems references, operating-systems internals, security
  handbooks.
- Professional and certification references: PMBOK/PRINCE2, CCNA/CCNP, AWS and
  cloud certification guides, CPA/legal study guides, medical reference texts.
- Standards, specifications, and handbooks: AS/NZS, ISO, IEC, IEEE, SAE
  standards; mechanical/electrical/structural handbooks; machining and
  materials data handbooks.
- Vendor reference material: datasheets, application notes, reference designs,
  integration manuals, and product technical manuals you look things up in.
- Encyclopaedic or dictionary-style technical works, formula collections,
  conversion tables, and lab/experiment manuals.
- Reference-style conference proceedings, edited technical volumes, and
  annotated technical reports that you consult repeatedly rather than read once.

How to add:

- Through the Calibre-Web UI (`Upload`) as the Calibre-Web local admin account.
  Uploaded books are registered in `metadata.db` and appear in the catalogue.
- In bulk from the server, importing into the shared library directly:

  ```bash
  sudo -u calibre-web calibredb add \
    --with-library /mnt/data/shared/_Calibre/Library \
    /path/to/technical-books/*.pdf
  ```

  Calibre-Web and the Search indexer pick up the new books on their next pass
  (Search re-syncs hourly; `sudo systemctl restart search-index.service` forces
  a pass).

## Choosing between the three

- Is it short, scannable, or paperwork? → **Paperless**.
- Will you read it front to back, especially on a phone or tablet? → **Kavita**.
- Will you look things up in it, cite it, or want it in a tagged technical
  catalogue and full-text search? → **Calibre-Web**.
- A technical PDF that is a one-off report belongs in Paperless; the same PDF as
  a lasting reference book belongs in Calibre-Web. When in doubt for a technical
  book, choose Calibre-Web so it is both catalogued and searchable.
- A novel scanned to PDF still belongs in Kavita; a textbook you only skim once
  can still go in Calibre-Web because the cost is low and the catalogue stays
  complete.

## Search coverage

Unified Search (`search.<domain>`) currently indexes: Paperless (live-federated
via its API), Calibre-Web (full-text), Kiwix ZIMs, Browsertrix web archives,
the mail archive, FreshRSS entries, and the Jellyfin, Audiobookshelf, and Kavita
libraries (metadata snapshots exported by Media Manager). Kavita results carry
catalog metadata (title, series, authors, genres, tags, description) rather
than page text, so keep using Kavita's own reader search and OPDS feeds when you
need in-book search.
