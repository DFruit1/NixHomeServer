{ lib, ... }:

{
  options.repo.search.paths = {
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
  };
}
