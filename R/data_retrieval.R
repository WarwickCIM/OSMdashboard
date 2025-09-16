#' Retrieve and process data for the dashboard
#' 
#' @param base_path The base path for data files. Default is "".
#' @param anonymize Logical. Whether to anonymize usernames and commit IDs. Default is FALSE.
#' @return A list of dataframes containing the processed data.
#' @export
retrieve_dashboard_data <- function(base_path = "", anonymize = FALSE) {
  # Initialize progress bar using {cli}
  cli::cli_progress_bar("Processing data", total = 6)

  # Step 1: Load group data
  cli::cli_progress_update(status = "Loading group data...")
  group_info <- read.csv(paste0(base_path, "data/group_info.csv"))
  group_users <- read.csv(paste0(base_path, "data/group_users.csv"))
  selected_users <- group_users$username

  # Step 2: Retrieve OSM user details
  cli::cli_progress_update(status = "Retrieving OSM user details...")
  osm_user_details <- OSMdashboard::get_contributions_osm_users(selected_users)

  # Step 3: Map contributions
  cli::cli_progress_update(status = "Mapping contributions...")
  changesets <- OSMdashboard::get_contributions_changesets(selected_users, 100)
  changesets_details <- OSMdashboard::get_changesets_details(changesets$id)
  changesets_tags <- OSMdashboard::extract_and_combine_tags(changesets_details)

  # Step 4: Process wiki contributions
  cli::cli_progress_update(status = "Processing wiki contributions...")
  wiki_contributions <- OSMdashboard::get_contributions_wiki(selected_users) |>
    dplyr::select(-tags) |>
    tibble::as_tibble()
  wiki_contributions_n <- wiki_contributions |>
    dplyr::count(user)

  # Step 5: Process diaries
  cli::cli_progress_update(status = "Processing diaries...")
  users_diaries <- osm_user_details |>
    dplyr::filter(diary > 0) |>
    dplyr::pull(user)
  contributions_diaries <- OSMdashboard::get_contributions_diaries(users_diaries)

  # Step 6: Summarize contributions
  cli::cli_progress_update(status = "Summarizing contributions...")
  contributions_summary <- osm_user_details |>
    dplyr::mutate(
      user = tolower(user),
      account_age = as.integer(
        lubridate::difftime(lubridate::today(), date_creation, units = "days")
      ) / 365
    ) |>
    dplyr::left_join(wiki_contributions_n, by = "user")

  # Add query timestamp
  timestamp <- Sys.time()
  changesets$timestamp <- timestamp
  changesets_details$timestamp <- timestamp
  changesets_tags$timestamp <- timestamp
  wiki_contributions$timestamp <- timestamp
  contributions_diaries$timestamp <- timestamp
  contributions_summary$timestamp <- timestamp

  # Anonymize data if requested
  if (anonymize) {
    anonymize_id <- function(x) paste0("anon_", seq_along(x))
    changesets$user <- anonymize_id(changesets$user)
    changesets_details$user <- anonymize_id(changesets_details$user)
    wiki_contributions$user <- anonymize_id(wiki_contributions$user)
    contributions_diaries$user <- anonymize_id(contributions_diaries$user)
    contributions_summary$user <- anonymize_id(contributions_summary$user)
  }

  # Save data to files
  write.csv(changesets, file = paste0(base_path, "data/changesets.csv"), row.names = FALSE)
  sf::st_write(changesets, dsn = paste0(base_path, "data/changesets.gpkg"), append = FALSE)
  write.csv(changesets_tags, file = paste0(base_path, "data/changesets_tags.csv"))
  changesets_details |>
    dplyr::select(-tags, -members) |>
    write.csv(file = paste0(base_path, "data/changesets_details.csv"), row.names = FALSE)
  write.csv(wiki_contributions, paste0(base_path, "data/wiki_contributions.csv"), row.names = FALSE)
  write.csv(contributions_diaries, paste0(base_path, "data/contributions_diaries.csv"), row.names = FALSE)
  write.csv(contributions_summary, paste0(base_path, "data/contributions_summary.csv"), row.names = FALSE)

  # Complete progress bar
  cli::cli_progress_done()

  # Return dataframes
  list(
    changesets = changesets,
    changesets_details = changesets_details,
    changesets_tags = changesets_tags,
    wiki_contributions = wiki_contributions,
    contributions_diaries = contributions_diaries,
    contributions_summary = contributions_summary
  )
}

# Notify user about sensitive data
cat("\nThe datasets generated contain sensitive information. Consider excluding the 'data/raw' folder from version control.\n")
response <- readline("Do you want to generate a .gitignore file to exclude the 'data/raw' folder? (yes/no): ")
if (tolower(response) == "yes") {
  gitignore_path <- file.path(base_path, ".gitignore")
  write("data/raw/", file = gitignore_path, append = TRUE)
  cat(".gitignore file updated to exclude 'data/raw'.\n")
}