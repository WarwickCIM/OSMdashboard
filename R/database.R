connect_osm_db <- function() {
  url <- Sys.getenv("DATABASE_URL", "")
  if (nzchar(url) && startsWith(url, "duckdb:///")) {
    # DATABASE_URL like "duckdb:///absolute/or/relative/path/to/file.duckdb"
    dbfile <- sub("^duckdb:///", "", url)
    return(DBI::dbConnect(duckdb::duckdb(), dbfile))
  }

  # Fallback: environment variable DUCKDB_PATH
  duck_path <- Sys.getenv("DUCKDB_PATH", "database/osm_changesets.duckdb")
  DBI::dbConnect(duckdb::duckdb(), duck_path)
}
