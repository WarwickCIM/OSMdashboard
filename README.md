
# OSMdashboard

<!-- badges: start -->
[![Project Status: WIP – Initial development is in progress, but there
has not yet been a stable, usable release suitable for the
public.](https://www.repostatus.org/badges/latest/wip.svg)](https://www.repostatus.org/#wip)
[![All Contributors](https://img.shields.io/github/all-contributors/WarwickCIM/OSMdashboard?color=ee8449&style=flat-square)](#contributors)
[![R-CMD-check](https://github.com/WarwickCIM/OSMdashboard/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/WarwickCIM/OSMdashboard/actions/workflows/R-CMD-check.yaml)

<!-- badges: end -->

> \[!WARNING\]  
> This package is highly experimental and is still a WIP. Expect
> uncomplete features, frequent breaks, uncomplete documentation and changes in the API.


The goal of OSMdashboard is to create interactive dashboards that visualise OSM-data locally and just by filling a csv file.

![Dashboard screenshot](man/figures/dashboard-screenshot.png)

## Citing


## Acknowledgements


## Installation

You can install the development version of OSMdashboard from [GitHub](https://github.com/) with:

``` r
# install.packages("devtools")
devtools::install_github("WarwickCIM/OSMdashboard")
```

## Example

You can easily create a dashboard displaying group contributions by:

1. Create a template running the code below:
    ``` r
    # Create a template
    OSMdashboard::create_dashboard("my_folder")

    ```
2. Edit `data/group_info.csv` and replace the default values, keeping the column names.
3. Edit `data/group_users.csv` and replace `<demo_user>` with an actual OSM username. Add as many rows as needed, but keep the column name. New columns will be ignored.
4. Run `data_retrieval.R` to retrieve all the data needed for the dashboard.
5. Render `dashboard.qmd` to generate the dashboard. To do so, you will need quarto installed (see instructions) and then either:
  1. Run the following command in the terminal from the folder:
    ```bash
    quarto render dashboard.qmd
    ```
  2. From RStudio click on render

## Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="http://carloscamara.es/en"><img src="https://avatars.githubusercontent.com/u/706549?v=4?s=100" width="100px;" alt="Carlos Cámara"/><br /><sub><b>Carlos Cámara</b></sub></a><br /><a href="#code-ccamara" title="Code">💻</a> <a href="#ideas-ccamara" title="Ideas, Planning, & Feedback">🤔</a> <a href="#design-ccamara" title="Design">🎨</a> <a href="#infra-ccamara" title="Infrastructure (Hosting, Build-Tools, etc)">🚇</a> <a href="#research-ccamara" title="Research">🔬</a></td>
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
