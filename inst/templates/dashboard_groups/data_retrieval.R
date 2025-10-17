library(OSMdashboard)
library(dplyr)
library(purrr)
library(lubridate)
library(sf)

# --------------------------------------------------
# Base folders (run this script FROM example_dashboard)
# --------------------------------------------------
dash_dir  <- normalizePath(getwd(), winslash = "/")              # .../OSMdashboard/example_dashboard
repo_root <- normalizePath(file.path(dash_dir, ".."), winslash = "/")  # .../OSMdashboard

# Tiny helper: build paths under example_dashboard
P <- function(...) file.path(dash_dir, ...)

# --------------------------------------------------
# Build group_users.csv from DB + group_definition.csv
# --------------------------------------------------
py_script <- file.path(repo_root, "python", "extract_group_users_from_definition.py")
db_path   <- file.path(repo_root, "database", "osm_changesets.duckdb")
group_def <- P("data", "metadata", "group_definition.csv")
group_out <- P("data", "metadata", "group_users.csv")

stopifnot("Python script not found"       = file.exists(py_script))
stopifnot("DB not found"                  = file.exists(db_path))
stopifnot("group_definition.csv missing"  = file.exists(group_def))
dir.create(dirname(group_out), recursive = TRUE, showWarnings = FALSE)

# Run Python safely
status <- system2("python", c(py_script, "--db", db_path, "--group-def", group_def, "--out", group_out),
                  stdout = TRUE, stderr = TRUE)
cat(paste(status, collapse = "\n"))

# --------------------------------------------------
# Read metadata
# --------------------------------------------------
group_info  <- read.csv(P("data", "metadata", "group_info.csv"))
group_users <- read.csv(P("data", "metadata", "group_users.csv"))

if (!"username" %in% names(group_users)) {
  stop("group_users.csv must have a 'username' column.")
}

# --------------------------------------------------
# Selected users
# --------------------------------------------------
selected_users <- unique(tolower(trimws(as.character(group_users$username))))
selected_users <- selected_users[nzchar(selected_users)]
if (length(selected_users) == 0) {
  message("No users found for this group (from group_definition.csv). Nothing to fetch.")
  dir.create(P("data","raw"), recursive = TRUE, showWarnings = FALSE)

  write.csv(data.frame(user=character(),
                       map_changesets=integer(), map_notes=integer(), traces=integer(),
                       diary=integer(), comments=integer(),
                       date_creation=as.Date(character()),
                       date_last_map_edit=as.Date(character())),
            P("data","raw","osm_user_details.csv"), row.names = FALSE)

  write.csv(data.frame(id=integer(), user=character(), created=as.POSIXct(character()),
                       min_lat=double(), min_lon=double(), max_lat=double(), max_lon=double()),
            P("data","raw","changesets.csv"), row.names = FALSE)

  write.csv(data.frame(changeset=integer(), key=character(), value=character()),
            P("data","raw","changesets_tags.csv"), row.names = FALSE)

  write.csv(data.frame(), P("data","raw","changesets_details.csv"), row.names = FALSE)

  write.csv(data.frame(user=character(), title=character(), timestamp=character()),
            P("data","raw","wiki_contributions.csv"), row.names = FALSE)

  write.csv(data.frame(), P("data","raw","contributions_diaries.csv"), row.names = FALSE)

  write.csv(data.frame(user=character(), map_changesets=integer(), map_notes=integer(),
                       traces=integer(), diary=integer(), comments=integer(),
                       date_creation=as.Date(character()), date_last_map_edit=as.Date(character()),
                       account_age=double(), map_activity_age=double(), wiki_edits=integer()),
            P("data","raw","contributions_summary.csv"), row.names = FALSE)
  quit(save = "no", status = 0)
}

# Cap
selected_users <- head(selected_users, 100)

# --------------------------------------------------
# User profile stats (with cache under example_dashboard/data/processed/.user_cache)
# --------------------------------------------------
cache_dir <- P("data", "processed", ".user_cache")
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
cache_path <- function(user) file.path(cache_dir, paste0(gsub("[^A-Za-z0-9._-]", "_", user), ".rds"))

fetch_user_polite <- function(user, sleep_min = 0.6, sleep_max = 1.4) {
  p <- cache_path(user)
  if (file.exists(p)) return(readRDS(p))
  Sys.sleep(runif(1, sleep_min, sleep_max))
  res <- tryCatch(OSMdashboard::get_contributions_osm_users(user), error = function(e) NULL)
  if (is.null(res) || nrow(res) == 0) return(NULL)
  saveRDS(res, p)
  res
}

osm_user_details <- map_dfr(selected_users, fetch_user_polite)
write.csv(osm_user_details, P("data","raw","osm_user_details.csv"), row.names = FALSE)

# --------------------------------------------------
# Changesets + details + tags
# --------------------------------------------------
safe_user_changesets <- function(user, n = 100) {
  tryCatch(OSMdashboard::get_contributors_changesets(user, n), error = function(e) NULL)
}

changesets <- map_dfr(selected_users, safe_user_changesets, n = 100)

if (nrow(changesets) == 0) {
  changesets <- tibble::tibble(
    id=integer(), user=character(), created=as.POSIXct(character()),
    min_lat=double(), min_lon=double(), max_lat=double(), max_lon=double()
  )
}

ids <- unique(changesets$id)
id_batches <- split(ids, ceiling(seq_along(ids)/200))
changesets_details <- map_dfr(
  id_batches,
  ~ tryCatch(get_changesets_details(.x), error = function(e) NULL)
)

changesets_tags <- tryCatch(
  extract_and_combine_tags(changesets_details),
  error = function(e) tibble::tibble()
)

write.csv(changesets, P("data","raw","changesets.csv"), row.names = FALSE)

if (nrow(changesets) > 0) {
  sf::st_write(changesets, dsn = P("data","raw","changesets.gpkg"), append = FALSE, quiet = TRUE)
}

write.csv(changesets_tags, P("data","raw","changesets_tags.csv"), row.names = FALSE)

# Keep 'tags' in details; drop 'members' only
details_out <- P("data","raw","changesets_details.csv")
if (is.null(changesets_details) || !is.data.frame(changesets_details) || nrow(changesets_details) == 0) {
  readr::write_csv(tibble::tibble(), details_out)
} else {
  changesets_details %>%
    dplyr::select(-dplyr::any_of("members")) %>%
    readr::write_csv(details_out)
}

# --------------------------------------------------
# Wiki
# --------------------------------------------------
wiki_contributions <- tryCatch(
  get_contributions_wiki(selected_users) %>%
    dplyr::select(-tags) %>%
    tibble::as_tibble(),
  error = function(e) tibble::tibble(user=character())
)

wiki_contributions_n <- wiki_contributions %>%
  count(user) %>%
  mutate(user = tolower(user)) %>%
  rename(wiki_edits = n)

write.csv(wiki_contributions, P("data","raw","wiki_contributions.csv"), row.names = FALSE)

# --------------------------------------------------
# Diaries
# --------------------------------------------------
users_diaries <- osm_user_details %>%
  mutate(user = tolower(user)) %>%
  filter(!is.na(diary), diary > 0) %>%
  pull(user) %>%
  unique()

contributions_diaries <- tryCatch(
  get_contributions_diaries(users_diaries),
  error = function(e) tibble::tibble()
)

write.csv(contributions_diaries, P("data","raw","contributions_diaries.csv"), row.names = FALSE)

# --------------------------------------------------
# Contributions summary
# --------------------------------------------------
contributions_summary <- osm_user_details %>%
  mutate(
    user = tolower(user),
    account_age    = as.integer(difftime(today(), date_creation,      units = "days")) / 365,
    map_activity_age = as.integer(difftime(date_last_map_edit, date_creation, units = "days")) / 365
  ) %>%
  left_join(wiki_contributions_n, by = "user")

write.csv(contributions_summary, P("data","raw","contributions_summary.csv"), row.names = FALSE)
