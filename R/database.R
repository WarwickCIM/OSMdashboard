#' Connect to the OSM DuckDB database
#'
#' @description Opens a DBI connection to the OSM Changesets DuckDB file.
#' It first checks the environment variable `DATABASE_URL` for a URL of the form
#' `duckdb:///path/to/osm_changesets.duckdb`. If not set, it falls back to
#' the environment variable `DUCKDB_PATH` (default:
#' `"database/osm_changesets.duckdb"`).
#'
#' @returns A DBI connection object (`DBI::DBIConnection`) to a DuckDB database.
#'   You are responsible for closing it with `DBI::dbDisconnect(con)`.
#' @export
#'
#' @examples
#' \dontrun{
#'   con <- connect_osm_db()
#'   # ... use the connection ...
#'   DBI::dbDisconnect(con)
#' }

#In the above example, dontrun is placed there as the database will not found on GitHub so these example
#checks will not execute 
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
