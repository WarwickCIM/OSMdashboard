#' Create a dashboard template
#'
#' Scaffolds the files and folders needed to produce OSM dashboards by copying
#' the necessary structure from inst/templates/ located in this package.
#'
#' @param path a string containing the destination path where the dashboard is
#'   going to reside.
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
create_dashboard <- function(path) {
  # Get the path to the folder within the package
  package_folder <- system.file(
    "templates/dashboard_groups",
    package = "OSMdashboard"
  )

  # Check if the folder exists in the package
  if (package_folder == "") {
    stop("The folder does not exist in the package.")
  }

  # Ask to overwrite existing directory
  if (dir.exists(path)) {
    # Display a menu asking to confirm folder's overwrite
    cli::cli_alert_danger("The folder {path} already exists.")
    choice <- menu(c("Overwrite", "Cancel"), title = "What would you like to do?")
    
    # Handle the user's choice
    if (choice == 2 || choice == 0) { # 2 = Cancel, 0 = No selection
      cli::cli_alert_info("Operation cancelled. No files were copied to avoid overwriting folder.")
      return(invisible(NULL)) # Exit the function without further execution
    }
    
    # If the user selects "Overwrite", proceed
    cli::cli_alert_info("Overwritting the folder {path}/ ...")
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

  if (!dir.exists(paste0(path, "/data/raw/"))) {
    dir.create(paste0(path, "/data/raw/"), recursive = TRUE)
  }

  if (!dir.exists(paste0(path, "/data/processed/"))) {
    dir.create(paste0(path, "/data/processed/"), recursive = TRUE)
  }

  absolute_path <- paste0(getwd(), "/", path)

  cli::cli_alert_success("Dashboard scaffolded successfully at: {absolute_path}.")
}
