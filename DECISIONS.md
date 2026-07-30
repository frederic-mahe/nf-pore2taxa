# Open questions / blocked spec items

Each entry below is a decision the workflow cannot make for itself. While a
question is `open`, the spec IDs it lists cannot have a green test — they
show as `blocked` in [`tests/COVERAGE.md`](tests/COVERAGE.md).

When a decision lands, record the resolution **inline** (do not delete the
entry — the reasoning is why the code looks the way it does) and update the
matching IDs in [`SPECIFICATIONS.md`](SPECIFICATIONS.md) in the same commit.

| Status legend | |
|---------------|---|
| `open` | nobody has answered yet |
| `proposed` | a draft answer exists, awaiting confirmation |
| `resolved` | answer is final; spec and tests reflect it |

The `D01`–`D14` entries below were taken during the July 2026 hardening
review; the full reasoning, alternatives considered and evidence for each is
in [`docs/plans/TBD_20260729_hardening.md`](docs/plans/TBD_20260729_hardening.md).
This file is the index — go there for the argument.

---

## Deployment targets (context for everything below)

1. **Now**: a single workstation, local executor — the external lab's
   environment.
2. **Soon**: HPC / slurm. The cluster profiles are supported, not
   hypothetical.

A fix that is right for one target can be wrong for the other; `D08` and
`D05` are both cases where that mattered.

---

## D01 — is basecalling in scope for the external lab?

**Affects:** `BC-01`..`BC-12`, `WF-02`, `WF-05`
**Status:** `resolved` (2026-07-29) — *unknown, so parameterise anyway*

The lab's intent was never established. Guessing permissively cost about a
day (three params + a dorado stub); guessing restrictively would have left a
lab unable to basecall with their own kit. Shipped in v1.11.0.

Worth recording: the value turned out not to be the parameters. Writing the
tests exposed a **destructive** bug — the driver script's `clean_up` walked
the *caller's* directory rather than `--output-dir`, moving and deleting
directories there (`BC-11`). A lab would have hit that the first time they
ran the script by hand to debug a basecalling problem.

## D02 — `cleanup` default on a single workstation

**Affects:** `CFG-02`, `CFG-03`
**Status:** `resolved` (2026-07-29) — *`cleanup = false`, plus a `--cleanup`
opt-in*

Correct by default (resumable, inspectable, link publish modes safe) with a
one-flag escape hatch for disk. `params.cleanup` is a boolean, so it goes
through `valid_bool`/`coerce_bool` — see `WF-16`.

## D03 — output layout

**Affects:** `OUT-01`..`OUT-06`
**Status:** `resolved` (2026-07-29) — *add `--outdir`, deprecate publish-back*

One archivable directory per run; `fastq_dir` becomes read-only.
`results_table` and `publish_beside_reads` are honoured with a warning and
removed at **v2.0.0**.

## D04 — reproducibility default: correctness or speed?

**Affects:** `CFG-06`, `OBS-03`, and the strength of every `SINTAX` assertion
**Status:** `resolved` (2026-07-29) — *warn only; the fix is upstream*

vsearch 2.32.0 is expected to make sintax reproducible under multithreading,
which removes the trade-off rather than managing it. So: warn at startup, add
no `--reproducible` flag, and treat the pin bump as the real fix.

**Follow-on when that lands:** bump `environment.yml` + CI together, raise
`MIN_VSEARCH_VERSION`, delete the warning, rewrite `OBS-03`, and then
strengthen the `SINTAX` tests to assert **exact** `.sintax` content for a
fixed seed. Tracked as `SX-45`.

## D05 — the `publish_mode` allowed set

**Status:** `resolved` (2026-07-29, revised) — *drop `move` only; keep the
link modes*

The first answer (drop `symlink`/`rellink`/`move`) was predicated on
`cleanup = true`. `D02` flips that default, so the link modes became safe —
and on a cluster they are the ones that matter, where work sits on scratch
and results on project storage. `move` still goes: it relocates files out of
the work directory that `BASECALL`'s downstream handoff reads from.

## D06 — how are unrecognised parameters caught?

**Affects:** `PRM-01`, `PRM-02`
**Status:** `resolved` (2026-07-29) — *hand-rolled strict check, no plugin*

Reverses an earlier recommendation of nf-schema. Once HPC became a real
target, a plugin that must be pre-seeded in `$NXF_PLUGINS_DIR` on air-gapped
compute nodes acquired a cost it did not have before, while the concrete win
came to about twenty lines. Given up: JSON-schema types/enums and nf-core
tooling compatibility.

## D07 — containers, or a conda lockfile?

**Status:** `resolved` (2026-07-29, revised) — *both; container promoted*

Container profiles shipped in v1.10.0 (Wave building from the same pinned
`environment.yml`). The original "lockfile first" reasoning did not survive
HPC: conda on a shared filesystem is slow, a shared cache races between
concurrent runs, and some sites disallow it. **A committed conda lock is
still outstanding.**

## D08 — keep, fix, or delete the `cluster` profile?

**Affects:** `CLU-01`..`CLU-09`
**Status:** `resolved` (2026-07-29) — *keep it supported; import the sibling's
profiles*

Same users, same sites as nf-metabarcoding, whose `conf/clusters/` files
carry only site facts — so the five institutional profiles imported verbatim.
`cluster` is retained as an exact alias of `slurm` (`CLU-04`).

## D09 — release and branch model

**Status:** `resolved` (2026-07-29) — *`dev` stages, `main` only at releases*

`main` is fast-forwarded and tagged at each release, so it is always exactly
a released version — which is what makes `nextflow run
frederic-mahe/nf-pore2taxa` reproducible without `-r`.

## D10 — how are tool versions captured?

**Affects:** `PRV-01`..`PRV-03`
**Status:** `resolved` (2026-07-29) — *a probe process, plus dorado from
`BASECALL` itself*

dorado is absent from the conda environment and may be absent from the
probe's node entirely, so the task that actually ran it is the only honest
source. A probe-only design would have recorded `n/a` for the GPU step.

## D11 — where do the provenance artefacts go?

**Status:** `resolved` (2026-07-29) — *`pipeline_info/` beside the tables*

The layout `--outdir` adopted in v1.12.0, so that release re-rooted one
directory instead of moving files.

## D12 — execution reports on by default?

**Affects:** `PRV-05`
**Status:** `resolved` (2026-07-29) — *on, fixed names, `overwrite = true`*

Provenance you must remember to enable is provenance you will not have. The
cost is explicit: a `-resume` report replaces the earlier run's.

## D13 — persist the effective parameters?

**Affects:** `PRV-04`, `PRV-07`
**Status:** `resolved` (2026-07-29) — *yes, a separate `params.json`*

Keeps the sibling's and nf-core's naming, and lets tool versions be diffed
independently of settings. It deliberately omits the session id and command
line: those vary per *invocation*, and including them made the task re-run on
every `-resume`, spending `SX-35`'s clean signal to duplicate what the
execution report already records.

## D14 — GPU routing for `BASECALL` on a cluster

**Affects:** `CLU-09`, `STB-01`
**Status:** `resolved` (2026-07-29) — *basecalling is local-only, for now, and
enforced*

`conf/slurm.config` ships no `BASECALL` tier, no site profile routes to a GPU
partition, and `main.nf` refuses at startup when basecalling is requested
under a non-local executor.

Per-site GPU routing would need a partition name, `--gres` syntax, possibly a
separate account, *and* an answer to how dorado is reached on a compute node
at all. None of that can be guessed for a site nobody has run on, and the
hybrid it would replace — basecall once on the GPU workstation, then run the
cheap CPU half at scale — is what people will do anyway.

**Revisit when a site asks.** The refusal message names the workaround, so a
user who hits it is not left guessing.

---

## Open

*(none)*

Two things are waiting on the outside world rather than on a decision:

- **vsearch 2.32.0** — see `D04`. Blocks `SX-45`.
- **A real `sbatch` submission and a real container image build.** Config
  resolution is fully tested (`CLU-01`..`CLU-09`); neither of those two can
  be, here. They stay manual smoke tests at the first adopting site — a fake
  scheduler would only prove the fake works.
