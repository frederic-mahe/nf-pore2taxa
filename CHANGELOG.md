# nf-pore2taxa: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

## v1.9.0 - 2026-07-29

Provenance: every run now explains itself. No change to any existing
parameter or to the analysis.

### `Added`

- **`pipeline_info/` beside the occurrence tables**, holding everything
  needed to account for a run. Archive it with the tables and two labs can
  diff exactly what differed between them, instead of guessing. This is
  the layout `--outdir` will adopt, so that release re-roots the directory
  rather than relocating files.
- **`software_versions.yml`** — the version of every tool that ran
  (`vsearch`, `cutadapt`, KronaTools, Python) plus the pipeline release
  and the Nextflow that ran it, sorted so two runs' files compare
  directly. A tool that cannot be probed is recorded as `n/a` rather than
  omitted: an absent line reads as "not used", which is a different and
  more misleading claim than "could not determine". Built by a new
  `DUMP_VERSIONS` process over the new stdlib `bin/collect_versions.py`,
  which reduces the tools' wildly different version formats (a bare `5.2`,
  `vsearch v2.31.0_linux_x86_64, ...`, dorado's `1.1.1+3c7eef9`, and
  KronaTools, which has **no** `--version` and only states it in a banner)
  to one clean token. Covered by PRV-01, PRV-02, PRV-06, PRV-10..13.
- **`dorado`'s version comes from `BASECALL` itself**, emitted as a text
  fragment that `DUMP_VERSIONS` merges. dorado is an ONT GPU binary,
  absent from the conda environment, and on a cluster it may not exist at
  all on the node the probe lands on — so the task that actually ran it is
  the only honest source. No `dorado` entry appears when basecalling was
  skipped, since recording a version for a tool that never executed would
  be a false claim about how the data was produced. Covered by PRV-03,
  PRV-06b — and covered *without* dorado, a GPU or a model download, which
  makes it the first part of the basecalling path under test at all.
- **`params.json`** — the **effective** configuration: every parameter as
  it was really in force. Booleans are recorded as JSON booleans rather
  than the CLI's truthy `'false'` string, and `sintax_references` records
  the path actually read after the deprecated `sintax_silva` alias is
  resolved, so the file cannot document the opposite of what the run did.
  Covered by PRV-04, PRV-07.
- **execution reports on by default** — `execution_report.html`,
  `execution_timeline.html`, `execution_trace.txt` and `pipeline_dag.html`
  in `pipeline_info/`, with no flag to remember: provenance you have to
  opt into is provenance you will not have. Fixed filenames with
  `overwrite = true`, so a re-run refreshes them in place instead of
  aborting at the *end* of the run because the file already exists. The
  trade-off, stated plainly: a `-resume` report describes the resumed run
  and replaces the earlier one — copy `pipeline_info/` first if you need
  both. The trace carries requested-vs-observed `cpus`/`memory`/`realtime`/
  `peak_rss`, which is how a lab sees the effect of the v1.8.0 ceiling. The
  DAG is rendered as HTML (bundled mermaid), so no graphviz is needed.
  Covered by PRV-05.

`params.json` deliberately omits the session id and command line. Both
vary per *invocation* rather than per configuration, and including them
made the task re-run on every `-resume` — costing the clean "nothing
changed" signal (SX-35) to duplicate what Nextflow's own report and
`.nextflow.log` already record. This file answers "with what settings?";
the report answers "which run?". PRV-08b pins that `-resume` still
re-executes nothing.

## v1.8.0 - 2026-07-29

Runs on the machine you have, and says what it did. No change to any
existing parameter's meaning.

### `Added`

- **resource ceiling, so the pipeline runs on the machine you have.** The
  per-step requests are written for a well-provisioned host (`SINTAX`
  asks for 20 cpus and 16 GB), and the local executor does not scale
  those down — it refuses: `Process requirement exceeds available CPUs
  -- req: 20; avail: 8`. Any workstation with fewer than 20 cores
  therefore died before doing any biology, with an error that reads like
  the machine's fault. `process.resourceLimits` now clamps every request,
  including a retry's `* task.attempt` escalation, to two new params:
  - `--max_cpus` (default: the host's core count)
  - `--max_memory` (default: the host's RAM)

  The defaults come from the same helper the local executor uses for that
  comparison, so the two cannot disagree — a request can no longer exceed
  what the executor will allow. A request above the ceiling is silently
  reduced rather than refused, so the startup log now reports the
  effective ceiling: a run that used fewer threads than the config asks
  for is explicable rather than mysterious. Covered by CFG-04, including
  an end-to-end case that runs the **real** resource config under a
  2-cpu / 3 GB ceiling and checks `--threads 2` reached vsearch.

  The `cluster` profile sets both **explicitly** (16 cpus / 128 GB,
  conservative placeholders for a site to override) and never
  auto-detects: under a scheduler the detected value describes the
  *submit* host, whose size says nothing about the compute nodes, so
  detection there would silently shrink every submitted job.
- `valid_memory()` in `modules/local/functions.nf`, so an unparseable
  `--max_memory` is rejected at startup instead of surfacing as a bare
  "Not a valid FileSize value" on the first task submission. Unit-tested
  (FN-05) across both forms the param arrives in — a CLI string and a
  real `MemoryUnit` — plus zero, negative and malformed sizes.
- **`manifest.nextflowVersion = '>=24.04.0'`** and
  `manifest.defaultBranch = 'main'`. The floor is the requirement of
  `process.resourceLimits`, which the resource ceiling is built on: an
  older Nextflow ignores an unknown directive *silently*, so every request
  would go through unclamped and the "requirement exceeds available"
  failure would return with no diagnostic. Declaring it turns that into a
  clear refusal at startup. `CFG-05b` guards the floor against being
  lowered below 24.04 by mistake. Caveat: CI exercises one Nextflow
  version, so this is the documented requirement of the feature we use,
  not a version the suite has been run against — a pinned + latest matrix
  is what would make it trustworthy, and is planned with the cluster work.
- **startup run summary.** Nextflow's header reports the version, profile
  and work directory but never the effective *parameters*, which is
  exactly what a lab needs later to answer "what did this table come
  from?". Every result-affecting parameter is now logged as a one-screen
  block, with the ambiguous ones spelled out (`discard_untrimmed = true
  (strict amplicon filtering)`, `subsample = 0 (disabled)`) and the
  resolved ceiling including the thread count `SINTAX` will actually get.
  Until `versions.yml` lands this block is the pipeline's only provenance
  record. Covered by CFG-06.
- **`randseed` reproducibility warning.** vsearch sintax is
  order-dependent across threads, so a fixed seed does **not** make a
  multithreaded run replayable — a caveat that previously lived only in
  comments and the README, leaving a user who set a seed believing they
  had reproducibility they did not have. Setting `randseed` now warns when
  `SINTAX` will run on more than one thread, and points at the fix
  (`--max_cpus 1`). It keys off the *effective* thread count via the new
  `effective_threads()` helper (FN-06), so a genuinely single-threaded
  seeded run is not warned about — a warning that fires when it does not
  apply just teaches people to ignore it. (vsearch 2.32.0 is expected to
  remove the underlying limitation; when the pin is bumped this warning
  goes away and `SINTAX`'s tests can assert exact content.)

### `Fixed`

- the fastq enumeration added in v1.7.1 used `file()` with a glob, which
  Nextflow 26 deprecates in favour of `files()` ("use `files()` instead")
  — it emitted a warning on every run. Switched to `files()`; caching and
  the `-resume` behaviour are unchanged (SX-35, DSC-06 still pass).

## v1.7.1 - 2026-07-29

Correctness release ahead of external adoption: five defects that could
each make a run report **SUCCESS** while producing a wrong, stale, or
unreadable result. No new features, no change to the meaning of any
existing parameter. See
[`docs/plans/TBD_20260729_hardening.md`](docs/plans/TBD_20260729_hardening.md)
for the full review this comes from.

### `Fixed`

- **published outputs could be silently unreadable.** `cleanup = true`
  was the shipped default while `publish_mode` accepted `symlink` and
  `rellink`, so the work directory was deleted *after* links into it were
  published: both occurrence tables, every per-barcode `.sintax`, and
  both Krona HTMLs became dangling links, under a run that exited 0.
  `cleanup` now defaults to **false** (a successful run also stays
  resumable and inspectable) and is exposed as `--cleanup` for throwaway
  runs; the incompatible `cleanup = true` + link-mode combination is
  rejected at startup rather than trusted to a default. `move` is no
  longer an accepted `publish_mode` at all — `BASECALL`'s downstream
  handoff reads the fastq back out of the task work directory, which
  moving them away empties. Covered by CFG-02, CFG-03.
- **`-resume` silently ignored new reads.** `DISCOVER_BARCODES` received
  the `fastq_pass` path as an unstaged value, so Nextflow's cache key did
  not reflect the tree's contents: adding a fastq to an **existing**
  barcode directory — a topped-up library, a second flow cell for one
  barcode — was a full cache hit, and the run republished the previous
  table with the new reads dropped. (Adding a *new* barcode directory
  happened to work, via the parent's mtime, which made the failure look
  like working behaviour.) `main.nf` now enumerates the run's fastq and
  passes the sorted list into the process, so any added or removed file
  invalidates discovery while an unchanged re-run stays a full cache hit.
  Covered by SX-35, DSC-06.
- **a `results_table` not ending in `.tsv` lost every result.**
  `BUILD_TABLE` declared `output: path "*.tsv"` but wrote the filename
  taken from `results_table`, so e.g. `results/table.txt` ran every
  `SINTAX` task, exited 0 from the script, and then failed the task on a
  missing output — publishing nothing, at the most expensive possible
  moment. The two outputs are now declared by exact name via the new
  `optimistic_name()` helper (mirroring `name_optimistic_output()` in
  `build_occurrence_table.py`), so any extension works. Covered by
  WF-15, FN-03.
- **`--skip_basecall false` skipped basecalling.** A command-line
  override arrives as the *string* `'false'`, which is truthy in Groovy,
  and the branch tested `params.skip_basecall` directly — so asking for
  basecalling silently reused whatever was in `fastq_dir` instead. This
  is the boolean the v1.7.0 `discard_untrimmed`/`krona` fix did not
  reach. Every declared boolean (`skip_basecall`, `discard_untrimmed`,
  `krona`, `cleanup`, `help`) now goes through `valid_bool()` in
  validation and `coerce_bool()` at the point of use, from a single list,
  so the next boolean added cannot repeat this. Covered by WF-16.
- **`fastq_dir` was required in only one of the two modes.** `BASECALL`
  publishes into it and `SINTAX` publishes each barcode's results
  beneath it, but it was validated only when `skip_basecall = true`. With
  basecalling enabled and `fastq_dir` unset, the run proceeded into
  basecalling and Nextflow silently created a directory literally named
  `null` in the launch directory. Now required unconditionally. Covered
  by WF-17.
- `assign_with_sintax.sh` no longer requires `file(1)`, which it never
  invoked — a spurious hard dependency that would abort on a minimal
  image.
- `BASECALL`'s no-op `saveAs: { filename -> filename }` closure removed;
  the output glob already carries the `fastq_pass/` prefix.

### `Removed`

- `params.version`, which nothing in any `.nf` or `.config` read. CFG-01
  compared it against `manifest.version` — a dead invariant — and now
  compares `manifest.version` against `CITATION.cff` instead, which is
  the duplicate that actually drifts on a release.

### `Added`

- `--cleanup` (default `false`): delete the work directory on successful
  completion. Off by default; see the `Fixed` entry above.
- `optimistic_name()` and `fastq_extensions()` in
  `modules/local/functions.nf`, both unit-tested (FN-03, FN-04), plus a
  drift guard (DSC-07) asserting `fastq_extensions()` and
  `discover_barcodes.py`'s `FASTQ_SUFFIXES` list the same extensions —
  they are what the discovery cache key is built from.
- tests: `tests/config/publish_modes.bats` (the publish-mode matrix and
  its `cleanup` interaction) and `tests/config/resume.bats` (two
  successive runs against a mutating input directory — the shape nf-test
  cannot express, and the gap that let the `-resume` defect through).

## v1.7.0 - 2026-07-24

### `Added`

- `--krona` option (default `false`) rendering interactive
  [Krona](https://github.com/marbl/Krona) HTML charts from the occurrence
  tables — one chart per table (`krona.html` from the filtered table,
  `krona_optimistic.html` from the optimistic one), each holding one dataset
  per barcode (a per-sample dropdown), published beside `results_table`. The
  taxonomy hierarchy is taken straight from the tables' `taxonomy` column
  (comma-separated ranks → Krona levels); an all-zero barcode is skipped and
  reported. Implemented as a stdlib `bin/build_krona.py` (TSV → per-sample
  `ktImportText` text files) driven by `bin/build_krona.sh`, wired through
  `params.krona` and the new `KRONA` module. Covered by KR-01..04, KR-30..35,
  KR-40..42 and WF-13.
- `krona=2.8.1` added to `environment.yml` (and the CI tool set). Krona's
  text mode needs no NCBI taxonomy database, so no large download is
  required; `dorado` remains the only tool the conda profile does not
  provide.

### `Fixed`

- `discard_untrimmed` can now be set on the command line. A CLI
  `--<flag>` override arrives as the string `'true'`/`'false'`, so the old
  strict `params.discard_untrimmed in [true, false]` check aborted every
  CLI form, and the module's truthy test would have mis-read the string
  `'false'` (non-empty → truthy) as `--discard-untrimmed`. Both the startup
  validation and the `SINTAX` module now compare the string form, so a
  config boolean and a CLI `--discard_untrimmed false` behave identically.
  The new `krona` flag uses the same coercion. Covered by WF-14.

## v1.6.0 - 2026-07-24

### `Added`

- `--subsample` option (default `0`) capping each barcode at `n` reads
  **before** trimming. The barcode's fastq files are pooled into a single
  fastq (handling the scattered / mixed-compression case), then subsampled
  with `vsearch --fastx_subsample` seeded by `--randseed`, so only `n` reads
  are trimmed and assigned. `0` disables subsampling and keeps every read;
  the fast per-file path is unchanged when the feature is off. Because the
  cap is applied before primer filtering, the number of *assigned* reads may
  be smaller than `n` when `discard_untrimmed = true`. Exposed on
  `assign_with_sintax.sh` as `--subsample` and wired through
  `params.subsample` + the `SINTAX` module. Covered by SX-15, SX-16, SX-25,
  SX-44 and WF-12.

## v1.5.0 - 2026-06-30

### `Added`

- `--randseed` option (default `0`) wires vsearch's random-generator seed
  through the workflow (`params.randseed`), the `SINTAX` module, and
  `assign_with_sintax.sh`. `0` lets vsearch pick a pseudo-random seed each
  run; a positive integer gives reproducible single-threaded assignments.
  Note that results remain non-deterministic under multithreading even
  with a fixed seed. Covered by SX-14.

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
