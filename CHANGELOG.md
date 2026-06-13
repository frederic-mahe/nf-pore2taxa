# nf-pore2taxa: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.2.0 - 2026-06-13

### `Changed`

- disable filtering based on primer presence (all reads are kept)
  (experimental)
- the occurrence-table step (`BUILD_TABLE`) is now a dependency-free
  Python 3 script (`bin/build_occurrence_table.py`, standard library
  only), replacing `build_occurrence_table.R`. Output is byte-for-byte
  identical. This removes the `R` + `tidyverse` + `optparse` runtime
  and test dependency. Pure-function and CLI behaviour is covered by a
  new `python3 -m unittest` suite
  (`tests/bin/test_build_occurrence_table.py`); the existing
  `build_occurrence_table.bats` integration test now drives the Python
  script.

### `Removed`

- `bin/build_occurrence_table.R` and the `R` / `tidyverse` / `optparse`
  dependency.

### `Fixed`

- `assign_with_sintax.sh` rejected input directories that contained
  only uncompressed `.fastq` or `.fastq.{bz2,xz}` files, despite
  v1.1.0 having advertised support for those formats. Validation now
  uses the same regex as the main processing loop.


## v1.1.0 - 2026-04-02

### `Added`

- secondary result table with *optimistic* taxonomic assignments
  (assignments with a probability below 0.9 are conserved)
- read headers in sintax files (taxonomic assignment) now have a
  *length* annotation (pattern ";length=n", where n is the read length
  in nucleotides)
- support for uncompressed fastq files, as well as fastq files
  compressed with `bzip2` or `xz`
- runtime checks for user-defined parameters

### `Changed`

### `Fixed`

- force `cutadapt` to output `fasta` sequences when reading compressed
  `fastq`
- issue when skipping basecall for projects where the `fastq` file in
  the data folder are not distributed into subfolders. The
  `fastq_pass` folder was duplicated.

### `Dependencies`

### `Removed`


## v1.0.0 - 2026-03-26

Initial public release

### `Added`

- basecalling and demultiplexing of pod5 ('super accurate') with
  [dorado](https://github.com/nanoporetech/dorado)
- trimming of reads with
  [cutadapt](https://cutadapt.readthedocs.io/en/stable/)
- taxonomic assignment with
  [vsearch](https://github.com/torognes/vsearch) (sintax)
- build an occurrence table (using [R](https://cran.r-project.org/)
  and the [tidyverse](https://tidyverse.org/) package)

The basecalling step can be skipped if `fastq` files are already
available.

### `Changed`

### `Fixed`

### `Dependencies`

### `Removed`
