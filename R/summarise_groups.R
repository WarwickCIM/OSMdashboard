summarise_group_profile <- function(df) {
  library(dplyr)

  # df is a table of edits with at least: user, date, action, tag

  # frequency of contributions per user
  contribs_per_day <- nrow(df) / length(unique(df$date))
  freq <- case_when(
    contribs_per_day < 1 ~ "occasional",
    contribs_per_day < 10 ~ "frequent",
    TRUE ~ "heavy"
  )

  # activity type of the user defined. if the most common activity is add, the user is a creator etc.
  type <- df %>%
    count(action) %>%
    arrange(desc(n)) %>%
    slice(1) %>%
    pull(action)
  type_word <- recode(type,
                      "add" = "creators",
                      "modify" = "repairers",
                      "delete" = "improvers")

  # experience level of the user defined by the average edits made.
  edits_per_user <- df %>% count(user)
  avg_edits <- mean(edits_per_user$n)
  exp_level <- case_when(
    avg_edits < 50 ~ "hobbyists",
    avg_edits < 500 ~ "pro-ams",
    TRUE ~ "professionals"
  )

  # interests of the users in the group defined by the top three tags used. if there are no tags
  # it will default to a 'variety of interests'
  top_tags <- df %>%
    count(tag) %>%
    arrange(desc(n)) %>%
    slice_head(n = 3) %>%
    pull(tag)

  # homogeneity of users
  contrib_dist <- df %>% count(user)
  top_share <- max(contrib_dist$n) / sum(contrib_dist$n)
  homog <- if (top_share > 0.5) "homogeneous" else "diverse"

  list(freq = freq,
       type = type_word,
       exp = exp_level,
       tags = top_tags,
       homog = homog)
}

describe_group <- function(df) {
  prof <- summarise_group_profile(df)
  sprintf(
    "This is a %s group of %s %s, mainly interested in %s.",
    prof$homog,
    prof$freq,
    prof$type,
    paste(prof$tags, collapse = ", ")
  )
}

