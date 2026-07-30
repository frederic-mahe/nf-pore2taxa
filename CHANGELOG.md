# nf-pore2taxa: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### `Added`

- **`-profile demo`**: runs the whole pipeline with **no flags** against a
  committed synthetic dataset in `assets/demo/`, publishing to
  `demo_results/`. The first thing to try after installing, and the fastest
  way to separate "my environment is broken" from "my data is awkward".
  Composes with an environment profile (`-profile demo,conda`) to check that
  too. Needs only the pipeline's core dependencies — `krona` is left off so a
  first run cannot fail for want of KronaTools; `--krona` adds the charts.
  Three barcodes, one of which mixes both taxa, so the demo table has the
  shape a real occurrence table has rather than a diagonal. Covered by
  DEM-01..DEM-04.
- **`stub:` blocks and `tests/check-stub-run.sh`**: the whole pipeline runs
  under `nextflow -stub-run` with `cutadapt`, `vsearch`, `ktImportText` and
  `dorado` all shadowed by stubs that `exit 1`, so a process falling through
  to its real script kills the run. Two layers — a static gate that every
  tool-invoking process declares a `stub:`, and the dynamic run itself —
  plus assertions that no real tool was reached even if the run succeeded,
  and that the declared outputs were really published. Needs only Nextflow
  and python3, so it validates the channel topology (discovery, the
  per-barcode fan-out, the gather, the optional KRONA branch, provenance) in
  seconds with no tools, no GPU and no data. Covered by STB-01..STB-04.

  `DISCOVER_BARCODES`, `BUILD_TABLE` and `DUMP_PARAMS` are exempt from the
  stub requirement: all three are pure standard-library Python, and all
  three are more useful running for real. Stubbing discovery in particular
  would give the fan-out width zero, so the topology would not be tested at
  all.
- `flake8` on every tracked `*.py`, in CI and as step 1/6 of
  `tests/run_all.sh`. Stock settings, no config file — matching
  nf-metabarcoding, whose Python is also clean at the default 79 columns.
  Raising the limit would have been easier; one standard across the two
  repositories the same people maintain is worth more than the wrapped lines
  cost.

### `Changed`

- reflowed the 46 over-long lines flake8 found (all `E501`; no unused
  imports, undefined names or other findings). Comment and docstring rewraps
  plus wrapped call arguments — no behaviour change, and the byte-exact
  occurrence-table tests confirm it.

## v1.12.0 - 2026-07-29

Two things, released together: one output directory per run, and strict
parameter validation.

## Part 1 — strict parameter validation

### `Added`

- **an undeclared parameter is rejected at startup**, with the nearest
  declared name suggested:

  ```
  $ nextflow run main.nf --subsampl 100 ...
  [ERROR] Parameter validation failed:
    - unknown parameter 'subsampl'. Did you mean 'subsample'? Run with
      --help for the full list.
  ```

  Nextflow accepts any `--foo bar` and puts it in `params`, so until now a
  typo left the real parameter at its **default** while the user believed
  they had set it: `--subsampl 100` ran with `subsample = 0` and said
  nothing. That is the same silent-wrong-result class as the v1.7.1 defects
  — and the only one of them the pipeline could not see itself.

  Every undeclared name is listed, not just the first, matching the rest of
  the aggregated report. Suggestions come from a length-scaled edit budget:
  one edit is a plausible slip in a short name, three in a long one, and
  nothing is suggested beyond that, because guessing three edits from
  `krona` would point somewhere wrong. Covered by PRM-01, FN-09.
- `known_params()` in `modules/local/functions.nf`, with a drift guard
  (PRM-02) asserting it matches the config's parameter surface in **both**
  directions. Both failure modes are silent otherwise: a parameter declared
  in the config but missing from the list would be rejected the moment
  anyone used it — the pipeline refusing its own parameter — and a stale
  name left in the list keeps a typo matching it acceptable forever, which
  is the very defect this release closes. Same shape as the DSC-07 and
  BC-12 guards.

Done by hand rather than with **nf-schema** (`D06`, reversing the earlier
recommendation). Once HPC became a real target, a plugin that has to be
pre-seeded in `$NXF_PLUGINS_DIR` on air-gapped compute nodes acquired a cost
it did not have before — while the concrete win, this one check, came to
about twenty lines. The rest of what nf-schema offers is either already
present (validation, with better messages than it generates) or unwanted (a
generated help page, when the hand-written one documents profiles and
composition a schema cannot express). Given up: JSON-schema types/enums and
nf-core tooling compatibility, neither in demand here.

## Part 2 — one output directory per run

### `Added`

- **`--outdir`**: everything a run produces now lands in a single directory —
  both occurrence tables, `per_barcode/<barcode>.sintax` and `.log`, the
  Krona charts, and `pipeline_info/`. One directory to archive, and
  `fastq_dir` is never written to, so it can be read-only and two projects
  may share one.

  Before this, outputs were spread across two trees: the tables went wherever
  `results_table` pointed, while each barcode's results were published *back
  into* `fastq_dir/fastq_pass/<barcode>/`. That meant the raw-data directory
  had to be writable, two projects sharing a `fastq_dir` overwrote each
  other's assignments, a flat read layout acquired invented barcode
  subdirectories, and nothing was "the results of this run".
- **`--table_name`** (default `sintax.tsv`): the filtered table's filename
  inside `outdir`. It must be a filename, not a path — a path would silently
  escape `outdir`, which is the one thing this consolidation exists to
  prevent.
- `effective_outdir()` and `effective_table_name()` in
  `modules/local/functions.nf`, unit-tested (FN-07, FN-08), so the
  deprecation shim lives in one place rather than in every `publishDir`.

### `Deprecated`

- **`results_table`** (removal at **v2.0.0**). It still works and still puts
  your tables exactly where they were: its parent becomes `outdir` and its
  basename `table_name`, with a warning naming the replacement. So an
  existing project config keeps producing what it produced, and gains the
  consolidated `per_barcode/` and `pipeline_info/` alongside. When both it
  and `outdir` are set and they disagree, `outdir` wins and the clash is
  warned about rather than resolved in silence. Same treatment
  `sintax_silva` got.
- **`publish_beside_reads`** (default `false`, removal at **v2.0.0**): also
  publish each barcode's `.sintax`/`.log` back into
  `fastq_dir/fastq_pass/<barcode>/`, as every release before this one did.
  **Additive** — the consolidated copy is still written — so turning it on to
  keep an existing habit costs nothing.

### `Changed`

- `results_table` is no longer *required*: `outdir` defaults to `results`, so
  a bare `nextflow run main.nf` is a valid invocation. WF-11's
  missing-required-parameter case moved to `primer_f`, which still is one.
- the execution reports' paths carry their own copy of the outdir fallback,
  because they are config-level values resolved without `main.nf`. OUT-03b
  pins that the two agree — this is exactly where they would drift.

New specs OUT-01..OUT-06, FN-07, FN-08, PRM-01, PRM-02, FN-09, FN-10.

## v1.11.0 - 2026-07-29

Usable basecalling. The GPU half of the pipeline had **no test coverage at
all** and three settings hardcoded in a shell script; both are now fixed.

### `Added`

- **`--basecall_model`, `--basecall_kit`, `--basecall_device`.** These
  existed as flags on `bin/basecall_pod5_files.sh` but nothing passed them
  and no parameter exposed them, so every run basecalled as
  `sup@v5.2.0` + `EXP-PBC096` + `cuda:0`: **a lab with a different
  sequencing kit could not use basecalling at all**, and a machine without
  an NVIDIA GPU could not use it either. All three are validated at startup
  against the patterns the script enforces, so a typo fails immediately
  rather than inside the first GPU-bound task — and only when basecalling
  will actually run, since holding a `--skip_basecall` run to the format of
  settings it never applies would be gratuitous. Covered by BC-07, BC-09.
- **a full dorado model name is accepted** for `--basecall_model`
  (e.g. `dna_r9.4.1_e8_hac@v3.3.0`). The short form still gets the
  flowcell/chemistry prefix `dna_r10.4.1_e8.2_400bps_`, which was hardcoded
  — so until now *only* that chemistry could be basecalled. Covered by
  BC-04b.
- **the basecalling model is cached.** A new `DOWNLOAD_MODEL` process holds
  it in a `storeDir` at `--basecall_model_dir` (default
  `<launchDir>/dorado_models`), outside the work directory, so Nextflow
  skips the process entirely once it is there. Previously the ~1 GB model
  was fetched into the task directory and then deleted by the script's own
  `clean_up`, so **every run re-downloaded it and every run needed
  network**. The storeDir output is named after the model, so changing
  `--basecall_model` correctly fetches the new one rather than serving a
  cached copy of the old. Covered by BC-10.
- **`tests/stubs/dorado`** — records the argv it was called with and
  fabricates the outputs. The real dorado needs a GPU and a large download,
  so it can never run in CI; the stub is what makes this branch testable at
  all. BC-01..BC-12 now cover the script's CLI, the defaults, the model
  cache, and (BC-08) the whole basecalling branch end to end — publishing
  the sentinel and the `fastq_pass` tree, then flowing on into discovery and
  assignment. That also closes **WF-02** and **WF-05**, and confirms
  PRV-03's dorado version capture on a real run.

### `Fixed`

- **the script could delete and move directories in the caller's current
  directory.** `clean_up` and `compress_fastq` walked `.` rather than
  `--output-dir`: it moved every `fastq_pass` it found there to the top
  level and `rm -rf`'d every other top-level directory. Invisible under
  Nextflow, where the task directory *is* the output directory — and
  destructive for anyone running the script by hand from anywhere else.
  (Found by running it from the repository root during this work, which
  moved a test fixture.) Both are now scoped to `--output-dir`. Covered by
  BC-11.
- `clean_up` aborted the script when `fastq_pass` was already at the top of
  the output directory: `mv ./fastq_pass .` fails, and under `find -exec`
  that made `find` exit non-zero, which `set -e` turned into a failed run.
  That is the pipeline's own layout (`--output-dir "./"`). Covered by
  BC-11b.
- the hermeticity gate in `tests/run_all.sh` compared `tests/fixtures/`
  against git, which cannot tell "the test run wrote this" from "the author
  is editing a fixture and has not committed yet" — and failed on the
  latter. It now compares a content snapshot taken before the run. The CI
  steps keep using git, which is correct there: the checkout is pristine and
  the run happened in an earlier step.

## v1.10.0 - 2026-07-29

Cluster support. Scheduler execution is a supported target, not a
hypothetical one; basecalling is explicitly not part of it.

### `Added`

- **Five institutional cluster profiles** — `abims`, `genotoul`,
  `ifb_core`, `meso`, `saga` — imported from nf-metabarcoding, which serves
  the same users at the same sites and whose `conf/clusters/` files carry
  only site facts (ceilings, queue-routing closures, bind mounts, array
  sizes) with no pipeline-specific content. Each *implies* slurm, so run
  `-profile abims` or `-profile abims,apptainer` and never list `slurm` as
  well. A sixth site starts from `conf/clusters/_template.config`.
- **`slurm` profile** (`conf/slurm.config`) with the submission plumbing:
  `--slurm_queue`, `--slurm_account`, `--slurm_clusterOptions`,
  `--slurm_queue_size`, `--slurm_array_size`, and a resource ceiling set
  **explicitly** rather than auto-detected — under a scheduler the
  auto-detected value describes the *submit* host, and inheriting it would
  silently shrink every submitted job. `cluster` is retained as an exact
  alias, since it shipped in v1.0.0 and project configs use it.
- **Walltime.** `time` directives, scaled by `task.attempt`, in
  `conf/slurm.config` only — the local executor has no walltime enforcer,
  but under a scheduler a job with no `time` inherits the queue default and
  is killed there. The existing `errorStrategy` already retries exit
  137..140, the range a walltime kill lands in, so a job that outgrew its
  slot gets a longer one on retry. This is also where the attempt-scaled
  memory escalation finally earns its keep: a retry can land on a bigger
  node, which a fixed-RAM workstation could never provide.
- **Slurm job arrays** (`--slurm_array_size`, default 50 at every shipped
  site): one `sbatch --array` submission instead of one job per task. This
  pipeline runs one task per barcode, up to 96 a run — exactly the
  submission load arrays exist to reduce.
- **Container profiles** `apptainer`, `singularity`, `docker`, `podman`.
  Each enables its engine plus Seqera Wave, which builds the image from the
  same pinned `environment.yml` that drives `-profile conda` — no
  Dockerfile, no registry, one source of truth for versions. Preferred over
  conda on a cluster, where conda on a shared filesystem is slow and a
  shared cache races between concurrent runs.
- **`--reference_size_gb`**: vsearch loads the reference and builds a k-mer
  index several times its size, so `SINTAX` now scales its memory request
  off the reference rather than a fixed 16 GB — generous for a small
  ITS/COI database and potentially too little for a full SILVA. Unset keeps
  the previous behaviour.
- **`conf/site.config.example`** and `--slurm_account` enforcement: a site
  profile can declare `require_slurm_account`, and the run then stops at
  startup naming both ways to supply one, instead of every `sbatch`
  bouncing. `abims` declares it.
- **CI resolves the cluster and container profiles on a pinned Nextflow
  (25.10.2) as well as the latest stable.** The matrix is the point, not
  decoration: a cluster config shipping a block-form `singularity { }`
  scope silently loses the engine profile's `singularity.enabled` on
  25.10.x but not on 26.x, and the run then falls back to a local conda env
  with no error. Every engine setting in `conf/` therefore uses dotted
  assignment, and CLU-06c pins that `enabled` and the site's bind mounts
  survive `includeConfig` together.

### `Changed`

- **Basecalling is local-only, and now refused rather than merely
  undocumented.** `dorado` is an Oxford Nanopore GPU binary that is not on
  bioconda, so it is in neither `environment.yml` nor any image built from
  it, and the sites' queue closures route by memory and time — `BASECALL`
  would land on a CPU node. A run that requests basecalling under a
  scheduler now aborts at startup with a message that says what to do
  instead, rather than queueing a job that cannot work and failing after
  the wait with the cause far from the reason. Basecall on the GPU
  workstation, then run the cluster half with `--skip_basecall`. Local
  basecalling is unaffected. Covered by CLU-09.
- the per-process `conda` specification moved to `conf/tool_env.config`,
  shared by the `conda` profile and all four engine profiles so the two
  paths cannot disagree about which processes are packaged. `BASECALL` is
  deliberately absent from it: giving it a container or an env without the
  one tool it needs would only hide the problem.
- an engine profile does **not** set `conda.enabled`. That switch turns on
  Nextflow's native conda integration *in addition to* Wave, adding a local
  `conda env create` on the launch node — which on an HPC login node blocks
  on a slow solve and can fail, stalling the run before a single task is
  submitted. Wave needs only the process `conda` directive. CLU-06b pins it.

### `Fixed`

- bare `-profile slurm` inherited the **auto-detected** resource ceiling,
  i.e. the submit host's capacity — the exact failure the v1.8.0 note warns
  about. Caught by CFG-04c when the inline `cluster` profile was replaced
  by `conf/slurm.config`; the file now sets conservative explicit defaults
  that a site profile or `-c site.config` overrides.

New specs CLU-01..CLU-09, all config-resolution only: no scheduler, no
container engine, no image build, so they run in CI with nothing but
Nextflow installed. Real `sbatch` submission and a real image build remain
manual smoke tests at the adopting site — a fake scheduler would only prove
the fake works.

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
