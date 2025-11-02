# data_retrieval.R
library(OSMdashboard)
library(dplyr)
library(purrr)
library(lubridate)
library(sf)
library(readr)
library(stringr)
library(tidyr)

# -------------------------------
# Connection hygiene
# -------------------------------
on.exit(closeAllConnections(), add = TRUE)

safe_gc <- function() {
  # If connections are building up, close them and GC
  if (nrow(showConnections(all = TRUE)) > 100) closeAllConnections()
  gc()
}

# base writer that avoids readr/gzfile path
write_csv_base <- function(x, path) {
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(x, path, row.names = FALSE, na = "")
}

# ------------------------------
# Param parsing
# ------------------------------
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
sample_perc_user <- parse_num(get_flag("sample-perc-user", 0.05), 0.05)
sample_max_total <- parse_int(get_flag("sample-max-total", 0), 0)
seed_val         <- parse_int(get_flag("seed", 123), 123)
set.seed(seed_val)

cli_args <- commandArgs(trailingOnly = TRUE)
cat(
  "\n[params]\n",
  "  raw CLI args     : ", if (length(cli_args)) paste(cli_args, collapse = " ") else "(none)", "\n",
  "  use_db_overlay   : ", use_db_overlay, "\n",
  "  sample_perc_user : ", sample_perc_user, "\n",
  "  sample_max_total : ", sample_max_total, "\n",
  "  seed             : ", seed_val, "\n\n",
  sep = ""
)

# --------------------------------------------------
# Base folders
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

# Temporary Block-----------------------------------
# target <- "mariefer"
# group_users <- tryCatch({
#   group_users <- dplyr::arrange(group_users, username)
#   ix <- which(tolower(group_users$username) == tolower(target))
#   if (length(ix) > 0) {
#     to_drop <- ix:min(nrow(group_users), ix + 4)
#     group_users <- group_users[-to_drop, , drop = FALSE]
#   }
#   group_users
# }, error = function(e) {
#   warning(paste("Error during user exclusion for target", target, ":", e$message))
#   group_users
# })
#-------------------------------------------------------------

# --------------------------------------------------
# Selected users
# --------------------------------------------------
selected_users <- group_users$username |> as.character() |> trimws() |> tolower() |> unique()
selected_users <- selected_users[nzchar(selected_users)]

if (!length(selected_users)) {
  message("No users found for this group. Writing empty RAW placeholders and exiting.")
  dir.create(P("data","raw"), recursive = TRUE, showWarnings = FALSE)
  write_csv_base(data.frame(user=character(), map_changesets=integer(), map_notes=integer(),
                            traces=integer(), diary=integer(), comments=integer(),
                            date_creation=as.Date(character()), date_last_map_edit=as.Date(character())),
                 P("data","raw","osm_user_details.csv"))
  write_csv_base(data.frame(id=integer(), user=character(), created=as.POSIXct(character()),
                            min_lat=double(), min_lon=double(), max_lat=double(), max_lon=double()),
                 P("data","raw","changesets.csv"))
  write_csv_base(data.frame(changeset=integer(), key=character(), value=character()),
                 P("data","raw","changesets_tags.csv"))
  write_csv_base(tibble::tibble(), P("data","raw","changesets_details.csv"))
  write_csv_base(data.frame(user=character(), title=character(), timestamp=character()),
                 P("data","raw","wiki_contributions.csv"))
  write_csv_base(data.frame(), P("data","raw","contributions_diaries.csv"))
  write_csv_base(data.frame(user=character(), map_changesets=integer(), map_notes=integer(),
                            traces=integer(), diary=integer(), comments=integer(),
                            date_creation=as.Date(character()), date_last_map_edit=as.Date(character()),
                            account_age=double(), map_activity_age=double(), wiki_edits=integer()),
                 P("data","raw","contributions_summary.csv"))
  quit(save = "no", status = 0)
}

# --------------------------------------------------
# build DB overlay (when requested)
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
# user profile stats
# --------------------------------------------------
cache_dir <- P("data", "processed", ".user_cache")
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
cache_path <- function(user) file.path(cache_dir, paste0(gsub("[^A-Za-z0-9._-]", "_", user), ".rds"))

fetch_user_polite <- function(user, sleep_min = 0.6, sleep_max = 1.4) {
  p <- cache_path(user)

  # Read branch — open/close explicitly
  if (file.exists(p)) {
    con <- file(p, open = "rb")   # NOT gzfile
    on.exit(try(close(con), silent = TRUE), add = TRUE)
    out <- tryCatch(readRDS(con), error = function(e) NULL)
    return(out)
  }

  # Write branch
  Sys.sleep(runif(1, sleep_min, sleep_max))
  res <- tryCatch(OSMdashboard::get_contributions_osm_users(user), error = function(e) NULL)
  if (is.null(res) || nrow(res) == 0) return(NULL)

  conw <- file(p, open = "wb")    # write uncompressed RDS
  on.exit(try(close(conw), silent = TRUE), add = TRUE)
  saveRDS(res, conw, compress = FALSE)
  res
}

chunk <- function(x, k) split(x, ceiling(seq_along(x) / k))

osm_user_details <- list()
for (grp in chunk(selected_users, 20)) {           #a chunk of 20 users
  part <- purrr::map_dfr(grp, fetch_user_polite)
  osm_user_details[[length(osm_user_details) + 1]] <- part
  closeAllConnections(); gc() #hard close between little chunks
}
osm_user_details <- dplyr::bind_rows(osm_user_details)

write_csv_base(osm_user_details, P("data","raw","osm_user_details.csv"))
safe_gc()

# --------------------------------------------------
# helpers
# --------------------------------------------------
write_empty_changesets <- function() {
  write_csv_base(
    data.frame(id=integer(), user=character(), created=as.POSIXct(character()),
               min_lat=double(), min_lon=double(), max_lat=double(), max_lon=double()),
    P("data","raw","changesets.csv")
  )
  write_csv_base(
    data.frame(changeset=integer(), key=character(), value=character()),
    P("data","raw","changesets_tags.csv")
  )
  write_csv_base(tibble::tibble(), P("data","raw","changesets_details.csv"))
}

# --------------------------------------------------
# changesets/tags/ details
# --------------------------------------------------
if (!use_db_overlay) {
  # ---------- BASELINE: API flow per user ---------------
  safe_user_changesets <- function(user, n = 100) {
    tryCatch(OSMdashboard::get_contributors_changesets(user, n), error = function(e) NULL)
  }
  changesets <- map_dfr(selected_users, safe_user_changesets, n = 100)
  safe_gc()

  ids <- unique(changesets$id)
  id_batches <- split(ids, ceiling(seq_along(ids)/200))

  changesets_details <- purrr::map_dfr(
    id_batches,
    function(ids) {
      out <- tryCatch(get_changesets_details(ids), error = function(e) NULL)
      safe_gc()
      out
    }
  )

  if (nrow(changesets) > 0 && nrow(changesets_details) > 0) {
    changesets <- changesets |>
      dplyr::left_join(
        changesets_details |> dplyr::select(id, lat, lon),
        by = "id"
      )
  }

  if (all(c("lat", "lon") %in% names(changesets)) &&
      !all(c("min_lat", "min_lon", "max_lat", "max_lon") %in% names(changesets))) {
    changesets <- changesets |>
      dplyr::mutate(
        min_lat = .data$lat,
        max_lat = .data$lat,
        min_lon = .data$lon,
        max_lon = .data$lon
      )
  }

  if (nrow(changesets) == 0) {
    changesets <- tibble::tibble(
      id=integer(), user=character(), created=as.POSIXct(character()),
      min_lat=double(), min_lon=double(), max_lat=double(), max_lon=double()
    )
  }

  # derive tags BEFORE writing details
  changesets_tags <- tryCatch(
    extract_and_combine_tags(changesets_details),
    error = function(e) tibble::tibble(changeset = integer(), key = character(), value = character())
  )
  write_csv_base(changesets_tags, P("data","raw","changesets_tags.csv"))
  safe_gc()

  # locale from tags (optional)
  locale_df <- changesets_tags |>
    dplyr::filter(key == "locale") |>
    dplyr::group_by(changeset) |>
    dplyr::summarise(locale = dplyr::first(stats::na.omit(value)), .groups = "drop") |>
    dplyr::rename(id = changeset)

  changesets <- changesets |>
    dplyr::left_join(locale_df, by = "id") |>
    dplyr::mutate(locale = as.character(locale))

  details_out <- changesets_details %>% dplyr::select(-dplyr::any_of(c("members","tags","tags_df")))
  write_csv_base(details_out, P("data","raw","changesets_details.csv"))
  write_csv_base(changesets,   P("data","raw","changesets.csv"))
  safe_gc()

  if (nrow(changesets) > 0) {
    suppressWarnings(sf::st_write(changesets, dsn = P("data","raw","changesets.gpkg"),
                                  append = FALSE, quiet = TRUE))
  }
  safe_gc()

} else {
  # ---------- OVERLAY SAMPLING: sample IDs, then API details ----------
  cs_overlay <- P("data","db_overlay","changesets_subset.csv")
  if (!file.exists(cs_overlay)) {
    warning("Overlay changesets_subset.csv not found; writing empty RAW and continuing.")
    write_empty_changesets()
  } else {
    cs_all <- readr::read_csv(cs_overlay, show_col_types = FALSE)
    if (!"user" %in% names(cs_all) && "username" %in% names(cs_all)) {
      cs_all <- dplyr::rename(cs_all, user = username)
    }
    cs_all <- cs_all |> dplyr::mutate(user = tolower(user))

    per_user_n <- cs_all |> dplyr::count(user, name = "n_total")
    alloc <- per_user_n
    alloc$n_target_raw <- ceiling(alloc$n_total * sample_perc_user)

    if (sample_max_total > 0) {
      user_cap <- alloc$n_target_raw
      w <- alloc$n_target_raw / sum(alloc$n_target_raw)
      prop_n <- pmax(1L, floor(w * sample_max_total))
      alloc$n_target <- pmin(prop_n, user_cap)
      overflow <- sum(alloc$n_target) - sample_max_total
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
      alloc$n_target <- alloc$n_target_raw
    }

    alloc <- alloc %>%
      dplyr::mutate(n_target = as.integer(dplyr::coalesce(n_target, 0L)),
                    n_target = pmax(0L, n_target)) %>%
      dplyr::filter(n_target > 0L)

    cat(sprintf("[sampling] users in overlay: %d | with target > 0: %d | total target: %d\n",
                dplyr::n_distinct(cs_all$user), nrow(alloc), sum(alloc$n_target)))

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

    sel_ids <- unique(na.omit(as.integer(sampled$id)))
    if (!length(sel_ids)) {
      write_empty_changesets()
    } else {
      id_batches <- split(sel_ids, ceiling(seq_along(sel_ids)/200))
      changesets_details <- purrr::map_dfr(
        id_batches,
        function(ids) {
          out <- tryCatch(get_changesets_details(ids), error = function(e) NULL)
          safe_gc()
          out
        }
      )

      if (is.null(changesets_details) || !is.data.frame(changesets_details) || !nrow(changesets_details)) {
        write_empty_changesets()
      } else {
        tags_df <- OSMdashboard::extract_and_combine_tags(changesets_details)
        write_csv_base(tags_df, P("data","raw","changesets_tags.csv"))
        safe_gc()

        details_clean <- changesets_details %>% dplyr::select(-dplyr::any_of(c("members","tags","tags_df")))
        write_csv_base(details_clean, P("data","raw","changesets_details.csv"))

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

        tags_wide <- if (nrow(tags_df)) {
          tags_df %>%
            dplyr::filter(key %in% c("hashtags", "imagery")) %>%
            dplyr::group_by(changeset, key) %>%
            dplyr::summarise(value = dplyr::first(stats::na.omit(value)), .groups = "drop") %>%
            tidyr::pivot_wider(names_from = key, values_from = value) %>%
            dplyr::rename(id = changeset) %>%
            dplyr::mutate(id = as.integer(id))
        } else {
          tibble::tibble(id = integer(), hashtags = character(), imagery = character())
        }

        core <- core %>%
          dplyr::left_join(tags_wide, by = "id") %>%
          dplyr::mutate(
            hashtags = if ("hashtags" %in% names(.)) as.character(hashtags) else NA_character_,
            imagery  = if ("imagery"  %in% names(.)) as.character(imagery)  else NA_character_
          )

        locale_overlay <- sampled %>% dplyr::select(id, dplyr::any_of(c("locale")))
        core <- core %>%
          dplyr::left_join(locale_overlay, by = "id") %>%
          dplyr::mutate(locale = if ("locale" %in% names(.)) as.character(locale) else NA_character_)

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

        write_csv_base(core, P("data","raw","changesets.csv"))
        safe_gc()
      }
    }
  }
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
  count(user) %>% mutate(user = tolower(user)) %>% rename(wiki_edits = n)
write_csv_base(wiki_contributions, P("data","raw","wiki_contributions.csv"))
safe_gc()

# --------------------------------------------------
# Diaries
# --------------------------------------------------
users_diaries <- osm_user_details %>%
  mutate(user = tolower(user)) %>%
  filter(!is.na(diary), diary > 0) %>%
  pull(user) %>%
  unique()
contributions_diaries <- tryCatch(get_contributions_diaries(users_diaries),
                                  error = function(e) tibble::tibble())
write_csv_base(contributions_diaries, P("data","raw","contributions_diaries.csv"))
safe_gc()

# --------------------------------------------------
# Contributions summary
# --------------------------------------------------
contributions_summary <- osm_user_details %>%
  mutate(
    user = tolower(user),
    account_age      = as.integer(difftime(today(), date_creation,      units = "days")) / 365,
    map_activity_age = as.integer(difftime(date_last_map_edit, date_creation, units = "days")) / 365
  ) %>%
  left_join(wiki_contributions_n, by = "user")
write_csv_base(contributions_summary, P("data","raw","contributions_summary.csv"))
safe_gc()
