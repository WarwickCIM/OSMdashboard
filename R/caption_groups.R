#' Create group caption for OSM contributors
#'
#' @description Returns a one-line, human-readable summary describing a group of
#'   contributors (such as frequency, dominant activity type, experience level, and
#'   top interest tags). Data are taken from either a single edits table 'df', or
#'   from precomputed tables ('contribs_tbl', 'edits_tbl', 'tags_tbl')
#'
#' @param df a data frame of edits with columns such as 'user', 'date', 'action'
#'   and either 'key' or 'tag'. If provided, this takes precedence over 'edits_tbl'
#' @param contribs_tbl an optional data frame with contribution summaries per
#'   user, such as 'changesets', 'first_edit', 'last_edit', 'adds',
#'   'mods', 'dels', 'total_edits'. e.g.
#' @param edits_tbl an optional raw edits table used when 'df' is not supplied.
#'   Should contain 'user', 'date', 'action', 'key', 'tag'..
#' @param tags_tbl an optional tags summary with columns 'key' and 'n' (counts)
#' @param max_names maximum number of names to include in the caption
#' #'
#' @returns a length-1 character vector containing the caption.
#' @export
#'
#' @examples
#' # Minimal example with a single edits table:
#' df <- tibble::tibble(
#'   user   = c("u1","u1","u2","u2","u3"),
#'   date   = as.Date(c("2024-01-01","2024-01-02","2024-01-01","2024-01-03","2024-01-03")),
#'   action = c("add","modify","add","delete","add"),
#'   key    = c("building","highway","building","landuse","highway")
#' )
#' caption_group(df = df)

caption_group <- function(
  df = NULL,
  contribs_tbl = NULL,
  edits_tbl = NULL,
  tags_tbl = NULL,
  max_names = 3L
) {
  # Prefer df if provided; otherwise use edits_tbl
  if (is.null(df)) {
    df <- edits_tbl
  }

  # ---- contribution frequency (changesets/day or edits/active-day) ----
  per_day <- NA_real_
  if (
    !is.null(contribs_tbl) &&
      all(c("changesets", "first_edit", "last_edit") %in% names(contribs_tbl))
  ) {
    rng <- range(
      c(contribs_tbl$first_edit, contribs_tbl$last_edit),
      na.rm = TRUE
    )
    days <- as.numeric(diff(rng)) + 1
    total_changesets <- sum(contribs_tbl$changesets, na.rm = TRUE)
    per_day <- ifelse(days > 0, total_changesets / days, total_changesets)
  } else if (!is.null(df) && "date" %in% names(df)) {
    # edits per active day
    per_day <- nrow(df) / dplyr::n_distinct(df$date)
  }

  freq <- dplyr::case_when(
    is.na(per_day) ~ "active",
    per_day < 1 ~ "occasional",
    per_day < 10 ~ "frequent",
    TRUE ~ "heavy"
  )

  # ---- activity type (creators / repairers / improvers) ----
  type_word <- "contributors"
  if (!is.null(df) && "action" %in% names(df)) {
    top_act <- df |>
      dplyr::count(action, name = "n") |>
      dplyr::arrange(dplyr::desc(.data$n)) |>
      dplyr::slice(1) |>
      dplyr::pull(action)
    type_word <- dplyr::recode(
      top_act,
      add = "creators",
      create = "creators",
      modify = "repairers",
      update = "repairers",
      delete = "improvers",
      remove = "improvers",
      .default = "contributors"
    )
  } else if (
    !is.null(contribs_tbl) &&
      all(c("adds", "mods", "dels") %in% names(contribs_tbl))
  ) {
    sums <- colSums(contribs_tbl[, c("adds", "mods", "dels")], na.rm = TRUE)
    type_word <- c(
      adds = "creators",
      mods = "repairers",
      dels = "improvers"
    )[names(which.max(sums))]
  }

  # ---- experience level (avg edits per user) ----
  avg_edits <- NA_real_
  if (!is.null(df) && "user" %in% names(df)) {
    avg_edits <- df |>
      dplyr::count(.data$user, name = "n") |>
      dplyr::summarise(m = mean(.data$n)) |>
      dplyr::pull(.data$m)
  } else if (!is.null(contribs_tbl) && "total_edits" %in% names(contribs_tbl)) {
    avg_edits <- mean(contribs_tbl$total_edits, na.rm = TRUE)
  }
  exp_level <- if (is.na(avg_edits)) {
    "hobbyists"
  } else {
    dplyr::case_when(
      avg_edits < 50 ~ "hobbyists",
      avg_edits < 500 ~ "pro-ams",
      TRUE ~ "professionals"
    )
  }

  # ---- interests (top 3 tag keys) ----
  top_tags <- character(0)
  if (!is.null(tags_tbl) && all(c("key", "n") %in% names(tags_tbl))) {
    top_tags <- tags_tbl |>
      dplyr::arrange(dplyr::desc(.data$n)) |>
      dplyr::slice_head(n = 3) |>
      dplyr::pull(.data$key)
  } else if (!is.null(df) && any(c("key", "tag") %in% names(df))) {
    tag_col <- if ("key" %in% names(df)) "key" else "tag"
    top_tags <- df |>
      dplyr::count(.data[[tag_col]], name = "n") |>
      dplyr::arrange(dplyr::desc(.data$n)) |>
      dplyr::slice_head(n = 3) |>
      dplyr::pull(1)
  }
  tags_text <- if (length(top_tags)) {
    paste(top_tags, collapse = ", ")
  } else {
    "a variety of features"
  }

  # ---- homogeneity (Gini on edits/user) ----
  gini <- NA_real_
  if (!is.null(df) && "user" %in% names(df)) {
    v <- df |>
      dplyr::count(.data$user, name = "n") |>
      dplyr::pull(.data$n) |>
      sort()
    if (length(v)) {
      n <- length(v)
      gini <- (2 * sum(seq_len(n) * v) / sum(v) / n) - (n + 1) / n
    }
  }
  homog <- if (is.na(gini)) {
    "diverse"
  } else if (gini > 0.6) {
    "homogeneous"
  } else if (gini > 0.4) {
    "somewhat concentrated"
  } else {
    "diverse"
  }

  # ---- final caption ----
  glue::glue(
    "This is a {homog} group of {freq} {type_word}, mostly {exp_level}, with interests in {tags_text}."
  ) |>
    as.character()
}
