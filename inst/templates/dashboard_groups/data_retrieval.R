library(dplyr)
library(osmapiR)

files.sources = list.files("group_contributions/R/", full.names = TRUE)
sapply(files.sources, source)

# Retrieve data -----------------------------------------------------------

group_info <- read.csv("data/group_info.csv")
group_users <- read.csv("data/group_users.csv")

selected_users <- group_users$username



# Map contributions -------------------------------------------------------

changesets <- get_contributions_changesets(selected_users, group_name, 500)

changesets_details <- data.frame()
tags_used <- data.frame()

for (changeset in changesets$id) {
  tmp.changesets_details <- osm_download_changeset(changeset)

  changesets_details <- changesets_details |>
    bind_rows(tmp.changesets_details)

  # TODO: some changesets are split in more than one part: modify, delete... the
  # lines below fail when there's more than one row with a changeset id.

  # tmp.tags <-  as.data.frame(tmp.changesets_details$tags) |>
  #   mutate(changeset = changeset)
  #


  # tags_used <- tags_used |>
  # bind_rows(tmp.tags)

}

changesets_tags <- extract_and_combine_tags(changesets_details)

write.csv(changesets, file = "group_contributions/data/changesets.csv", row.names = FALSE)

sf::st_write(changesets, dsn = "group_contributions/data/changesets.gpkg", append = FALSE)

write.csv(changesets_tags, file = "group_contributions/data/changesets_tags.csv")

changesets_details |>
  select(-tags, -members) |>
  write.csv(file = "group_contributions/data/changesets_details.csv",
            row.names = FALSE)

save(changesets_details, file = "group_contributions/data/changesets_details.rda")

# test <- as.data.frame(head(changesets_details$tags,2))

# test <- unlist(changesets_details$tags)


# OSM user ----------------------------------------------------------------

osm_user_details <- get_contributions_osm_users(selected_users)


write.csv(osm_user_details, "group_contributions/data/osm_user_details.csv",
          row.names = FALSE)

# Wiki --------------------------------------------------------------------

wiki_contributions <- get_contributions_wiki(selected_users) |>
  select(-tags) |>
  as_tibble()

write.csv(wiki_contributions, "group_contributions/data/wiki_contributions.csv",
          row.names = FALSE)


# Contributions summary ---------------------------------------------------

contributions_summary <- osm_user_details |>
  mutate(user = tolower(user),
         account_age = as.integer(
           difftime(today(), date_creation, units = "days"))/365 ) |>
  left_join(wiki_contributions_n, by = "user")

write.csv(contributions_summary,
          "group_contributions/data/contributions_summary.csv",
          row.names = FALSE)

# Diaries -----------------------------------------------------------------

users_diaries <- contributions_summary |>
  filter(diary > 0) |>
  pull(user)

contributions_diaries <- get_contributions_diaries(users_diaries)

write.csv(contributions_diaries,
          "group_contributions/data/contributions_diaries.csv",
          row.names = FALSE)

#TODO: detect language (read https://cran.r-project.org/web/packages/fastText/vignettes/language_identification.html)


