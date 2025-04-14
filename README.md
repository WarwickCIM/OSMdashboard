
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

This project welcomes any type of contributions, not just coding. It follows the [all-contributors](https://allcontributors.org) specification as a way to recognise that, while addressing Katherine d'Ignazio and Lauren F Klein's [Principle #7 of Data Feminism is to Make Labor Visible](https://data-feminism.mitpress.mit.edu/pub/0vgzaln4/release/3):

> **Make labor visible:** “Starting with questions of data provenance helps to credit the bodies that make visualization possible – the bodies that collect the data, that digitize them, that clean them, and that maintain them. However, most data provenance research focuses on technical rather than human points of origination and integration [66]. With its emphasis on under-valued forms of labor, a feminist approach to visualization can help to render visible the bodies that shape and care for data at every stage of the process. This relates to the concept of provenance rhetoric [44] in which authors of narrative visualizations cite data sources and methods which may help build credibility with the audience.” (Ignazio and Klein, 2016, p. 3)

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="https://digitalgood.net/"><img src="https://warwick.ac.uk/fac/cross_fac/cim/research/digital-good-neutrality-osm/screenshot_2024-09-19_at_10-15-55_esrc_digital_good_network_-_esrc_digital_good_network.png?s=100" width="100px;" alt="ESRC Digital Good Network"/><br /><sub><b>ESRC Digital Good Network</b></sub></a><br /><a href="#financial" title="Financial">💵</a></td>
      <td align="center" valign="top" width="14.28%"><a href="http://carloscamara.es/en"><img src="https://avatars.githubusercontent.com/u/706549?v=4?s=100" width="100px;" alt="Carlos Cámara"/><br /><sub><b>Carlos Cámara</b></sub></a><br /><a href="https://github.com/WarwickCIM/OSMdashboard/commits?author=ccamara" title="Code">💻</a> <a href="#ideas-ccamara" title="Ideas, Planning, & Feedback">🤔</a> <a href="#design-ccamara" title="Design">🎨</a> <a href="#infra-ccamara" title="Infrastructure (Hosting, Build-Tools, etc)">🚇</a> <a href="#research-ccamara" title="Research">🔬</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/timothymonteath"><img src="https://avatars.githubusercontent.com/u/17410066?v=4?s=100" width="100px;" alt="timothymonteath"/><br /><sub><b>timothymonteath</b></sub></a><br /><a href="#ideas-timothymonteath" title="Ideas, Planning, & Feedback">🤔</a> <a href="#research-timothymonteath" title="Research">🔬</a></td>
      <td align="center" valign="top" width="14.28%"><a href="http://seleneyang.info"><img src="https://avatars.githubusercontent.com/u/20440464?v=4?s=100" width="100px;" alt="Selene Yang"/><br /><sub><b>Selene Yang</b></sub></a><br /><a href="#ideas-seleneyang" title="Ideas, Planning, & Feedback">🤔</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/silvira"><img src="https://avatars.githubusercontent.com/u/78524262?v=4?s=100" width="100px;" alt="silvira"/><br /><sub><b>silvira</b></sub></a><br /><a href="#ideas-silvira" title="Ideas, Planning, & Feedback">🤔</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/malecanclini"><img src="https://avatars.githubusercontent.com/u/166962846?v=4?s=100" width="100px;" alt="malecanclini"/><br /><sub><b>malecanclini</b></sub></a><br /><a href="#ideas-malecanclini" title="Ideas, Planning, & Feedback">🤔</a></td>
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
