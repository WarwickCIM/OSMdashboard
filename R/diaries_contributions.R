#' Retrieve Users' diaries' titles
#'
#' @description Queries and parses the OSM diaries' RSS feeds into a dataframe.
#'
#' @param users a character vector containing the usernames to be queried.
#'
#' @returns a dataframe containing the titles and urls of OSM diaries and
#'   entries, per user.
#' @export
#'
get_contributions_diaries <- function(users) {
  # Load required package
  if (!requireNamespace("tidyRSS", quietly = TRUE)) {
    stop(
      "The 'tidyRSS' package is required but not installed. Please install it first."
    )
  }

  # Initialize an empty list to store dataframes
  all_data <- list()

  # Loop through each URL in the vector
  for (user in users) {
    url <- paste0("https://www.openstreetmap.org/user/", user, "/diary/rss")
    # Parse the RSS feed and handle potential errors
    tryCatch(
      {
        feed_data <- tidyRSS::tidyfeed(url, list = FALSE) |>
          dplyr::select(-item_category) |>
          dplyr::mutate(user = user, .before = 1)

        all_data[[url]] <- feed_data
      },
      error = function(e) {
        warning(paste("Failed to parse URL:", url, "Error:", e$message))
      }
    )
  }

  # Combine all dataframes into one
  combined_data <- do.call(rbind, all_data)

  rownames(combined_data) <- NULL

  return(combined_data)
}
