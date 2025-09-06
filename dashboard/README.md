This folder contains the structure needed to create a dashboard displaying how a certain group of users contribute to OSM.

## Instructions

1. Edit `data/group_info.csv` and replace the default values, keeping the column names.
2. Edit `data/group_users.csv` and replace `<demo_user>` with an actual OSM username. Add as many rows as needed, but keep the column name. New columns will be ignored.
3. Run `data_retrieval.R` to retrieve all the data needed for the dashboard.
4. Render `dashboard.qmd` to generate the dashboard. To do so, you will need quarto installed (see instructions) and then either:
  1. Run the following command in the terminal from the folder:
    ```bash
    quarto render dashboard.qmd
    ```
  2. From RStudio click on render
