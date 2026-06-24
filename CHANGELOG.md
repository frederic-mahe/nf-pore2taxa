# nf-pore2taxa: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.4.0 - 2026-06-24

### `Changed`

- **per-barcode fan-out.** The monolithic `SINTAX` task (one process over
  the whole run, looping internally and re-loading the reference once per
  fastq file) is replaced by one task per barcode, run in parallel. Each
  barcode's fastq files are primer-trimmed and assigned with a **single**
  `vsearch` run, so the reference database is loaded once per barcode
  rather than once per file — a large saving when a barcode is split into
  many small files. This also gives per-barcode failure isolation and
  granular `-resume`.
- barcode identity is now derived by regex over the path, so both the
  demultiplexed-into-folders layout (`fastq_pass/barcode01/…`) and the
  flat layout with the barcode embedded in the filename
  (`…_barcode01_0.fastq.gz`) are supported. Discovery is rooted at
  `fastq_pass`, so a sibling `fastq_fail/` is ignored.
- `assign_with_sintax.sh` now takes `--barcode` and one or more FASTQ
  files (replacing `--input-dir`); it writes `<barcode>.sintax` /
  `<barcode>.log`. Internal driver — no backward-compatibility shim.

### `Added`

- `bin/discover_barcodes.py` (stdlib only): discovers fastq files under a
  `fastq_pass` tree and groups them by barcode for the fan-out, aborting
  with a clear error if a file carries no recognisable barcode token.
  Covered by `tests/bin/test_discover_barcodes.py` (DSC-01..05).
- fixtures: a flat-layout `flat_dir` (barcode in the filename, a
  multi-file barcode, and a `fastq_fail/` that must be ignored).

### `Removed`

- the `done_sintax.txt` sentinel (replaced by a real `.collect()` gather)
  and the `trim_extension` helper (per-file output naming is gone).

## v1.3.0 - 2026-06-24

### `Added`

- `discard_untrimmed` parameter (default `true`) toggling primer-presence
  filtering in `assign_with_sintax.sh`. When `true`, a read is dropped
  unless both the forward primer and the reverse-complemented reverse
  primer are found (strict amplicon filtering); when `false`, every read
  is kept and trimmed only where a primer is found. Exposed on the driver
  script as `--discard-untrimmed` / `--keep-untrimmed`. Covered by SX-13.
- `conda` profile and pinned `environment.yml` (vsearch 2.31.0, cutadapt
  5.2, python 3.12) so dependencies resolve reproducibly without relying
  on the bare `PATH`. Scoped to the `SINTAX`/`BUILD_TABLE` steps; `dorado`
  (BASECALL) is an ONT GPU binary not on bioconda and stays bare-PATH. The
  in-script `vsearch` version check remains the safety net for bare-PATH
  runs.
- `publish_mode` parameter (default `link`) selecting the `publishDir`
  mode; set to `copy` when `workDir` and the data/results directories are
  on different filesystems (hard links cannot cross devices). Also governs
  how `SINTAX` stages its input.
- startup parameter validation in `main.nf`: a run missing a required
  value (`sintax_references`, `results_table`, `primer_f`, `primer_r`, the
  mode-appropriate `fastq_dir`/`pod5_dir`) or holding an invalid
  `discard_untrimmed`/`publish_mode` aborts with a single aggregated
  report before any process runs. Covered by WF-11.
- process resilience: failures in the OOM/kill exit-code range
  (137..140) now retry (`maxRetries = 2`) with memory escalating per
  `task.attempt`; deterministic failures still terminate immediately. The
  memory escalation is mainly forward-compatibility for a scheduler; the
  local executor cannot grant more RAM on retry. `time` stays disabled
  until the cluster profile is fleshed out.
- GitHub Actions CI (`.github/workflows/test.yml`) running the python,
  bats, nf-test and shellcheck layers on every push and pull request.

### `Fixed`

- restore primer-presence filtering as the default, undoing the
  experimental "disable primer filtering" change that left every read
  assigned and broke the `barcode03` fixture invariants (SX-33, BT-13).
- `BUILD_TABLE` now resolves its `publishDir` path lazily (a closure), so
  a null `results_table` is reported by the startup validation instead of
  a raw `file()` error at process-definition time.
- resolve shellcheck warnings in the `bin/` and `tests/` shell scripts
  (SC2155, SC2164) and add a `.shellcheckrc` so the sourced
  `bin/lib/validation.sh` is followed (SC1091).

## v1.2.1 - 2026-06-20

### `Deprecated`

- `sintax_silva` is restored as a deprecated alias for
  `sintax_references`. When supplied, the pipeline emits a warning and
  falls back to it only when `sintax_references` is not set. The alias
  will be removed in a future release; please migrate to
  `sintax_references`.

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
