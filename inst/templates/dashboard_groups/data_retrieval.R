library(OSMdashboard)
library(dplyr)
library(lubridate)
library(sf)


# Retrieve data -----------------------------------------------------------

# Add folder name if dashboard is not in the root of the project. Add trailing /
base_path <- ""

group_info <- read.csv(paste0(base_path, "data/metadata/group_info.csv"))
group_users <- read.csv(paste0(base_path, "data/metadata/group_users.csv"))

selected_users <- group_users$username

osm_user_details <- get_contributions_osm_users(selected_users)

# Map contributions -------------------------------------------------------

changesets <- get_contributors_changesets(selected_users, 100)

changesets_details <- get_changesets_details(changesets$id)

changesets_tags <- extract_and_combine_tags(changesets_details)

write.csv(
  changesets,
  file = paste0(base_path, "data/raw/changesets.csv"),
  row.names = FALSE
)

sf::st_write(
  changesets,
  dsn = paste0(base_path, "data/raw/changesets.gpkg"),
  append = FALSE
)

write.csv(
  changesets_tags,
  file = paste0(base_path, "data/raw/changesets_tags.csv")
)

changesets_details |>
  dplyr::select(-tags, -members) |>
  write.csv(
    file = paste0(base_path, "data/raw/changesets_details.csv"),
    row.names = FALSE
  )


# Wiki --------------------------------------------------------------------

wiki_contributions <- get_contributions_wiki(selected_users) |>
  select(-tags) |>
  as_tibble()

wiki_contributions_n <- wiki_contributions |>
  count(user) |>
  mutate(user = tolower(user)) |>
  rename(wiki_edits = n)

write.csv(
  wiki_contributions,
  paste0(base_path, "data/raw/wiki_contributions.csv"),
  row.names = FALSE
)

# Diaries -----------------------------------------------------------------

users_diaries <- osm_user_details |>
  filter(diary > 0) |>
  pull(user)

contributions_diaries <- get_contributions_diaries(users_diaries)

write.csv(
  contributions_diaries,
  paste0(base_path, "data/raw/contributions_diaries.csv"),
  row.names = FALSE
)


# Contributions summary ---------------------------------------------------

contributions_summary <- osm_user_details |>
  mutate(
    user = tolower(user),
    account_age = as.integer(
      difftime(today(), date_creation, units = "days")
    ) /
      365,
    map_activity_age = as.integer(
      difftime(date_last_map_edit, date_creation, units = "days")
    ) /
      365
  ) |>
  left_join(wiki_contributions_n, by = "user")

write.csv(
  contributions_summary,
  paste0(base_path, "data/raw/contributions_summary.csv"),
  row.names = FALSE
)
