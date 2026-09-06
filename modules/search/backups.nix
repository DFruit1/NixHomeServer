{ config, lib, ... }:

{
  config = lib.mkIf config.repo.search.enable {
    repo.backups = {
      # The search database is the system of record: Solr cores are derived
      # state that search-solr-core-bootstrap and the indexer rebuild, so the
      # Solr data directory is deliberately not backed up.
      appStateEntries = [
        {
          app = "search";
          component = "postgresql";
          stateRoot = config.services.postgresql.dataDir;
          payloadRoots = [ ];
          notes = "Search metadata and extracted text; a logical dump is published as dumps/search.pgdump.";
        }
        {
          app = "search";
          component = "solr";
          stateRoot = "/var/lib/solr";
          payloadRoots = [ ];
          notes = "Derived Solr index state; rebuilt from the search database, not backed up.";
        }
      ];
      postgresqlDumps = [
        {
          database = "search";
          user = "search";
          outputName = "search.pgdump";
        }
      ];
    };
  };
}
