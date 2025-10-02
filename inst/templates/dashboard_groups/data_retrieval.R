library(OSMdashboard)
library(dplyr)
library(purrr)
library(lubridate)
library(sf)

# ---------------------------------------
# Build group_users.csv from DB and group_definition.csv
# ---------------------------------------
base_path <- ""

system(paste(
  "python",
  "../python/extract_group_users_from_definition.py",
  "--db", shQuote(paste0(base_path, "../database/osm_changesets.duckdb")),
  "--group-def", shQuote(paste0(base_path, "data/metadata/group_definition.csv")),
  "--out", shQuote(paste0(base_path, "data/metadata/group_users.csv"))
))

group_info  <- read.csv(paste0(base_path, "data/metadata/group_info.csv"))
group_users <- read.csv(paste0(base_path, "data/metadata/group_users.csv"))

if (!"username" %in% names(group_users)) {
  stop("group_users.csv must have a 'username' column.")
}

# ---- CAP USERS TO 100 FOR NOW PLEASE CHANGE LATER -------------
selected_users <- group_users$username |>
  as.character() |>
  trimws() |>
  tolower()
selected_users <- selected_users[nzchar(selected_users)]
selected_users <- unique(selected_users)
selected_users <- head(selected_users, 100)   # <-- hard cap

options(timeout = max(120, getOption("timeout")))

# ---------------------------------------
# User profile stats polite to webpage and with caching
# ---------------------------------------
cache_dir <- file.path(base_path, "data/processed/.user_cache")
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
cache_path <- function(user) file.path(
  cache_dir, paste0(gsub("[^A-Za-z0-9._-]", "_", user), ".rds")
)

fetch_user_polite <- function(user, sleep_min = 0.6, sleep_max = 1.4) {
  p <- cache_path(user)
  if (file.exists(p)) return(readRDS(p))
  Sys.sleep(runif(1, sleep_min, sleep_max))  # polite delay
  res <- tryCatch(OSMdashboard::get_contributions_osm_users(user),
                  error = function(e) NULL)
  if (is.null(res) || nrow(res) == 0) return(NULL)
  saveRDS(res, p)
  res
}

osm_user_details <- map_dfr(selected_users, fetch_user_polite)

write.csv(osm_user_details, file = paste0(base_path,"data/raw/osm_user_details.csv"),
  row.names = FALSE
)

# ---------------------------------------
# Changesets (robust per-user)
# ---------------------------------------
safe_user_changesets <- function(user, n = 100) {
  tryCatch(OSMdashboard::get_contributors_changesets(user, n),
           error = function(e) NULL)
}

changesets <- map_dfr(selected_users, safe_user_changesets, n = 100)

# if nothing came back, keep downstream from crashing
if (nrow(changesets) == 0) {
  changesets <- tibble::tibble(
    id=integer(), user=character(), created=as.POSIXct(character()),
    min_lat=double(), min_lon=double(), max_lat=double(), max_lon=double()
  )
}

# Details in quiet batches
ids <- unique(changesets$id)
id_batches <- split(ids, ceiling(seq_along(ids)/200))
changesets_details <- map_dfr(
  id_batches,
  ~ tryCatch(get_changesets_details(.x), error = function(e) NULL)
)

# Tags
changesets_tags <- tryCatch(
  extract_and_combine_tags(changesets_details),
  error = function(e) tibble::tibble()
)

# ---------------------------------------
# Write map contributions outputs
# ---------------------------------------
write.csv(changesets, file = paste0(base_path, "data/raw/changesets.csv"),
          row.names = FALSE)

if (nrow(changesets) > 0) {
  sf::st_write(changesets, dsn = paste0(base_path, "data/raw/changesets.gpkg"),
               append = FALSE, quiet = TRUE)
}

write.csv(changesets_tags,
          file = paste0(base_path, "data/raw/changesets_tags.csv"),
          row.names = FALSE)

changesets_details |>
  dplyr::select(-tags, -members) |>
  write.csv(file = paste0(base_path, "data/raw/changesets_details.csv"),
            row.names = FALSE)

# ---------------------------------------
# Wiki (robust, quiet)
# ---------------------------------------
wiki_contributions <- tryCatch(
  get_contributions_wiki(selected_users) |>
    dplyr::select(-tags) |>
    tibble::as_tibble(),
  error = function(e) tibble::tibble(user=character())
)

wiki_contributions_n <- wiki_contributions |>
  count(user) |>
  mutate(user = tolower(user)) |>
  rename(wiki_edits = n)

write.csv(wiki_contributions,
          paste0(base_path, "data/raw/wiki_contributions.csv"),
          row.names = FALSE)

# ---------------------------------------
# Diaries (robust, quiet)
# ---------------------------------------
users_diaries <- osm_user_details |>
  mutate(user = tolower(user)) |>
  filter(!is.na(diary), diary > 0) |>
  pull(user) |>
  unique()

contributions_diaries <- tryCatch(
  get_contributions_diaries(users_diaries),
  error = function(e) tibble::tibble()
)

write.csv(contributions_diaries,
          paste0(base_path, "data/raw/contributions_diaries.csv"),
          row.names = FALSE)

# ---------------------------------------
# Contributions summary
# ---------------------------------------
contributions_summary <- osm_user_details |>
  mutate(
    user = tolower(user),
    account_age = as.integer(difftime(today(), date_creation, units = "days")) / 365,
    map_activity_age = as.integer(difftime(date_last_map_edit, date_creation, units = "days")) / 365
  ) |>
  left_join(wiki_contributions_n, by = "user")

write.csv(contributions_summary,
          paste0(base_path, "data/raw/contributions_summary.csv"),
          row.names = FALSE)
