# data_retrieval.R
library(OSMdashboard)
library(dplyr)
library(purrr)
library(lubridate)
library(sf)
library(readr)
library(stringr)
library(tidyr)

# ------------------------------
# Param parsing (CLI + env)
# ------------------------------

# Usage example:
# Rscript data_retrieval.R \
#   --use-db-overlay=true \
#   --sample-perc-user=0.05 \
#   --sample-max-total=0 \
#   --seed=42

parse_num <- function(x, default) {
  if (is.null(x)) return(default)
  out <- suppressWarnings(as.numeric(x))
  if (is.na(out)) default else out
}

get_flag <- function(name, default = NULL) {
  args <- commandArgs(trailingOnly = TRUE)
  hit  <- args[grepl(paste0("^--", name, "="), args)]
  if (length(hit)) {
    val <- sub(paste0("^--", name, "="), "", hit[1])
  } else {
    envn <- toupper(gsub("-", "_", name))
    val  <- Sys.getenv(envn, unset = NA)
  }
  if (is.na(val) || val == "") return(default)
  val
}
parse_bool <- function(x, default = FALSE) {
  if (is.null(x)) return(default)
  tolower(x) %in% c("1","true","t","yes","y")
}
parse_int <- function(x, default) {
  if (is.null(x)) return(default)
  out <- suppressWarnings(as.integer(x))
  if (is.na(out)) default else out
}
`%||%` <- function(a,b) if (is.null(a) || is.na(a)) b else a

use_db_overlay   <- parse_bool(get_flag("use-db-overlay", "false"), FALSE)
sample_perc_user  <- parse_num(get_flag("sample-perc-user", 0.05), 0.05)
sample_max_total <- parse_int(get_flag("sample-max-total", 0), 0)  # 0 = no global cap
seed_val         <- parse_int(get_flag("seed", 123), 123)

set.seed(seed_val)

cli_args <- commandArgs(trailingOnly = TRUE)
cat(
  "\n[params]\n",
  "  raw CLI args     : ", if (length(cli_args)) paste(cli_args, collapse = " ") else "(none)", "\n",
  "  use_db_overlay   : ", use_db_overlay, "\n",
  "  sample_perc_user  : ", sample_perc_user, "\n",
  "  sample_max_total : ", sample_max_total, "\n",
  "  seed             : ", seed_val, "\n\n",
  sep = ""
)

# --------------------------------------------------
# Base folders (run this script from dashboard folder)
# --------------------------------------------------
dash_dir  <- normalizePath(getwd(), winslash = "/")
repo_root <- normalizePath(file.path(dash_dir, ".."), winslash = "/")
P <- function(...) file.path(dash_dir, ...)

# --------------------------------------------------
# Build group_users.csv from DB + group_definition.csv
# --------------------------------------------------
py_extract  <- file.path(repo_root, "python", "extract_group_users_from_definition.py")
duckdb_path <- file.path(repo_root, "database", "osm_changesets.duckdb")
group_def   <- P("data", "metadata", "group_definition.csv")
group_out   <- P("data", "metadata", "group_users.csv")

stopifnot("Python extract script not found" = file.exists(py_extract))
stopifnot("DuckDB not found"                = file.exists(duckdb_path))
stopifnot("group_definition.csv missing"    = file.exists(group_def))
dir.create(dirname(group_out), recursive = TRUE, showWarnings = FALSE)

status <- system2(
  "python",
  c(py_extract, "--db", duckdb_path, "--group-def", group_def, "--out", group_out),
  stdout = TRUE, stderr = TRUE
)
cat(paste(status, collapse = "\n"))

# --------------------------------------------------
# Read metadata
# --------------------------------------------------
group_info  <- read.csv(P("data", "metadata", "group_info.csv"))
group_users <- read.csv(P("data", "metadata", "group_users.csv"))
if (!"username" %in% names(group_users)) stop("group_users.csv must have a 'username' column.")

# --------------------------------------------------
# Selected users
# --------------------------------------------------
selected_users <- group_users$username |> as.character() |> trimws() |> tolower() |> unique()
selected_users <- selected_users[nzchar(selected_users)]

if (!length(selected_users)) {
  message("No users found for this group. Writing empty RAW placeholders and exiting.")
  dir.create(P("data","raw"), recursive = TRUE, showWarnings = FALSE)

  write.csv(data.frame(user=character(), map_changesets=integer(), map_notes=integer(),
                       traces=integer(), diary=integer(), comments=integer(),
                       date_creation=as.Date(character()), date_last_map_edit=as.Date(character())),
            P("data","raw","osm_user_details.csv"), row.names = FALSE)

  write.csv(data.frame(id=integer(), user=character(), created=as.POSIXct(character()),
                       min_lat=double(), min_lon=double(), max_lat=double(), max_lon=double()),
            P("data","raw","changesets.csv"), row.names = FALSE)

  write.csv(data.frame(changeset=integer(), key=character(), value=character()),
            P("data","raw","changesets_tags.csv"), row.names = FALSE)

  readr::write_csv(tibble::tibble(), P("data","raw","changesets_details.csv"))

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

# Soft cap to avoid API hammering
selected_users <- head(selected_users, 100)

# --------------------------------------------------
# (A) Build DB overlay (when requested)
# --------------------------------------------------
overlay_dir <- P("data", "db_overlay")
if (use_db_overlay) {
  overlay_py <- file.path(repo_root, "python", "overlay.py")
  queries_py <- file.path(repo_root, "python", "queries.py")

  stopifnot("overlay.py not found" = file.exists(overlay_py))
  stopifnot("queries.py not found" = file.exists(queries_py))
  dir.create(overlay_dir, recursive = TRUE, showWarnings = FALSE)

  cat("\n[overlay] Building DB overlay...\n",
      "  overlay.py  : ", overlay_py, "\n",
      "  queries.py  : ", queries_py, "\n",
      "  duckdb      : ", duckdb_path, "\n",
      "  group_users : ", P("data","metadata","group_users.csv"), "\n",
      "  group_info  : ", P("data","metadata","group_info.csv"), "\n",
      "  out_dir     : ", overlay_dir, "\n\n", sep = "")

  py_tmp <- tempfile(fileext = ".py")
  py_code <- sprintf(
    paste0(
      "import importlib.util\n",
      "p=r'''%s'''\nq=r'''%s'''\n",
      "spec=importlib.util.spec_from_file_location('overlay', p)\n",
      "m=importlib.util.module_from_spec(spec)\n",
      "spec.loader.exec_module(m)\n",
      "m.build_overlay(db_path=r'''%s''', queries_path=q,\n",
      "  group_users_csv=r'''%s''', group_info_csv=r'''%s''', out_dir=r'''%s''',\n",
      "  usernames=None, hashtags=None, start=None, end=None, bbox=None)\n"
    ),
    overlay_py, queries_py, duckdb_path,
    P("data","metadata","group_users.csv"),
    P("data","metadata","group_info.csv"),
    overlay_dir
  )
  writeLines(py_code, py_tmp)
  out <- tryCatch(system2("python", c(py_tmp), stdout = TRUE, stderr = TRUE),
                  error = function(e) structure(list(error = e$message), class = "overlay_error"))
  cat("[overlay] Python output:\n", paste(out, collapse = "\n"), "\n", sep = "")
  unlink(py_tmp)

  expected <- file.path(overlay_dir, "changesets_subset.csv")
  if (!file.exists(expected)) warning("Overlay build did not produce ", expected, ".")
}

# --------------------------------------------------
# (B) RAW: user profile stats
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
# Helpers
# --------------------------------------------------
write_empty_changesets <- function() {
  write.csv(
    data.frame(id=integer(), user=character(), created=as.POSIXct(character()),
               min_lat=double(), min_lon=double(), max_lat=double(), max_lon=double()),
    P("data","raw","changesets.csv"), row.names = FALSE
  )
  write.csv(
    data.frame(changeset=integer(), key=character(), value=character()),
    P("data","raw","changesets_tags.csv"), row.names = FALSE
  )
  readr::write_csv(tibble::tibble(), P("data","raw","changesets_details.csv"))
}

# --------------------------------------------------
# (C) RAW: changesets / tags / details
# --------------------------------------------------
if (!use_db_overlay) {
  # ---------- BASELINE: API flow per user ---------------
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

  # >>> IMPORTANT: derive tags BEFORE writing details (list-cols vanish in CSV)
  changesets_tags <- tryCatch(
    extract_and_combine_tags(changesets_details),
    error = function(e) tibble::tibble(changeset = integer(), key = character(), value = character())
  )
  readr::write_csv(changesets_tags, P("data","raw","changesets_tags.csv"))

  # Write details (without list-cols)
  details_out <- changesets_details %>% dplyr::select(-dplyr::any_of(c("members","tags","tags_df")))
  readr::write_csv(details_out, P("data","raw","changesets_details.csv"))

  # Write changesets as returned by API
  write.csv(changesets, P("data","raw","changesets.csv"), row.names = FALSE)

  # Optional GPKG (keep if you still want it)
  if (nrow(changesets) > 0) {
    suppressWarnings(sf::st_write(changesets, dsn = P("data","raw","changesets.gpkg"),
                                  append = FALSE, quiet = TRUE))
  }

} else {
  # ---------- OVERLAY SAMPLING: sample IDs, then API details  ----------
  cs_overlay  <- P("data","db_overlay","changesets_subset.csv")
  if (!file.exists(cs_overlay)) {
    warning("Overlay changesets_subset.csv not found; writing empty RAW and continuing.")
    write_empty_changesets()
  } else {
    # Load overlay rows and normalise user column
    cs_all <- readr::read_csv(cs_overlay, show_col_types = FALSE)
    if (!"user" %in% names(cs_all) && "username" %in% names(cs_all)) {
      cs_all <- dplyr::rename(cs_all, user = username)
    }
    cs_all <- cs_all |> dplyr::mutate(user = tolower(user))

    # ---- per-user targets ----
    per_user_n <- cs_all |> dplyr::count(user, name = "n_total")
    alloc <- per_user_n

    # --- NEW: Calculate target based on percentage (n_total * percentage) ---
    alloc$n_target_raw <- ceiling(alloc$n_total * sample_perc_user)

    if (sample_max_total > 0) {
      # Use the proportionally calculated size as the effective 'per user cap'
      user_cap <- alloc$n_target_raw

      # Now, scale down the proportional targets if the total exceeds sample_max_total
      w <- alloc$n_target_raw / sum(alloc$n_target_raw)
      prop_n <- pmax(1L, floor(w * sample_max_total))

      # The target is the proportional calculation, capped by the overall max_total constraint
      alloc$n_target <- pmin(prop_n, user_cap)

      overflow <- sum(alloc$n_target) - sample_max_total

      # The complex overflow logic remains (simplified slightly here):
      if (overflow > 0) {
        ord <- order(alloc$n_target, decreasing = TRUE)
        i <- 1L
        while (overflow > 0 && i <= length(ord)) {
          j <- ord[i]
          can_reduce <- alloc$n_target[j] - 1L
          if (can_reduce > 0L) {
            take <- min(can_reduce, overflow)
            alloc$n_target[j] <- alloc$n_target[j] - take
            overflow <- overflow - take
          }
          i <- i + 1L
        }
      }
    } else {
      # No global cap: n_target is simply the proportional calculation
      alloc$n_target <- alloc$n_target_raw
    }

    alloc <- alloc %>%
      dplyr::mutate(n_target = as.integer(dplyr::coalesce(n_target, 0L)),
                    n_target = pmax(0L, n_target)) %>%
      dplyr::filter(n_target > 0L)

    cat(sprintf("[sampling] users in overlay: %d | with target > 0: %d | total target: %d\n",
                dplyr::n_distinct(cs_all$user), nrow(alloc), sum(alloc$n_target)))

    # ---- sample overlay rows per user -> IDs only ----
    set.seed(seed_val)
    sampled <- cs_all %>%
      dplyr::inner_join(alloc, by = "user") %>%
      dplyr::group_by(user) %>%
      dplyr::mutate(.rand = runif(dplyr::n())) %>%
      dplyr::arrange(.rand, .by_group = TRUE) %>%
      dplyr::mutate(.row = dplyr::row_number()) %>%
      dplyr::filter(.row <= dplyr::first(n_target)) %>%
      dplyr::ungroup() %>%
      dplyr::select(-.rand, -.row)

    # ---- fetch API details only for sampled IDs ----
    sel_ids <- unique(na.omit(as.integer(sampled$id)))
    if (!length(sel_ids)) {
      write_empty_changesets()
    } else {
      id_batches <- split(sel_ids, ceiling(seq_along(sel_ids)/200))
      changesets_details <- map_dfr(id_batches, ~ tryCatch(get_changesets_details(.x), error = function(e) NULL))

      if (is.null(changesets_details) || !is.data.frame(changesets_details) || !nrow(changesets_details)) {
        write_empty_changesets()
      } else {
        #derive tags BEFORE writing details

        tags_df <- OSMdashboard::extract_and_combine_tags(changesets_details)

        readr::write_csv(tags_df, P("data","raw","changesets_tags.csv"))

        # Write details (strip list-cols)
        details_clean <- changesets_details %>% dplyr::select(-dplyr::any_of(c("members","tags","tags_df")))
        readr::write_csv(details_clean, P("data","raw","changesets_details.csv"))

        # Build changesets.csv from API details + tags
        det <- tibble::as_tibble(changesets_details)
        n   <- nrow(det)
        col_or_na <- function(df, nm, n) if (nm %in% names(df)) df[[nm]] else rep(NA, n)
        first_of  <- function(df, n, ...) {
          cands <- c(...)
          hit <- cands[cands %in% names(df)]
          if (length(hit)) df[[hit[1]]] else rep(NA, n)
        }

        id_vec      <- first_of(det, n, "changeset", "id")
        user_vec    <- tolower(as.character(first_of(det, n, "user", "username")))
        created_vec <- first_of(det, n, "created_at", "created", "timestamp")

        core <- tibble::tibble(
          id         = as.integer(id_vec),
          user       = user_vec,
          created_at = suppressWarnings(lubridate::ymd_hms(as.character(created_vec))),
          min_lat    = suppressWarnings(as.numeric(col_or_na(det, "min_lat", n))),
          min_lon    = suppressWarnings(as.numeric(col_or_na(det, "min_lon", n))),
          max_lat    = suppressWarnings(as.numeric(col_or_na(det, "max_lat", n))),
          max_lon    = suppressWarnings(as.numeric(col_or_na(det, "max_lon", n))),
          created_by = as.character(col_or_na(det, "created_by", n)),
          comment    = as.character(col_or_na(det, "comment", n))
        ) %>% dplyr::distinct()

        # Join locale/hashtags from tags
        tags_wide <- if (nrow(tags_df)) {
          tags_df %>%
            dplyr::filter(key %in% c("locale","hashtags", "imagery")) %>%
            dplyr::group_by(changeset, key) %>%
            dplyr::summarise(value = dplyr::first(stats::na.omit(value)), .groups = "drop") %>%
            tidyr::pivot_wider(names_from = key, values_from = value) %>%
            dplyr::rename(id = changeset) %>%
            # convert ID to an integer
            dplyr::mutate(id = as.integer(id))
        } else {
          tibble::tibble(id = integer(), locale = character(), hashtags = character())
        }

        core <- core %>%
          dplyr::left_join(tags_wide, by = "id") %>%
          #Fill with NA if join fails
          dplyr::mutate(
            locale = if("locale" %in% names(.)) as.character(locale) else NA_character_,
            hashtags = if("hashtags" %in% names(.)) as.character(hashtags) else NA_character_,
            imagery = if("imagery" %in% names(.)) as.character(imagery) else NA_character_
          )

        # Fill bbox from overlay if API missed it
        bbox_overlay <- sampled %>% dplyr::select(id, dplyr::any_of(c("min_lat","min_lon","max_lat","max_lon")))
        if (nrow(bbox_overlay)) {
          core <- core %>%
            dplyr::left_join(bbox_overlay, by = "id", suffix = c("", "_ov")) %>%
            dplyr::mutate(
              min_lat = dplyr::coalesce(min_lat, .data$min_lat_ov),
              min_lon = dplyr::coalesce(min_lon, .data$min_lon_ov),
              max_lat = dplyr::coalesce(max_lat, .data$max_lat_ov),
              max_lon = dplyr::coalesce(max_lon, .data$max_lon_ov)
            ) %>%
            dplyr::select(-dplyr::ends_with("_ov"))
        }

        readr::write_csv(core, P("data","raw","changesets.csv"))
      }
    }
  }
}

# --------------------------------------------------
# (D) RAW: Wiki
# --------------------------------------------------
wiki_contributions <- tryCatch(
  get_contributions_wiki(selected_users) %>%
    dplyr::select(-tags) %>%
    tibble::as_tibble(),
  error = function(e) tibble::tibble(user=character())
)
wiki_contributions_n <- wiki_contributions %>%
  count(user) %>% mutate(user = tolower(user)) %>% rename(wiki_edits = n)
write.csv(wiki_contributions, P("data","raw","wiki_contributions.csv"), row.names = FALSE)

# --------------------------------------------------
# (E) RAW: Diaries
# --------------------------------------------------
users_diaries <- osm_user_details %>%
  mutate(user = tolower(user)) %>%
  filter(!is.na(diary), diary > 0) %>%
  pull(user) %>%
  unique()
contributions_diaries <- tryCatch(get_contributions_diaries(users_diaries),
                                  error = function(e) tibble::tibble())
write.csv(contributions_diaries, P("data","raw","contributions_diaries.csv"), row.names = FALSE)

# --------------------------------------------------
# (F) RAW: Contributions summary
# --------------------------------------------------
contributions_summary <- osm_user_details %>%
  mutate(
    user = tolower(user),
    account_age      = as.integer(difftime(today(), date_creation,      units = "days")) / 365,
    map_activity_age = as.integer(difftime(date_last_map_edit, date_creation, units = "days")) / 365
  ) %>%
  left_join(wiki_contributions_n, by = "user")
write.csv(contributions_summary, P("data","raw","contributions_summary.csv"), row.names = FALSE)
