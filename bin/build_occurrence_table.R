#!/usr/bin/env Rscript

library(tidyverse)
library(optparse)

option_list <- list(
    make_option(c("-i", "--input-dir"),
                dest = "inputdir",
                type = "character",
                help = "Input directory to search"),
    make_option(c("-o", "--output"),
                type = "character",
                help = "Output TSV file"),
    make_option(c("-p", "--pattern"),
                type = "character",
                default = "\\.sintax$",
                help = "File pattern [default: %default]")
)

opt <- parse_args(OptionParser(option_list = option_list))


## ------------------------------------------------------------------ constants

header          <- c("query", "full_taxonomy", "strand", "taxonomy")
barcode_pattern <- "barcode[0-9]+|unclassified|mixed"


## ------------------------------------------------------------------ functions

validate_args <- function(opt) {
    if (is.null(opt$inputdir)) {
        stop("--inputdir is required. Use --help for usage.")
    }

    if (!file.exists(opt$inputdir)) {
        stop(sprintf("Path does not exist: '%s'", opt$inputdir))
    }

    if (!dir.exists(opt$inputdir)) {
        stop(sprintf("Path exists but is not a directory: '%s'", opt$inputdir))
    }

    if (is.null(opt$output)) {
        stop("--output is required. Use --help for usage.")
    }

    output_parent <- dirname(opt$output)
    if (!dir.exists(output_parent)) {
        dir.create(output_parent, recursive = TRUE)
    }

    if (file.access(output_parent, mode = 2) != 0) {
        stop(sprintf("Output directory is not writable: '%s'", output_parent))
    }
}


name_optimistic_output <- function(output_name) {
    extension <- str_extract(output_name, "\\.[[:alpha:]]+$")
    new_extension <- str_c("_optimistic", extension)
    str_replace(output_name, fixed(extension), fixed(new_extension))
}


is_empty <- function(file) {
  file.info(file)$size == 0
}


is_non_empty <- function(file) {
  file.info(file)$size > 0
}


get_list_of_barcodes <- function(directory, pattern) {
  list.files(path = directory,
             pattern = pattern,
             recursive = TRUE,
             full.names = TRUE)
}


abort_if_empty_file_list <- function(barcodes) {
    if (length(barcodes) == 0) {
        stop("No sintax files found. Aborting.")
    }
}


keep_non_empty_barcodes <- function(barcodes) {
  barcodes |>
    purrr::keep(is_non_empty)
}


keep_empty_barcodes <- function(barcodes, pattern) {
  barcodes |>
    purrr::keep(is_empty)
}


process_a_barcode <- function(a_barcode, col_names) {
  read_tsv(a_barcode,
           col_names = col_names,
           show_col_types = FALSE) |>
    select(full_taxonomy, taxonomy)
}


process_all_barcodes <- function(barcodes, col_names) {
  barcodes |>
    purrr::set_names() |>
    purrr::map(\(a_barcode) process_a_barcode(a_barcode, col_names)) |>
    list_rbind(names_to = "barcode")
}


trim_empty_barcode_names <- function(barcodes, pattern) {
  barcodes |>
    str_extract(pattern)
}


trim_barcode_names <- function(df, pattern) {
  df |>
    mutate(barcode = str_extract(barcode, pattern))
}


select_full_taxonomy <- function(df) {
    ## remove probability values
    df |>
        mutate(taxonomy = str_remove_all(full_taxonomy,
                                         "\\([:digit:]+\\.[:digit:]+\\)")) |>
        select(-full_taxonomy)
}


mark_unassigned_reads <- function(df) {
  df |>
    mutate(taxonomy = replace_na(taxonomy, "unknown"))
}


dereplicate_per_barcode <- function(df) {
  df |>
    arrange(barcode, taxonomy) |>
    count(barcode, taxonomy, name = "reads")
}


dereplicate_globally <- function(df) {
  df |>
    arrange(taxonomy) |>
    add_count(taxonomy, wt = reads, name = "total")
}


format_table <- function(df) {
  df |>
    arrange(barcode) |>
    pivot_wider(names_from = "barcode",
                values_from = "reads",
                values_fill = 0) |>
    arrange(desc(total), taxonomy)
}


append_empty_barcodes <- function(df, list_of_empty_barcodes) {
  list_of_empty_barcodes |>
      purrr::reduce(\(acc, barcode) add_column(acc, !!barcode := 0),
                    .init = df)
}


build_table <- function(barcodes, empty_barcodes,
                        col_names, pattern,
                        pick_taxonomy = identity) {
    barcodes |>
        keep_non_empty_barcodes() |>
        process_all_barcodes(col_names) |>
        trim_barcode_names(pattern) |>
        pick_taxonomy() |>
        mark_unassigned_reads() |>
        dereplicate_per_barcode() |>
        dereplicate_globally() |>
        format_table() |>
        append_empty_barcodes(empty_barcodes)
}


export_table <- function(df, output) {
    write_tsv(df, output)
}


## ----------------------------------------------------------------------- main

validate_args(opt)

barcodes <- get_list_of_barcodes(opt$inputdir, opt$pattern)

## expect at least one barcode
barcodes |>
    abort_if_empty_file_list()

## get list of empty barcodes, if any
barcodes |>
  keep_empty_barcodes() |>
  trim_empty_barcode_names(barcode_pattern) -> empty_barcodes

## produce filtered output table
build_table(barcodes, empty_barcodes,
            header, barcode_pattern) |>
    export_table(opt$output)

## produce optimistic output table
build_table(barcodes, empty_barcodes,
            header, barcode_pattern,
            select_full_taxonomy) |>
    export_table(name_optimistic_output(opt$output))

quit(save = "no")
