# Review + hardening plan: preparing nf-pore2taxa for external labs

Status: **in progress** — `v1.7.1` **implemented** and committed 2026-07-29;
`v1.8.0` resource clamping implemented (§4), rest of `v1.8.0`
outstanding. `D01`–`D04` and `D08` **resolved**
2026-07-29; `D05` and `D07` **revised** by the `D08` resolution;
`D06`/`D09` proposed and awaiting confirmation (§6). Review of `dev` @
`24a1396` (post-`v1.7.0`), against the goal: *thoroughly tested, easy to
use, hard to misuse, well versioned*, for labs that are not us.

The findings in §2 describe the code **as reviewed** (`24a1396`) and are
kept in the past tense where `v1.7.1` has since fixed them — they are the
evidence trail for the fixes, not a list of live bugs. P0-1..P0-5 are
fixed; P1-6 onwards are not.

**Deployment targets (confirmed, 2026-07-29):**

1. **Now:** a **single workstation**, local executor — the external lab's
   environment, and the target every fix in `v1.7.1`/`v1.8.0` must be
   correct for.
2. **Soon:** **HPC / slurm.** The `cluster` profile stays **supported**;
   scheduler execution is a real target, not a hypothetical one.

That ordering is a priority, not a scope reduction, and it is the single
most important thing to hold in mind while reading §4 — because a fix
that is right for one target can be wrong for the other. Two in this plan
are: **profile-aware resource clamping** (auto-detecting the machine's
cores is correct locally and actively harmful on a submit host, `v1.8.0`)
and the **`publish_mode` allowed set** (`D05`, revised — the link modes
matter most on a cluster, where work and results usually live on
different filesystems). Anything justified by "it's just one workstation"
is flagged below as such.

Everything under "Findings" was checked against the running code on this
machine (Nextflow 26.04.4, vsearch 2.31.0, cutadapt, KronaTools, bats
1.10, nf-test 0.9.5). Items marked **[reproduced]** were demonstrated;
items marked **[inferred]** are read from the code and not executed.

Baseline: the suite is **green** — 71 bats tests, 27 nf-test tests, the
python unittest suite, and shellcheck all pass.

---

## 0. Verdict

The *inner* layer is in good shape: the two Python scripts and the two
driver shell scripts are small, pure, documented, and genuinely well
tested; `SPECIFICATIONS.md` is better than most published pipelines
have; the per-barcode fan-out is the right topology.

The risk is concentrated in the **outer** layer — the config surface,
the parameter contract, the publish/cleanup interaction, and provenance.
That is exactly the layer a second lab meets first and that the current
suite does not touch: every nf-test overrides `cpus`/`memory`, no test
resolves a profile, no test runs a second time with `-resume`, and no
test asserts anything about `cleanup`, `publish_mode`, or the BASECALL
half of the pipeline.

Five defects can produce a **wrong or missing result while the run
reports `SUCCESS`**. Those are the whole content of the proposed
`v1.7.1`; everything else can follow at leisure.

---

## 1. What is already right (keep, don't churn)

- `SPECIFICATIONS.md` with stable IDs, and the ground-rule that we test
  *our* orchestration and never vsearch/cutadapt internals.
- `bin/*.py` are stdlib-only, side-effect-free at import, and unit-tested
  through their pure helpers rather than only through the CLI.
- Exact `=` pins in `environment.yml`, matched by hand to the CI pins,
  with the "bump both at once" rule written down.
- The v1.7.0 `coerce_bool`/`valid_bool` centralisation: the right fix for
  the CLI-boolean trap, in the right place, with FN-01/FN-02 pinning it.
- Aggregated startup validation that reports every bad parameter at once
  instead of dying on the first.
- The `.sintax`-is-empty-not-absent invariant (SX-33) and the
  empty-barcode column bookkeeping (BT-13/BT-25). These are the subtle
  parts of the table builder and they are pinned properly.
- CI already splits into four independent jobs and installs real tools.

---

## 2. Findings

### P0 — a run can report SUCCESS and be wrong or empty

#### P0-1 `publish_mode = symlink|rellink` + `cleanup = true` destroys every output **[reproduced]**

`nextflow.config` sets `cleanup = true` at top level. `publish_mode`
validation accepts `symlink` and `rellink`. Together, the work dir is
deleted on success *after* publishing links into it:

```
$ ls -l results/
table.tsv            -> .../work/75/8124f8.../table.tsv     (dangling)
table_optimistic.tsv -> .../work/75/8124f8.../table_optimistic.tsv (dangling)
[SUCCESS] completed=5 failed=0 cached=0
```

Both occurrence tables, every per-barcode `.sintax`, and both Krona
HTMLs are unreadable. The run exits 0.

`move` is a second, different hazard **[inferred]**: `BASECALL`'s
downstream handoff is `BASECALL.out.done.map { file("${it.parent}/fastq_pass") }`
— a path *inside the task work dir*. `mode: 'move'` relocates those
files out of the work dir, so discovery would then walk an empty or
absent tree.

Fix: default `cleanup = false` (the sibling pipeline's `[S82]`, for the
same reason — a successful run should stay resumable and inspectable),
**and** reject the incompatible combinations at startup rather than
relying on the default staying put. `symlink`/`rellink` are only ever
safe with `cleanup = false`; `move` is never safe for `BASECALL`.

#### P0-2 `-resume` silently ignores new reads added to an existing barcode **[reproduced]**

`DISCOVER_BARCODES` receives `fastq_pass` as `val` (deliberately
unstaged), so its cache key does not reflect the directory's recursive
contents. Add a second fastq to an existing `barcode02/` and resume:

```
$ nextflow run main.nf -c p.config -resume
[SUCCESS] completed=0 failed=0 cached=6
$ barcode02 total = 5      # unchanged; the new reads were never seen
```

A new barcode *directory* happens to invalidate the cache (the parent's
mtime changes) — which makes the failure mode worse, because the
mechanism looks like it works. Topping up an existing sample — a
re-sequenced library, a second flow cell for the same barcode, the exact
thing `-resume` is for — silently yields the old table.

Fix: make the channel content-derived instead of caching a directory
scan. Cheapest correct form: enumerate in the workflow
(`Channel.fromPath("${dir}/**.fastq{,.gz,.bz2,.xz}")`), pass the sorted
list into `DISCOVER_BARCODES` as a `val` so the cache key contains it,
and keep `discover_barcodes.py` as the single barcode-naming
implementation. (Staging the whole tree as `path` would be
content-hashed but costs a stage-in of every fastq.)

#### P0-3 a `results_table` not ending in `.tsv` fails at the last step **[reproduced]**

`BUILD_TABLE` declares `output: path "*.tsv"` but writes
`file(params.results_table).name`. With `results_table = ".../table.txt"`:

```
Command exit status: 0
[ERROR] BUILD_TABLE (build_table)      # Missing output file(s) `*.tsv`
[FAILED] completed=5 failed=1
```

The script succeeded; Nextflow could not match the glob. Nothing is
published. On a real run this arrives after every SINTAX task has
finished — the most expensive possible moment to learn about a typo in a
filename.

Fix: declare the two real output names
(`path "${file(params.results_table).name}"` plus the `_optimistic`
sibling) so the contract is exact, and validate the suffix at startup.

#### P0-4 `--skip_basecall false` skips basecalling **[reproduced]**

```
skip_basecall raw=[false] class=class java.lang.String
  Groovy truthiness: SKIP basecalling
```

A CLI override arrives as the *string* `'false'`, which is truthy.
`main.nf` tests `if (params.skip_basecall)` directly — it is the one
boolean the v1.7.0 fix did not reach, and it is the one with the largest
consequence: the pipeline quietly runs against whatever is (or isn't) in
`fastq_dir` instead of basecalling. `--skip_basecall yes` is likewise
accepted.

Fix: `valid_bool(params.skip_basecall)` in validation +
`coerce_bool(params.skip_basecall)` at the branch. Then add a
`valid_bool` check for *every* declared boolean, so the next one added
cannot repeat this.

#### P0-5 `fastq_dir` is required in both modes but validated in only one **[reproduced]**

`BASECALL` publishes to `params.fastq_dir`; `SINTAX` publishes to
`${params.fastq_dir}/fastq_pass/${barcode}`. Validation only requires
`fastq_dir` when `skip_basecall = true`. With `skip_basecall = false`
and no `fastq_dir`, the run proceeds straight into basecalling:

```
[PROCESS 33/e33de6] BASECALL (basecall)
```

and Nextflow resolves `publishDir "null/…"` by silently creating a
directory literally named `null` in the launch dir (verified
separately). Hours of GPU basecalling land in `./null/fastq_pass/`, and
so do the results.

Fix: require `fastq_dir` unconditionally.

### P1 — misuse hazards and first-run failures

#### P1-6 shipped resource defaults exceed a normal workstation **[reproduced]**

`SINTAX` requests `cpus = 20`, `memory = 16.GB`; `BASECALL` asks
`32.GB`. The local executor refuses outright:

```
Process requirement exceeds available CPUs -- req: 40; avail: 24
```

(demonstrated with 40 vs this machine's 24; the shipped 20 fails
identically on any 8- or 16-core machine). The immediate target runs in
**local** mode, so this is the single most likely way a new lab's first
run dies — before any biology, with an error that reads like their
machine is at fault.

Fix: `max_cpus` / `max_memory` params + a `check_max`-style helper in
`modules/local/functions.nf` clamping every `withName` block
(unit-testable exactly like `coerce_bool`). **The default must be
profile-aware, not simply auto-detected** — detecting the box is right
locally and wrong under a scheduler, where `availableProcessors()`
describes the submit host rather than the compute node and would silently
shrink every submitted job. See `v1.8.0` for the two branches.

#### P1-7 `randseed` promises reproducibility it cannot deliver **[inferred]**

`--randseed 42` with `SINTAX cpus = 20` is not reproducible — vsearch
sintax is order-dependent under threading. This is stated in three
comments and the README, and nowhere at run time. A user who sets a seed
reasonably concludes their run is replicable.

Fix (per `D04`): warn at startup when `randseed > 0` and the resolved
`SINTAX` cpus > 1, naming the trade-off — and treat the real fix as the
**vsearch 2.32.0** pin bump, which is expected to make sintax
reproducible under multithreading and so removes the trade-off rather
than managing it. No `--reproducible` flag: it would be deprecated within
a release.

#### P1-8 barcode names can be taken from a parent directory **[reproduced]**

`build_occurrence_table.py::extract_barcode` searches the *whole* path
string:

```
/data/barcode01_rerun/fastq_pass/unclassified/unclassified.sintax -> 'barcode01'
/proj/run_barcode07/results/barcode12.sintax                      -> 'barcode07'
```

In-pipeline the staged dir is `.`, so today this is latent. But BT-16
claims "directory clutter does not pollute names", and the obvious
hand-run (`--input-dir /data/run/fastq_pass`, on the tree the pipeline
itself publishes into) silently mislabels samples. `discover_barcodes.py`
already does this correctly, relative to the input dir — the two scripts
that are documented as being "in lock-step" disagree.

Fix: match on the path relative to `input_dir`, and give the two scripts
one shared implementation (or a test asserting they agree on a corpus of
paths).

#### P1-9 results are published back into the input data tree **[inferred]**

`SINTAX` publishes `<barcode>.sintax`/`.log` into
`${fastq_dir}/fastq_pass/<barcode>/`, and `BASECALL` publishes
`done_basecalling.txt` into `fastq_dir`. Consequences: the raw-data
directory must be writable; inputs and derived results interleave (a
re-run's discovery walks a tree containing the previous run's outputs —
harmless only because the glob is `*.fastq*`); two projects sharing a
`fastq_dir` overwrite each other's assignments; a flat layout gets new
`barcode*/` subdirectories invented inside it; and there is no single
directory a lab can archive as "the results of this run".

Fix: an `--outdir` holding everything (tables, per-barcode `.sintax`,
logs, reports, versions), with publish-back retained as an explicit
opt-in for current users.

#### P1-10 `results_table` named `*_optimistic.tsv` collapses both Krona charts **[reproduced]**

`html_name_for` keys off the substring `_optimistic`:

```
mytable_optimistic.tsv            -> krona_optimistic.html
mytable_optimistic_optimistic.tsv -> krona_optimistic.html
```

One overwrites the other; the process emits one HTML where two are
expected. Fix: derive the HTML name from the TSV stem, or reject
`_optimistic` in `results_table` at startup.

#### P1-11 smaller items

- `assign_with_sintax.sh::check_commands` requires `file(1)` but the
  script never invokes it **[reproduced]** — a spurious hard dependency
  that would abort on a minimal image.
- `subsample_or_passthrough` counts reads as `wc -l / 4`. A miscount
  upward makes `vsearch --fastx_subsample` fatal. Counting `^@` records
  via the same vsearch pass, or letting vsearch decide and tolerating
  its error, is sturdier.
- `errorStrategy 'terminate'` aborts a 96-barcode run for one bad
  barcode. Defensible (a silently-dropped sample is worse), but it
  should be a documented decision, not an accident.
- `BASECALL`'s `saveAs: { filename -> filename }` is a no-op.
- `${fastqs}` / `${tsv_files}` are interpolated unquoted into the
  scripts; a filename with a space breaks the command.

### P2 — replicability and provenance

#### P2-12 nothing records what produced a result

There is no `versions.yml`, no captured vsearch/cutadapt/dorado/Krona
version, no pipeline commit in the output, no `-with-report`/`-with-trace`
wiring in the config. Two labs comparing tables cannot tell whether they
ran the same software. The sibling pipeline solves this with
`dump_software_versions` + `collect_versions.py`; this is the largest
single gap for cross-lab reproducibility and the cheapest to close.

#### P2-13 no `manifest.nextflowVersion`, no `defaultBranch`

Nothing stops a lab running this on an incompatible Nextflow. The
sibling pins `>=25.04.0`.

#### P2-14 conda-only, and only the top four packages are pinned

Exact `=` pins on vsearch/cutadapt/krona/python are good, but the
transitive closure is unpinned, so each lab resolves a slightly
different environment. No container profile exists. A
`docker`/`singularity`/`apptainer` profile (or a committed conda lock)
would make "same pipeline" mean "same bytes".

#### P2-15 release hygiene

- `origin/main` is one commit past the `v1.7.0` tag (`24a1396`, a
  behaviour-touching refactor) while still declaring
  `manifest.version = '1.7.0'` **[reproduced]**. "1.7.0" now names two
  different trees. `nextflow run frederic-mahe/nf-pore2taxa` without
  `-r` pulls the untagged one.
- `origin/main` and `origin/dev` are identical, so the two-branch scheme
  currently buys no staging.
- No `Unreleased` section in `CHANGELOG.md`, so post-tag work has
  nowhere to land.
- `params.version = '1.7.0'` is **dead** — nothing in any `.nf` or
  `.config` reads it **[reproduced]**. `CFG-01` therefore tests a dead
  invariant, while the live duplicate (`CITATION.cff: version: 1.7.0`)
  is unchecked.
- The README never tells a lab to pin a revision.

### P3 — test-suite gaps

#### P3-16 `BASECALL` has zero tests, and is the least parameterised code

BC-01..BC-08 are all open. Meanwhile that code is where the
hardest-to-fix usability problems sit **[inferred]**:

- `MODEL` (`sup@v5.2.0`) and `KIT_NAME` (`EXP-PBC096`) exist as script
  flags but `modules/basecall.nf` never passes them and no `params`
  expose them. **A lab with a different kit cannot use basecalling at
  all** without editing the script.
- `--device cuda:0` is hardcoded — no CPU, no `cuda:all`, no
  multi-GPU node.
- `clean_up()` `rm -rf`s everything but `fastq_pass`, including the
  `models/` directory `download_model()` just fetched, so **the model is
  re-downloaded on every run** and the step needs network every time.
- `clean_up()`'s `find … -name fastq_pass -exec mv '{}' . \;` runs with
  `OUTPUT_DIR = "."`, i.e. it may try to move `./fastq_pass` onto
  itself.

A `dorado` stub that records its argv (SPECIFICATIONS.md §2 already
proposes this) turns all of it into cheap CI.

#### P3-17 no `-stub` blocks, so there is no fast tool-free smoke test

Nothing lets a new lab (or CI) validate the channel topology in seconds
without vsearch/cutadapt/dorado. The sibling's `check-stub-run.sh`
pattern — a static gate that every process declares `stub:`, plus a
`-stub-run` with the real tools shadowed by `exit 1` stubs — is directly
portable.

#### P3-18 the config surface is entirely untested

The sibling has ten `tests/check-*.sh` resolving profiles with
`nextflow config -flat`. Here nothing asserts the `conda` profile
resolves (`nf-test.config` sets `profile ""`, so it is never exercised),
nothing asserts the `cluster` profile, nothing asserts the `cleanup`
default, nothing asserts the resource defaults are runnable, and nothing
covers the `publish_mode` matrix. **P0-1 and P1-6 both live in exactly
this blind spot** — and both are one `nextflow config` assertion away
from being caught.

#### P3-19 spec ↔ test drift is unpoliced

- `BT-24` is asserted by two test files but is **not declared** in
  `SPECIFICATIONS.md` **[reproduced]**.
- `OBS-02` still documents `trim_extension`/`SX-21`, both removed in
  v1.4.0.
- `tests/README.md` claims `BT-21..BT-24` where the spec has `BT-25`.

The sibling's `coverage-gate.sh` + `COVERAGE.md` catch precisely this
class, and it is ~80 lines to port.

#### P3-20 other coverage holes

| Gap | Note |
| --- | --- |
| SX-01..04, SX-06..10 | CLI validation paths, listed as known gaps |
| SX-35 | `-resume` idempotence — the spec that would have caught **P0-2** |
| WF-01, WF-02, WF-05, WF-07 | the whole basecalling branch of the workflow |
| OBS-05 | `results_table` as a bare filename / non-`.tsv` — i.e. **P0-3** |
| publish_mode matrix | no test runs with anything but the default |
| production resources | every nf-test overrides `cpus`/`memory`, so **P1-6** is invisible |
| fixture drift | `generate.sh` outputs are committed but never re-checked |
| python lint | sibling runs `flake8`; nothing here does |

---

## 3. What to port from nf-metabarcoding

| Mechanism | There | Here | Priority |
| --- | --- | --- | --- |
| `cleanup = false` default, with rationale | `[S82]` | `cleanup = true` | **P0** |
| `manifest.nextflowVersion` | `>=25.04.0` | absent | P2 |
| `nextflow_schema.json` + nf-schema | present | hand-written help + Groovy guards | P2 |
| schema ↔ config drift test | `test_schema_params_sync.py` | n/a | P2 |
| manifest ↔ CITATION version test | `test_version_sync.py` | `CFG-01` tests a dead param | P2 |
| exact-pin + CI-pin agreement test | `test_reproducible_pins.py` | pins correct, unchecked | P2 |
| `coverage-gate.sh` + `COVERAGE.md` | present | absent (drift already present) | P1 |
| `check-*.sh` config resolution (×10) | present | absent | **P1** |
| `stub:` in every process + `check-stub-run.sh` | present | absent | P1 |
| software-version capture | `dump_software_versions` | absent | P2 |
| container profiles + offline image path | present | conda only | **P1** (HPC) |
| CI on pinned **and** latest Nextflow | matrix | latest only | **P1** (HPC) |
| `check-cluster-profiles.sh` / `check-slurm-config.sh` | present | absent | **P1** (HPC) |
| `conf/site.config.example` + `-c` override | present | absent | **P1** (HPC) |
| slurm account requirement error + test | present | absent | **P1** (HPC) |
| institutional cluster configs | 5 sites, **tool-agnostic** | none | **P1** — import verbatim |
| slurm job arrays (`process.array`) | present | absent | **P1** — 96-barcode fan-out |
| reference-size-scaled memory for vsearch sintax | present | flat `16.GB` | **P1** — same tool, same shape |
| `DECISIONS.md` for open questions | present | decisions live in plan docs | P3 |
| `--tag ci` on tests | present | all tests always run | P3 |
| demo profile, zero-flag run | `-profile demo` | fixtures only | P2 |

The rows marked **(HPC)** were P2/P3 in the first draft of this table,
when the plan assumed a single workstation was the only target. They are
the mechanical part of `v1.10.0`. Because the two pipelines serve the
**same users at the same sites**, the five institutional configs and the
`_template` import *verbatim* — they carry no process names and no
tool references — so this is copying, not designing. The only part that
cannot be imported is the GPU routing for `BASECALL`, which the sibling
never needed; see `v1.10.0`.

Two things are *better* here and should not be traded away: exact `=`
pins on every conda dependency (the sibling needed a test to enforce
what this repo does by habit), and a `SPECIFICATIONS.md` whose ground
rules are stated before the tables.

---

## 4. Plan

Test-first throughout, per house style: add the spec ID and a failing
test, then implement to green.

One feature per minor release, per the repo's established cadence
(1.3.0 → 1.7.0), so history stays bisectable.

### v1.7.1 — the five silent-failure defects (no new features) — **IMPLEMENTED 2026-07-29**

All five landed, each verified against a reproduction of the original
failure before and after. Suite: **38** nf-test (was 27), **85** bats
(was 71), **43** python (was 34), shellcheck clean.

Two deviations from the plan as written, both deliberate:

- **#3 needed no suffix validation.** The plan proposed declaring the
  exact output names *and* rejecting a non-`.tsv` `results_table` at
  startup. Declaring the names (via a new `optimistic_name()` helper,
  FN-03) makes **any** extension work correctly, so the restriction would
  have been gratuitous — `results/table.txt` now publishes `table.txt` +
  `table_optimistic.txt` and both Krona charts. `WF-15` asserts the
  working behaviour rather than the abort the plan predicted.
- **`SX-35`/`DSC-06` are bats, not nf-test.** They need two successive
  `nextflow run` invocations against an input directory that changes in
  between; nf-test gives each test a fresh `outputDir` and has no resume
  hook. `tests/config/resume.bats` drives Nextflow directly. Worth noting
  *why* the defect survived a green suite: there was no way to express
  "run it twice".

Also fixed in passing, being documentation-only and in files already
being edited: the three spec-drift items from P3-19 (`BT-24` now
declared, `OBS-02` marked resolved, `tests/README.md`'s coverage table
corrected). The `coverage-gate.sh` that would *prevent* recurrence is
still outstanding — see "Continuous".

| # | Change | New spec | Test |
| --- | --- | --- | --- |
| 1 | `cleanup = false` by default + a `--cleanup` opt-in (`D02`); reject `cleanup && publish_mode in [symlink, rellink]`; drop `move` from the accepted set, keep the link modes (`D05` revised) | `CFG-02`, `CFG-03` | `tests/check-publish-modes.sh` (config resolution) + a workflow test per mode asserting the published tables are real, readable files — including `symlink` under both `cleanup` settings |
| 2 | Content-derived barcode discovery (enumerate in the workflow, pass the sorted list as `val`) | `SX-35`, `DSC-06` | two-run nf-test: run, add a fastq to an *existing* barcode, `-resume`, assert that barcode's column total grew |
| 3 | Declare `BUILD_TABLE`'s two exact output names; validate the `results_table` suffix at startup | `WF-15`, `BT-08` | a workflow test with `results_table = *.txt` asserting a *startup* abort |
| 4 | `valid_bool`/`coerce_bool` for `skip_basecall` — and for every declared boolean, including the new `cleanup` | `WF-16` | `--skip_basecall false` runs `BASECALL` (dorado stub); `--skip_basecall yes` aborts at startup |
| 5 | Require `fastq_dir` unconditionally | `WF-17` | startup abort with `skip_basecall = false` and no `fastq_dir` |

> **Note on #1 + #4.** `D02` adds `params.cleanup`, i.e. a *new boolean*
> — exactly the shape that produced P0-4. It must go through
> `valid_bool`/`coerce_bool` in the same commit, and `FN-01`/`FN-02` must
> be extended to cover it. A `--cleanup false` that reads as truthy would
> delete the work dir the flag was added to preserve.

Also in the patch, since they are one-liners: drop the unused `file(1)`
requirement; drop the no-op `saveAs`; delete the dead `params.version`
and repoint `CFG-01` at `manifest.version` ↔ `CITATION.cff`.

### v1.8.0 — runnable out of the box (resource clamping)

**Resource clamping: IMPLEMENTED 2026-07-29.** Remaining `v1.8.0` items
(`nextflowVersion`, the full startup summary) outstanding — see below.

- ~~`max_cpus`/`max_memory` params + a `check_max` helper~~ →
  **`process.resourceLimits`**, done. The plan called for a hand-rolled
  `check_max` in `modules/local/functions.nf`; native `resourceLimits`
  (Nextflow ≥ 24.04, and what nf-metabarcoding's slurm profile already
  uses) is strictly better and was used instead. It clamps every request
  *and* every retry's `* task.attempt` escalation, at directive-resolution
  time, with no helper to maintain and nothing to remember to wrap a new
  process in.

  Two things were verified before committing to the design, because the
  whole fix rests on them:

  - `resourceLimits` genuinely prevents the local executor's refusal — a
    40-cpu request on a 24-core host ran, clamped, instead of aborting;
  - `nextflow.util.SysHelper.getAvailCpus()` / `getAvailMemory()` resolve
    inside a config file and return exactly what the executor compares a
    request against (24 / 125.3 GB on the dev box).

  Using `SysHelper` for the defaults — rather than nf-core's fixed
  `max_cpus = 16` — is what makes the failure *impossible* rather than
  merely unlikely: the ceiling and the executor's check read the same
  number, so `req <= avail` holds by construction. (It is a
  Nextflow-internal class; the risk is noted in `nextflow.config` and both
  params are overridable, which is the mitigation.)

  **Profile-aware, as the plan required.** Top-level params auto-detect
  (correct for local); the `cluster` profile sets both explicitly and
  never consults the helper, because on a submit host the detected value
  describes the wrong machine and would silently shrink every submitted
  job. `CFG-04c` asserts the cluster profile's ceiling differs from the
  running host's.

  Covered by `CFG-04a`–`CFG-04g` + `FN-05`, in
  `tests/config/resources.bats`. `CFG-04g` is the one that matters: it
  runs the **production** resource config (no `tests/nextflow.config`, so
  `SINTAX` asks for its real 20 cpus / 16 GB) under a 2-cpu / 3 GB
  ceiling and asserts `--threads 2` reached vsearch. That also closes the
  "production resource defaults are never exercised" gap from P3-20 —
  every nf-test overrides `cpus`/`memory`, so this is the only place the
  shipped numbers are tested.

  One thing the plan did not anticipate: **clamping is silent**. A user
  whose `SINTAX` asked for 20 threads and got 8 has no way to know why, or
  that raising the request would not help. A startup notice now reports
  the effective ceiling.

- **`manifest.nextflowVersion` + `defaultBranch` (P2-13): done.** The
  floor is `>=24.04.0` — the release that added `resourceLimits`, which
  the ceiling above depends on. This is not cosmetic: an older Nextflow
  ignores an unknown directive *silently*, so the clamping would stop
  working with no diagnostic and the "exceeds available" failure would
  return. `CFG-05b` guards the floor arithmetically so it cannot be
  lowered by mistake. Honest caveat recorded in the config: CI runs one
  Nextflow version, so the floor is the documented requirement of the
  feature, not a version the suite has been run against — the pinned +
  latest matrix in `v1.10.0` is what would make it trustworthy.

- **Startup summary + `randseed` warning (`D04`): done.** Nextflow's own
  header covers version/profile/workDir, so the block covers what it never
  shows — the effective *parameters*, with the ambiguous ones spelled out
  (`discard_untrimmed = true (strict amplicon filtering)`) and the
  resolved ceiling including the thread count `SINTAX` will really get.
  Until `versions.yml` lands (`v1.9.0`) this is the pipeline's only
  provenance record.

  The `randseed` warning keys off the **effective** thread count, not the
  configured one, via `effective_threads()` (FN-06) reading
  `process.withName:SINTAX.cpus` out of the resolved config. That matters:
  `--max_cpus 1` genuinely does make a seeded run replayable, and a
  warning that fires when it does not apply just teaches people to ignore
  warnings. `CFG-06g` pins the negative case.

`v1.8.0` is complete. Two incidental fixes came with it: the `file()`
glob deprecation introduced by `v1.7.1`'s enumeration (Nextflow 26 asks
for `files()`), and three `resources.bats` assertions that had been
written against the interim ceiling message before the summary block
absorbed it.

### v1.9.0 — provenance

- Software-version capture → `versions.yml` published with the results
  (P2-12): vsearch, cutadapt, KronaTools, python, dorado when it ran,
  plus the pipeline version and git commit.
- Execution reports (`report`/`timeline`/`trace`/`dag`) written under the
  results directory by default.

Together these make a lab's output self-describing, which is the
precondition for two labs comparing tables at all.

### v1.10.0 — HPC readiness (`D08`), imported from nf-metabarcoding

The two pipelines serve the **same users at the same sites**, so this is
an **import**, not a design exercise. I checked what is actually in the
sibling's `conf/` — the split is much more favourable than expected.

#### Imports verbatim (no pipeline-specific content whatsoever)

`conf/clusters/{abims,genotoul,ifb_core,meso,saga}.config` and
`conf/clusters/_template.config`. Every one of these contains **only**
site facts: `max_cpus`/`max_memory`/`max_time`, `resourceLimits`, a
`queue` closure routing on `task.memory`/`task.time`, `array`, container
bind mounts, and (meso) an account-derivation closure. **No process
names, no swarm/mumu/vsearch references** — nothing to rewrite. Copy the
files, register five profiles, done:

| Site | ceiling | queue routing |
| --- | --- | --- |
| abims | 512 cpu / 2000 GB / 720 h | `bigmem` \| `fast` \| `long`; requires an account |
| genotoul | 128 cpu / 4000 GB / 96 h | `workq` \| `unlimitq`; `module load` for the engine |
| ifb_core | 256 cpu / 2000 GB / 720 h | `fast` \| `long` |
| meso | 186 cpu / 3800 GB / 168 h | `cpu-dedicated` \| `bigmem-…`; account derived from size/time |
| saga | 64 cpu / 6000 GB / 7 d | `normal` \| `bigmem` \| `hugemem`; `scratch = $SCRATCH` |

Two pieces of hard-won knowledge come with them and must not be
"cleaned up":

- The `_template.config` warning that engine settings use **dotted
  assignment** (`singularity.runOptions = …`), never a
  `singularity { }` block: reached through `includeConfig` on Nextflow
  25.10.x, a block-form scope silently drops the engine profile's
  `enabled = true` and the run falls back to local conda. This is the
  exact bug the CI version matrix exists to catch.
- `slurm_array_size` / `process.array`. pore2taxa's per-barcode fan-out
  over up to 96 barcodes is precisely the workload job arrays are for —
  one `sbatch --array` instead of 96 submissions. A free, large win that
  needs no new code.

#### Imports with the tiers rewritten

`conf/slurm.config`. The executor plumbing ports as-is: `slurm_queue`,
`slurm_account`, `slurm_clusterOptions`, `slurm_queue_size`,
`slurm_array_size`, the `clusterOptions` closure that emits nothing when
neither account nor extra options are set, `resourceLimits`, and the
`executor { queueSize / submitRateLimit / pollInterval }` block. What
cannot port is the `withName:` tiers — they name that pipeline's
processes. pore2taxa has five, so the tiers are short:

| Process | shape | tier |
| --- | --- | --- |
| `BASECALL` | GPU, hours | see the gap below |
| `DISCOVER_BARCODES` | stdlib python, seconds | 1 cpu, small, minutes |
| `SINTAX` | multi-threaded vsearch, **reference-bound** memory | `params.threads`, memory off `reference_size_gb` |
| `BUILD_TABLE` | single-threaded python, whole-study table | 1 cpu, memory off `dataset_size_gb` |
| `KRONA` | ktImportText, small | 1 cpu, small |

One tier is worth stealing outright: the sibling scales
`assign_taxonomy_sintax` off `params.reference_size_gb * 4` because
vsearch loads the reference and builds a k-mer index several times its
size. **pore2taxa's `SINTAX` does exactly the same thing** with exactly
the same tool. Its current flat `memory = 16.GB` is a guess that is
simultaneously too much for a small ITS reference and too little for a
full SILVA — replace it with the same scaling, which also fixes the
workstation case (P1-6).

`conf/site.config.example` ports with the tool list swapped
(`module_vsearch`/`cutadapt` stay, `swarm`/`mumu` go,
`krona`/`dorado` arrive) and the shared-cache / air-gapped-image sections
kept intact.

#### The one genuine gap: GPU, which the sibling cannot supply

Both `meso.config` and `saga.config` say in as many words that they
*ignore* their GPU partitions because "this pipeline has no GPU steps".
pore2taxa has one. So the imported `queue` closures — which route purely
on memory and time — would cheerfully send `BASECALL` to a CPU partition
with no GPU on it. Each imported site profile needs a `BASECALL`
override, and those values are irreducibly site-specific:

- a GPU partition (`accel`/`a100` on saga, `gpu-cirad-dedicated` on meso
  — both already named in the sibling's comments, which is a head start);
- a GPU request (`clusterOptions '--gres=gpu:1'`, syntax varies by site);
- possibly a different account for the GPU queue;
- **how `dorado` is reached at all.** It is not in the container and not
  on bioconda, so on a cluster it needs a module load or an absolute
  path — a new param, and the one piece of this milestone that touches
  `v1.11.0` (basecalling parameterisation). Sequence `v1.11.0` first if
  the GPU path is wanted early, or ship `v1.10.0` with `BASECALL`
  documented as local-only.

This is also an argument for `skip_basecall` on clusters generally:
basecall once on the GPU workstation, then run the cheap CPU half at
scale on the cluster. Worth stating in the README as the recommended
hybrid, since it sidesteps the whole problem.

#### Tests

Port `check-cluster-profiles.sh` and `check-slurm-config.sh` — config
resolution only, no submission, so they run in CI with nothing
installed — plus the pinned-and-latest Nextflow matrix that protects the
dotted-assignment trap above. Add one assertion the sibling has no need
for: that every imported site profile routes `BASECALL` to a GPU queue,
or explicitly declares it unsupported. Real submission stays a manual
smoke test at whichever site adopts it first; that cannot be CI'd and
should not pretend to be.

#### Still ours to write

- **Walltime.** Re-enable `time` with `task.attempt` scaling. Without it
  every job inherits the queue default and is killed there. The existing
  `errorStrategy` already retries `137..140`, which covers a walltime
  kill, so only the directive is missing.
- **Account guard.** `abims.config` carries `require_slurm_account = true`
  and the sibling fails loudly at startup when it is unset. Port that
  (`slurm_account_requirement_error` + its unit test) rather than letting
  `sbatch` reject the job.
- **Attempt-scaled memory finally pays off.** `16.GB * task.attempt`
  cannot help on a workstation with fixed RAM, but under a scheduler a
  retry can land on a bigger node. The existing design was already
  forward-looking; `resourceLimits` is what keeps it from looping to
  failure against a ceiling that does not exist.

### v1.11.0 — usable basecalling (`D01`)

Expose `basecall_model`, `basecall_kit`, `basecall_device` as params
threaded through to the script (P3-16), validated at startup with the
patterns `basecall_pod5_files.sh` already enforces; keep the model out of
`clean_up`'s blast radius and cache it via `storeDir` so it is fetched
once instead of every run; add `BC-01`..`BC-08` against a `dorado` stub
that records its argv. Until this ships, the README must say plainly that
basecalling is hardcoded to `sup@v5.2.0` + `EXP-PBC096` + `cuda:0`.

`D01` was resolved as *parameterise without waiting for an answer*, so
this milestone is committed regardless of whether the lab turns out to
basecall. If they confirm early that they do, promote it ahead of
`v1.8.0`/`v1.9.0` — "cannot run with our kit" outranks everything except
the P0 defects.

### v1.12.0 — one place for outputs (`D03`)

`--outdir` containing the tables, per-barcode `.sintax`/`.log`, Krona
HTMLs, execution reports and `versions.yml` (P1-9), so `fastq_dir`
becomes read-only and a run has exactly one directory to archive. Keep
publish-back behind an explicit flag and deprecate it the way
`sintax_silva` was — warn, honour, name the removal release (`v2.0.0`).

Sequenced after provenance deliberately: `versions.yml` and the reports
should be born into the new layout rather than moved into it one release
later.

### v1.13.0 — a machine-readable parameter contract (`D06`)

`nextflow_schema.json` + nf-schema, additively (keep the Groovy guards
until the schema demonstrably covers them, as the sibling did). The win
that matters for external labs: `--subsampl 100` is currently accepted
in silence, and strict validation rejects it. Port
`test_schema_params_sync.py` so the schema cannot drift from the config.

### Upstream-blocked

- **vsearch 2.32.0 makes sintax reproducible under multithreading**
  (`D04`). When it is released: bump the `environment.yml` and CI pins
  together, raise `MIN_VSEARCH_VERSION` in `assign_with_sintax.sh` to
  `2.32.0`, delete the `randseed` warning added in `v1.8.0`, and replace
  the three "not replicable under multithreading" comments
  (`nextflow.config`, `assign_with_sintax.sh`,
  `SPECIFICATIONS.md OBS-03`) with the new guarantee. `OBS-03` currently
  licenses every SINTAX test to be structural rather than exact — once
  the seed genuinely determines the output, the module tests can assert
  **exact** `.sintax` content for a fixed seed, which is a real increase
  in test strength. Worth a spec ID of its own (`SX-45`) so it is not
  forgotten.
- Until then `randseed` is warn-only: no `--reproducible` flag, no
  implicit single-threading. Adding a coupling now that upstream is about
  to make unnecessary would be churn.

### Continuous (any release)

- `coverage-gate.sh` + `tests/COVERAGE.md`; fix the three drift items
  (P3-19) in the same commit that adds the gate.
- `stub:` in every process + `check-stub-run.sh` (P3-17). Doubles as the
  new-lab smoke test: "does my install work?" in seconds, no tools.
- `tests/check-*.sh` for the `conda` profile, the `cluster` profile, the
  `cleanup` default, the publish-mode matrix, the resource defaults
  (P3-18).
- Port `test_reproducible_pins.py` so the `environment.yml` ↔ CI pin
  agreement is enforced, not remembered.
- CI matrix over a pinned Nextflow and `latest-stable`; add `flake8` on
  tracked `*.py`.
- Container profile (or a committed conda lock) (P2-14).
- Close SX-01..04, SX-06..10 — mechanical bats cases, and they are
  already itemised in `tests/README.md`'s "Known gaps".

### Release checklist (fixes P2-15)

1. `Unreleased` section in `CHANGELOG.md` accumulates work.
2. Release commit: bump `manifest.version` **and** `CITATION.cff`
   (`CFG-01` enforces), rename `Unreleased` → `vX.Y.Z - <date>`.
3. Tag `vX.Y.Z` on `main`; never leave `main` ahead of its tag while
   `manifest.version` still names the tag.
4. README shows the pinned form:
   `nextflow run frederic-mahe/nf-pore2taxa -r v1.8.0 …`.
5. Tag `v1.7.1` promptly regardless, so `24a1396` stops masquerading as
   `v1.7.0`.

---

## 5. Deliberately deferred

- **HPC / slurm — *not* deferred.** An earlier draft of this plan
  deferred scheduler work indefinitely and proposed marking the `cluster`
  profile unsupported. That was wrong: HPC is a confirmed near-term
  target (see the header), so the profile is now a `v1.10.0` milestone
  with its own tests. Nor is **per-site tuning** deferred any more: the
  five sites the sibling already supports (`abims`, `genotoul`,
  `ifb_core`, `meso`, `saga`) serve the same users, and their configs
  carry no pipeline-specific content, so they import verbatim rather than
  being guessed at. What stays deferred is a **sixth, unknown site** —
  that is what `_template.config` and `-c site.config` are for. Ship the
  mechanism *and* the five known sites; invent nothing beyond them.
- **Real slurm submission in CI.** Config resolution is testable and will
  be tested (`check-cluster-profiles.sh`); actually submitting a job is
  not, and a fake-scheduler test would only prove the fake works. One
  manual smoke run at the adopting site, recorded in the CHANGELOG.
- **Retry/`errorStrategy` policy.** Worth a written decision (P1-11), not
  a code change. Note the current design is already right for target 2:
  `memory = { 16.GB * task.attempt }` cannot help on a single workstation
  (fixed RAM) but pays off under a scheduler, where a retry can land on a
  bigger node. The open question is only whether one failed barcode
  should keep aborting the whole run (`terminate`) or let the rest finish
  (`finish`) — a per-barcode fan-out over 96 samples makes that a real
  trade-off, and it is more pressing on a cluster where the run is long
  and queued.
- **`unclassified`/`mixed` semantics.** Currently these become ordinary
  columns. Correct, but a lab will ask; a README paragraph is enough.

---

## 6. Open questions

Same convention as the sibling pipeline's `DECISIONS.md`: while a
question is `open`, the spec IDs it blocks cannot go green. Record the
resolution inline when it lands (don't delete the entry) and update the
affected section of this plan in the same commit.

| Status legend | |
|---|---|
| `open` | nobody has answered yet |
| `proposed` | a draft answer exists, awaiting confirmation |
| `resolved` | answer is final; plan and tests reflect it |

### D01 — is basecalling in scope for the external lab?

**Blocks:** `BC-01`..`BC-08`, `WF-02`, `WF-05`. **Status:** `resolved`
(2026-07-29)

> **Resolution:** *unknown, so parameterise anyway.* The lab's intent is
> not established, and the cost of guessing wrong in the permissive
> direction is about a day (three params + a `dorado` stub), while the
> cost of guessing wrong in the restrictive direction is a lab that
> cannot run the pipeline at all with their kit. Committed as `v1.10.0`,
> to be promoted ahead of `v1.8.0`/`v1.9.0` if the lab confirms they
> basecall. Still worth asking them — the answer changes the *priority*,
> not the *scope*.

If the lab receives fastq from MinKNOW and always runs
`skip_basecall = true`, then P3-16 is documentation work and `v1.11.0`
disappears. If they intend to basecall pod5 themselves, the hardcoded
`sup@v5.2.0` / `EXP-PBC096` / `cuda:0` make that impossible without
editing bash, and `v1.11.0` becomes urgent — arguably part of `v1.7.1`,
because "cannot run at all with our kit" outranks the silent-failure
bugs.

**Recommendation:** ask the lab directly. If unclear, parameterise
anyway (model/kit/device are three params and a stub test) — it is a
day of work and removes a hard blocker.

### D02 — `cleanup` default on a single workstation

**Blocks:** `CFG-02`, `CFG-03` (P0-1). **Status:** `resolved`
(2026-07-29)

> **Resolution:** option (c) — **`cleanup = false` by default, plus a
> `--cleanup` param** so throwaway runs can opt back in. Correct by
> default (resumable, inspectable, link modes safe) with a one-flag
> escape hatch for the workstation's disk. Lands in `v1.7.1` together
> with the publish-mode guard. **`params.cleanup` is a new boolean and
> must go through `valid_bool`/`coerce_bool` in the same commit** — see
> the note under `v1.7.1`.

`cleanup = true` today. Flipping it to `false` makes `-resume` work
across invocations, keeps a "succeeded but looks wrong" run
inspectable, and makes `symlink`/`rellink` safe — but on one workstation
`work/` then grows without bound, and ONT runs are large (the
`subsample` pooling step materialises an *uncompressed* pooled fastq per
barcode).

Options: (a) `cleanup = false`, document manual `nextflow clean -f`;
(b) keep `cleanup = true` and reject the link modes;
(c) `cleanup = false` plus a `--cleanup` param so throwaway runs opt in.

**Recommendation:** (c). Correct-by-default, with the disk escape hatch
one flag away. Either way the startup guard against
`cleanup && publish_mode in [symlink, rellink]` ships in `v1.7.1`,
because the default is not something a plan can rely on staying put.

### D03 — output layout: `--outdir`, or keep publishing back into `fastq_dir`?

**Blocks:** `v1.12.0` (P1-9). **Status:** `resolved` (2026-07-29)

> **Resolution:** **add `--outdir`, deprecate publish-back.** One
> archivable directory per run; `fastq_dir` becomes read-only. Deprecated
> on the `sintax_silva` model — warn, honour, name `v2.0.0` as the
> removal release. Scheduled as `v1.11.0`, after provenance, so
> `versions.yml` and the execution reports are born into the new layout
> instead of being relocated a release later.

Today `.sintax`/`.log` land inside the input tree and the tables land
wherever `results_table` points. An `--outdir` gives one archivable
directory (tables, per-barcode files, reports, `versions.yml`) and stops
requiring the raw-data directory to be writable — at the cost of
changing the output contract for the configs already in use.

**Recommendation:** add `--outdir` in `v1.9.0`, keep publish-back behind
an explicit flag, and deprecate it exactly the way `sintax_silva` was
(warn, honour, name a removal release). If the current layout is
actively wanted — results sitting next to the reads they came from is a
defensible workflow — say so and this milestone is dropped rather than
deferred.

### D04 — reproducibility default: correctness or speed?

**Blocks:** P1-7, `OBS-03`, and the strength of every SINTAX assertion.
**Status:** `resolved` (2026-07-29)

> **Resolution:** **warn only — the problem is going upstream.**
> vsearch 2.32.0 is expected to make sintax reproducible under
> multithreading, which removes the trade-off entirely rather than
> forcing a choice between speed and replicability. So: add the run-time
> warning in `v1.8.0`, add **no** `--reproducible` flag and **no**
> implicit single-threading, and treat the pin bump as the real fix (see
> "Upstream-blocked"). Building a threads-vs-seed coupling now, for a
> constraint about to disappear, would be churn — and a `--reproducible`
> flag would then have to be deprecated.
>
> **Follow-on worth noting:** `OBS-03` ("SINTAX is non-deterministic, so
> tests must be structural") is the reason the module tests assert shapes
> rather than content. Once a seed genuinely determines the output, those
> tests can assert **exact** `.sintax` content — a real strengthening of
> the suite that arrives free with the pin bump. Tracked as `SX-45`.

`randseed > 0` with `SINTAX cpus = 20` is not reproducible, and nothing
says so at run time. Options considered: (a) warn only; (b) `randseed > 0`
implicitly forces single-threaded SINTAX (reproducible by default,
markedly slower); (c) a separate `--reproducible` flag that sets both,
leaving `randseed` alone. (a) was chosen once the upstream fix was known
to be imminent; (b) and (c) are both obviated by it.

### D05 — trim the `publish_mode` allowed set?

**Status:** `proposed`, **revised 2026-07-29** — drop `move` only; keep
`symlink`/`rellink` and guard them.

> **Revised because HPC is a target.** The original recommendation
> (drop `symlink`, `rellink` and `move`) was predicated on
> `cleanup = true`, which made the link modes unsafe. `D02` flips the
> default to `cleanup = false`, so they become safe by default — and on a
> cluster they are the modes that *matter*: work dirs live on fast
> scratch, results on project storage, so `link` (hardlink) cannot cross
> the filesystem boundary and `copy` duplicates the data against a quota.
> Removing them would have made the pipeline worse on target 2 in order
> to paper over a bug that the `cleanup` guard fixes properly.
>
> Revised set: **`link` (default) / `copy` / `copyNoFollow` / `symlink` /
> `rellink`**, with the startup guard rejecting
> `cleanup && publish_mode in [symlink, rellink]` — that guard is the
> real fix for P0-1 and it holds on both targets.
>
> `move` still goes: it relocates files out of the work dir that
> `BASECALL`'s downstream handoff reads from, and no executor makes that
> safe.

### D06 — migrate to nf-schema?

**Status:** `proposed` — yes, additively, in `v1.13.0`.

The concrete win is that `--subsampl 100` is currently accepted in
silence; strict validation rejects it. Cost: a plugin dependency (must
be pre-seeded for offline use) and a schema that can drift from the
config — the sibling's `test_schema_params_sync.py` handles the drift.
Keep the Groovy guards until the schema demonstrably covers them.

### D07 — containers, or a conda lockfile?

**Status:** `proposed`, **revised 2026-07-29** — both, container promoted
to `v1.10.0`.

Four exact pins is good; the transitive closure is not pinned, so two
labs resolve two environments. A committed `conda-lock`/`--explicit` file
closes most of that gap for no new infrastructure, and it stays the right
first step for the workstation.

> **Revised because HPC is a target.** The original reasoning — "on a
> single GPU workstation a container buys less, because `dorado` sits
> outside it regardless" — does not survive contact with a cluster. There,
> conda is often the *problem*: environment creation on a shared
> filesystem is slow, `NXF_CONDA_CACHEDIR` on a shared mount is a
> well-known source of corrupt/racing environments across concurrent runs,
> and plenty of sites disallow it outright. An
> `apptainer`/`singularity` profile therefore moves from "stronger but
> optional" to part of `v1.10.0`, alongside the offline/pre-built image
> path (the sibling has `check-container-profiles.sh` and
> `check-offline-container.sh` to copy). `dorado` still stays outside the
> container — which is fine, because the GPU node running it is not the
> node bottlenecked on conda.

### D08 — keep, fix, or delete the `cluster` profile?

**Blocks:** `v1.10.0`. **Status:** `resolved` (2026-07-29)

> **Resolution:** **keep it supported, and import the profiles from
> nf-metabarcoding** — same users, same sites (confirmed 2026-07-29). The
> profile is neither speculative nor to be annotated "untested": it gets
> made to work, with tests, as `v1.10.0`.
>
> This reverses the earlier recommendation to mark it unsupported and
> delete at `v2.0.0`. It also un-defers the `time` directive and gives the
> existing attempt-scaled memory escalation a reason to exist.
>
> **The import is cleaner than expected.** The five site configs
> (`abims`, `genotoul`, `ifb_core`, `meso`, `saga`) and the `_template`
> contain nothing but site facts — ceilings, queue-routing closures,
> bind mounts, array sizes — with **no process names and no tool
> references**, so they copy verbatim. Only `conf/slurm.config`'s
> `withName:` tiers need rewriting for this pipeline's five processes,
> and one of them (`assign_taxonomy_sintax` → `SINTAX`) maps onto the
> same tool doing the same thing.
>
> Consequence for §5: "ship the mechanism, not invented queue names" no
> longer applies to *these five sites* — their values are known and
> tested. It still applies to any sixth site, which is what
> `_template.config` is for.
>
> **One thing the sibling cannot give us: GPU.** `meso` and `saga` both
> state they ignore their GPU partitions because that pipeline has no GPU
> steps. `BASECALL` does, so the imported queue closures would route it
> to a CPU node. That override, and how `dorado` is reached on a compute
> node at all, is genuinely new work — see `v1.10.0`.

### D09 — release and branch model

**Status:** `proposed`

`origin/main` == `origin/dev`, one untagged commit past `v1.7.0`
(P2-15). Proposal: tag `v1.7.1` as soon as the P0 fixes land so
`24a1396` stops masquerading as `v1.7.0`; add an `Unreleased` section to
`CHANGELOG.md`; use `dev` as real staging (merge to `main` only at
release) so `main` is always exactly a tag; document `-r vX.Y.Z` in the
README. Confirm, or say you prefer trunk-based with tags only.
