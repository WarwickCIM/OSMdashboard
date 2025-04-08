#' Get wiki contributions from a given set of users
#'
#' @description Queries OSM wiki using wikimedia API via
#' [WikipediR::user_contributions()] and returns a dataframe with all the wiki
#' contributions made by every user.
#'
#' @param users a character vector containing usernames
#'
#' @returns a dataframe containing all the contributions in
#'   wiki.openstreetmap.org made by the set of users
#' @export
#'
get_contributions_wiki <- function(users) {
  df <- data.frame()

  for (user in users) {
    print(user)

    df_raw <- WikipediR::user_contributions(
      domain = "wiki.openstreetmap.org",
      username = user
    )

    # This returns a list of lists which needs to be converted to a dataframe.
    # wiki_contributions < map_df(test, tibble::as_tibble)
    if (!length(df_raw$query$usercontribs) == 0) {
      df_raw <- df_raw$query$usercontribs |>
        purrr::map(as_tibble) |>
        purrr::reduce(bind_rows)

      df <- df |>
        dplyr::bind_rows(df_raw)
    }
  }

  return(df)
}


#' Wiki contributions summaries
#'
#' @description
#' Provides a summary of contributions
#'
#' @param df a dataframe with all wiki contributions generated from [get_contributions_wiki()]
#'
#' @returns a list containing several summarised data.
#' @export
#'
stats_contributions_wiki <- function(df) {
  n_users <- nlevels(as.factor(df$user))

  date_start <- min(df$timestamp)
  date_end <- max(df$timestamp)

  contributions_n <- df |>
    dplyr::count(user)

  contributions_size <- df |>
    dplyr::select(user, sizediff) |>
    dplyr::mutate(
      additions = dplyr::case_when(sizediff > 0 ~ sizediff),
      deletions = dplyr::case_when(sizediff < 0 ~ sizediff)
    ) |>
    dplyr::group_by(user) |>
    dplyr::summarise(dplyr::across(c(additions, deletions), mean, na.rm = TRUE))


  contributed_pages <- df |>
    dplyr::select(title, sizediff) |>
    dplyr::mutate(
      sizediff = abs(sizediff),
      # Redact usernames
      title = dplyr::case_when(
        stringr::str_starts(title, "User:") ~ "User pages",
        .default = title
      )
    ) |>
    dplyr::count(title, wt = sizediff, sort = TRUE)

  results <- list(n_users, date_start, date_end, contributions_size, contributed_pages)

  return(results)
}
