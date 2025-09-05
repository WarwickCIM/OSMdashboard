#' Create a text describing the group
#'
#'
#' @param path a string containing the destination path where the data resides. The function will look for the following files:
#' 
#' @param type a string defining what we want to caption (everything, just size, temporal patterns...)
#' 
#' @param format speficy whether we want plain text or html/md
#'
#' @returns a string.
#' @export
#'
#' @examples
caption_group <- function(path, type, format) {

  

  if(format = "txt") {
    return(caption_txt)
  }

  if (format = "HTML") {
    return (caption_html)
  }

}