library(OSMdashboard)
library(dplyr)
library(lubridate)
library(sf)


# Retrieve data -----------------------------------------------------------

group_info <- read.csv("data/group_info.csv")
group_users <- read.csv("data/group_users.csv")

selected_users <- group_users$username

osm_user_details <- get_contributions_osm_users(selected_users)

# Map contributions -------------------------------------------------------

changesets <- get_contributions_changesets(selected_users, 100)

changesets_details <- get_changesets_details(changesets$id)

changesets_tags <- extract_and_combine_tags(changesets_details)

write.csv(changesets, file = "data/changesets.csv", row.names = FALSE)

sf::st_write(changesets, dsn = "data/changesets.gpkg", append = FALSE)

write.csv(changesets_tags, file = "data/changesets_tags.csv")

changesets_details |>
  dplyr::select(-tags, -members) |>
  write.csv(file = "data/changesets_details.csv", row.names = FALSE)


# Wiki --------------------------------------------------------------------

wiki_contributions <- get_contributions_wiki(selected_users) |>
  select(-tags) |>
  as_tibble()

wiki_contributions_n <- wiki_contributions |>
  count(user)

write.csv(wiki_contributions, "data/wiki_contributions.csv",
  row.names = FALSE
)

# Diaries -----------------------------------------------------------------

users_diaries <- osm_user_details |>
  filter(diary > 0) |>
  pull(user)

contributions_diaries <- get_contributions_diaries(users_diaries)
get_contributions_diaries("msevilla00")

write.csv(contributions_diaries,
          "group_contributions/data/contributions_diaries.csv",
          row.names = FALSE
)


# Contributions summary ---------------------------------------------------


contributions_summary <- osm_user_details |>
  mutate(
    user = tolower(user),
    account_age = as.integer(
      difftime(today(), date_creation, units = "days")
    ) / 365
  ) |>
  left_join(wiki_contributions_n, by = "user")

write.csv(contributions_summary,
  "group_contributions/data/contributions_summary.csv",
  row.names = FALSE
)


