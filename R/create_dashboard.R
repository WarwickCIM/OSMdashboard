#' Create a dashboard template
#'
#' Scaffolds the files and folders needed to produce OSM dashboards by copying
#' the necessary structure from inst/templates/ located in this package.
#'
#' @param path a string containing the destination path where the dashboard is
#'   going to reside.
#' @param overwrite boolean specifying whether to overwrite the folder if it
#'   exists.
#'
#' @returns a folder containing the template to start editing the dashboard.
#' @export
#'
#' @examples
#' # Save the current working directory
#' original_wd <- getwd()
#'
#' # Create a temporary directory
#' temp_dir <- tempdir()
#'
#' # Set the working directory to the temporary directory
#' setwd(temp_dir)
#'
#' # Run the scaffold_dashboard function to create the dashboard
#' create_dashboard("dashboard_folder")
#'
#' # Check the contents of the created dashboard folder
#' list.files("dashboard_folder", recursive = TRUE)
#'
#' # Clean up: delete the created dashboard folder
#' unlink("dashboard_folder", recursive = TRUE)
#'
#' # Restore the original working directory
#' setwd(original_wd)
create_dashboard <- function(path, overwrite = FALSE) {
  # Get the path to the folder within the package
  package_folder <- system.file(
    "templates/dashboard_groups",
    package = "OSMdashboard"
  )

  # Check if the folder exists in the package
  if (package_folder == "") {
    stop("The folder does not exist in the package.")
  }

  # Ensure the destination path exists, create it if it doesn't
  if (!dir.exists(path)) {
    dir.create(path, recursive = TRUE)
  }

  # List all files and directories within the templates folder
  files <- list.files(package_folder, full.names = TRUE, recursive = TRUE)

  # Copy each file while preserving the folder structure
  for (file in files) {
    # Determine the relative path of the file
    relative_path <- sub(paste0("^", package_folder, "/"), "", file)

    # Construct the destination path for the file
    destination <- file.path(path, relative_path)

    # Create the destination directory if it doesn't exist
    dir.create(dirname(destination), recursive = TRUE, showWarnings = FALSE)

    # Copy the file to the destination
    file.copy(file, destination, overwrite = TRUE)
  }

  message("Dashboard scaffolded successfully at: ", path)
}
