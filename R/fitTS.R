fitTS <- function(prep_dir, out_dir, config) {

  # ---- Input Checks ----

  # Check if output directory already exists, otherwise create it
  #if (!dir.exists(out_dir)) dir.create(out_dir) else stop("Output directory already exists.")

  # ---- Metadata Handling ----

  # check metadata
  xml_vi_files  <- list.files(prep_dir, pattern = '.*_(NDVI|EVI)_.*.aux.xml', full.names = TRUE, no.. = TRUE)
  xml_doy_files <- list.files(prep_dir, pattern = '.*_DOY_.*.aux.xml', full.names = TRUE, no.. = TRUE)
  xml_qa_files  <- list.files(prep_dir, pattern = '.*_QA_.*.aux.xml', full.names = TRUE, no.. = TRUE)

  meta_vi  <- .check_bin_metadata(xml_vi_files)
  meta_doy <- .check_bin_metadata(xml_doy_files)
  meta_qa  <- .check_bin_metadata(xml_qa_files)

  # Check if number of rows and cols are identical
  if (!identical(meta_vi$lines, meta_doy$lines) | !identical(meta_vi$lines, meta_qa$lines)) {
    stop("Number of rows does not match.")
  }
  if (!identical(meta_vi$samples, meta_doy$samples) | !identical(meta_vi$samples, meta_qa$samples)) {
    stop("Number of columns do not match.")
  }

  n_rows <- meta_vi$lines
  n_cols <- meta_vi$samples

  # ---- Datacube Construction ----

  # list all prepared files
  bin_vi_files  <- list.files(prep_dir, pattern = '.*_(NDVI|EVI)_.*.envi$', full.names = TRUE, no.. = TRUE)
  bin_doy_files <- list.files(prep_dir, pattern = '.*_DOY_.*.envi$', full.names = TRUE, no.. = TRUE)
  bin_qa_files  <- list.files(prep_dir, pattern = '.*_QA_.*.envi$', full.names = TRUE, no.. = TRUE)

  # check if the lengths of the prepared files are equal
  if (isFALSE(length(unique(c(length(bin_vi_files), length(bin_doy_files), length(bin_qa_files)))) == 1)){
    stop("Number of subdatasets (VI, DOY, QA) do not match.")
  }

  # get the base years from the filenames
  years <- .get_prep_year_str(bin_vi_files)

  # create datacubes
  dc_vi  <- raster::brick(sapply(bin_vi_files, function(x) {
    r <- raster::raster(x)
    names(r) <- basename(x)
    return(r)}))
  names(dc_vi) <- unlist(lapply(bin_vi_files, function (x) {strsplit(basename(x), '_')[[1]][1]}))
  dc_doy <- raster::brick(sapply(bin_doy_files, function(x) {
    r <- raster::raster(x)
    names(r) <- basename(x)
    return(r)}))
  names(dc_doy) <- unlist(lapply(bin_doy_files, function (x) {strsplit(basename(x), '_')[[1]][1]}))
  dc_qa  <- raster::brick(sapply(bin_qa_files, function(x) {
    r <- raster::raster(x)
    names(r) <- basename(x)
    return(r)}))
  names(dc_qa) <- unlist(lapply(bin_qa_files, function (x) {strsplit(basename(x), '_')[[1]][1]}))

  # ---- Curve Fitting ----

  # loop trough all rows
  for (i in 1:n_rows) {

    # Extract all values from the current row from datacube
    logging::logdebug(paste0("Processing row ", i, " of ", n_rows, "..."))
    row_vi  <- raster::getValues(dc_vi, row = i)
    row_doy <- raster::getValues(dc_doy, row = i)
    row_qa  <- raster::getValues(dc_qa, row = i)

    # Loop through all pixels of the extrated row
    for (j in 1:n_cols) {

      logging::logdebug(paste0("Processing col ", j, " of ", n_cols, "..."))

      # extract all values from current pixel => 1 time series curve
      pix_vi  <- row_vi[j, ]
      pix_doy <- row_doy[j, ]
      pix_qa  <- row_qa[j, ]

      # Skip curve fitting when whole time series is NA
      if (all(is.na(pix_vi))) next

      # -- Date Extraction / Correction --

      # load vectors
      pix_years <- years
      pix_doy <- unname(pix_doy)

      # doy correction
      # TODO: Make it FAAAST
      for (d in 1:length(pix_doy)) {
        if (lubridate::leap_year(pix_years[d])) {
          if (!is.na(pix_doy[d])) {
            if (pix_doy[d] > 366) {
              pix_years[d] + 1
              pix_doy[d] - 366
            }
          }
        } else {
          if (!is.na(pix_doy[d])) {
            if (pix_doy[d] > 365) {
              pix_years[d] + 1
              pix_doy[d] - 365
            }
          }
        }
      }

      # TODO: try to fix quick and dirty data wrestling below
      # pix_doy[!is.na(pix_doy) & lubridate::leap_year(pix_years) & pix_doy > 366] <- pix_doy[
      #   !is.na(pix_doy) & lubridate::leap_year(pix_years) & pix_doy > 366] - 366
      # pix_years[!is.na(pix_doy) & lubridate::leap_year(pix_years) & pix_doy > 366] <- pix_years[
      #   !is.na(pix_doy) & lubridate::leap_year(pix_years) & pix_doy > 366] + 1
      # pix_doy[!is.na(pix_doy) & !lubridate::leap_year(pix_years) & pix_doy > 365] <- pix_doy[
      #   !is.na(pix_doy) & !lubridate::leap_year(pix_years) & pix_doy > 365] - 365
      # pix_years[!is.na(pix_doy) & !lubridate::leap_year(pix_years) & pix_doy > 365] <- pix_years[
      #   !is.na(pix_doy) & !lubridate::leap_year(pix_years) & pix_doy > 365] + 1

      # date conversion
      pix_doystr <- paste0(as.character(pix_years), as.character(pix_doy))
      pix_dates <- as.Date(pix_doystr, format = "%Y%j")

      # check input timeseries
      pix_vi <- check_ts(pix_vi, config$general$max_data_gap, config$general$internal_min)

      # weight assignment
      if (isTRUE(config$use_qa)) {
        weights <- MODIS_summary_qa(pix_qa)
      } else {
        weights <- rep(1, length(pix_vi))
      }

      # spike removal
      weights <- switch(config$spike$spike_method,
        Median = spike_median(pix_vi, weights, config$general$n_val_per_year,
                              config$weights$w_min, config&spike$spike_value),
        STL    = spike_stl(),
        STL_w  = spike_stl_w()
      )


      #Sys.sleep(1)
      #pix_vi <- rHarmonics::harmonics_fun(pix_vi, pix_dates, 1)

      # Overwrite the curve with fitted results
      row_vi[j, ] <- pix_vi

    }

    dc_vi[i, ] <- row_vi
  }
  stop()
  for (i in 1:nlayers(dc_vi)) {
    out_file <- file.path(out_dir, paste0(strsplit(basename(bin_vi_files[i]), '_')[[1]][1],
                                                    "_", strsplit(basename(bin_vi_files), '_')[[1]][2],
                                                    "_fit.bin"))
    raster::writeRaster(dc_vi[[i]], out_file, format = "ENVI", datatype = "UInt16")
  }
  #plot(dc_vi[[1]])
}

.check_bin_metadata <- function(xml_files) {

  # Read xml files
  xmls <- lapply(xml_files, xml2::read_xml)

  # Check if all images have the same extent
  lines <- unlist(lapply(xmls, function(x) {xml2::xml_integer(xml2::xml_find_all(x, ".//MDI[@key='lines']"))}))
  samples <- unlist(lapply(xmls, function(x) {xml2::xml_integer(xml2::xml_find_all(x, ".//MDI[@key='samples']"))}))
  if (!length(unique(lines)) == 1 | !length(unique(samples)) == 1) {stop("Image sizes are differing.")}

  # Check if the data has datatype 'UInt16'
  dtype <- unlist(lapply(xmls, function(x) {xml2::xml_integer(xml2::xml_find_all(x, ".//MDI[@key='data_type']"))}))
  if (!all(dtype == 12)) stop("Not all datatypes are UInt16")

  # Check if 1 bands are available
  bands <- unlist(lapply(xmls, function(x) {xml2::xml_integer(xml2::xml_find_all(x, ".//MDI[@key='bands']"))}))
  if (!all(bands == 1)) stop("Some images have more than band.")

  # Check if interleave is BIL
  interleave <- unlist(lapply(xmls, function(x) {xml2::xml_text(xml2::xml_find_all(x, ".//MDI key='interleave'"))}))
  if (!all(interleave == 'bil')) stop("Not all images have interleave 'BIL'.")

  # Check File type
  filetype <- unlist(lapply(xmls, function(x) {xml2::xml_text(xml2::xml_find_all(x, ".//MDI key='file_type'"))}))
  if (!all(filetype == 'ENVI Standard')) stop("Not all images are of file typ 'ENVI Standard'.")

  # Check byte order
  byteorder <- unlist(lapply(xmls, function(x) {xml2::xml_integer(xml2::xml_find_all(x, ".//MDI key='byte_order'"))}))
  if (!all(byteorder == 0)) stop("Not all images have byteorder of 0.")

  # Check header offset
  headeroffset <- unlist(lapply(xmls, function(x) {xml2::xml_integer(xml2::xml_find_all(x, ".//MDI key='header_offset'"))}))
  if (!all(headeroffset == 0)) stop("Not all images have header offset of 0.")

  # Check the NA value
  na_val  <- unlist(lapply(xmls, function(x) {xml2::xml_integer(xml2::xml_find_all(xml2::xml_find_all(x,
                                            ".//PAMRasterBand[@band='1']"), ".//NoDataValue"))}))
  if (length(unique(na_val)) > 1)  stop("Not all images have the same NA value.")

  return(list(lines        = unique(lines),
              samples      = unique(samples),
              dtype        = unique(dtype),
              interleave   = unique(interleave),
              filetype     = unique(filetype),
              byteorder    = unique(byteorder),
              headeroffset = unique(headeroffset),
              na_val       = unique(na_val)))
}
