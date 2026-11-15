{ lib, vars, ... }:

{
  options.repo.search.paths = {
    models = lib.mkOption {
      type = lib.types.str;
      default = "${vars.dataRoot}/search/models";
      description = "Retained, hash-verified semantic search weights on the data pool.";
    };
    solrHome = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/solr/home";
      description = "Solr home (cores and configsets) for the Search platform.";
      readOnly = true;
    };

    solrState = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/solr";
      description = "Writable Solr state root (logs, pid files, home).";
      readOnly = true;
    };

    pdfArchive = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/search/pdf-archive";
      description = ''
        Persistent archive of PDFs that the admin-only archive pass discovered
        in FreshRSS entries. The download manifest lives in the search
        database; this directory holds the files.
      '';
      readOnly = true;
    };

    articleArchive = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/search/article-archive";
      description = ''
        Text of the articles behind feed entries whose feed carries only a
        summary, saved by the article fetch pass and read by the indexer.
      '';
      readOnly = true;
    };
  };
}
