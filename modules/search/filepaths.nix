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
  };
}
