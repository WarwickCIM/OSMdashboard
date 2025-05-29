#' Get OSM contributions by type
#'
#' @description Returns a dataframe listing the number and type of contributions
#'   by a set of users. Data is scrapped from OSM users' profiles.
#'
#' @param users a vector containing the usernames to be queried.
#'
#' @returns a dataframe containing the number of contributions by type made by
#'   user.
#' @export
#'
#' @examples
#' get_contributions_osm_users("ccamara")
get_contributions_osm_users <- function(users) {
  # TODO: use description to see if a user has listed their wiki account.
  df <- data.frame()

  for (user in users) {

    print(user)

    # Sanitise url
    user_clean <- sub(" ", "%20", user)

    # URL to scrape
    url <- paste0("https://www.openstreetmap.org/user/", user_clean)

    # Read the HTML content of the page
    page <- rvest::read_html(url)

    # Extract the `ul` nested under `.secondary-actions`
    list_items <- page |>
      rvest::html_element(".secondary-actions ul") |> # Select the `ul` element under `.secondary-actions`
      rvest::html_elements("li") |> # Extract all `li` elements
      rvest::html_text(trim = TRUE) # Get the text content of each `li`


    # TODO: extract creation date.
    user_dates <- page |>
      rvest::html_element(".text-body-secondary dl") |>
      rvest::html_elements("dd") |>
      rvest::html_text()

    user_dates_df <- data.frame(
      user = user,
      dates = c("date_creation", "date_last_map_edit"),
      date = user_dates
    ) |>
      dplyr::mutate(date = lubridate::mdy(date)) |>
      tidyr::pivot_wider(id_cols = user, names_from = dates, values_from = date)

    # Convert the list of items into a dataframe
    user_df <- data.frame(item = list_items, stringsAsFactors = FALSE) |>
      tidyr::separate(item, into = c("item", "value"), sep = "\\s\\s", extra = "merge") |>
      dplyr::mutate(
        item = stringr::str_trim(item),
        value = stringr::str_trim(value),
        value = stringr::str_remove(value, ","),
        value = as.numeric(value),
        user = user
      ) |>
      tidyr::pivot_wider(id_cols = user, names_from = item, values_from = value) |>
      dplyr::left_join(user_dates_df, by = dplyr::join_by(user))


    df <- df |>
      dplyr::bind_rows(user_df)
  }

  df <- df |>
    dplyr::select(-`Send Message`) |>
    dplyr::rename(
      map_changesets = Edits,
      map_notes = `Map Notes`,
      traces = Traces,
      diary = Diary,
      comments = Comments
    )

  return(df)
}
