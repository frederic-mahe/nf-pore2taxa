# nf-pore2taxa

quick taxonomic assignment of Nanopore metabarcoding data


## Introduction

**nf-pore2taxa** is a [netxflow](https://nextflow.io/) bioinformatics
analysis pipeline used for Nanopore amplicon sequencing. Its goal is
to provide _quick & dirty_ taxonomic profiles. To do so, it supports
taxonomic assignment with the [sintax](https://doi.org/10.1101/074161)
method, as implemented in
[vsearch](https://github.com/torognes/vsearch), and produces an
occurrence table (identified taxa vs. barcode ID). Read processing is
minimal: a simple primer trimming and conversion to fasta
([cutadapt](https://cutadapt.readthedocs.io/en/stable/), [Martin
2011](http://dx.doi.org/10.14806/ej.17.1.200)). Read are then grouped
based on their taxonomic assignments (sintax cutoff: 0.90). Any
taxonomic reference dataset can be used (16S/18S SSU rRNA, ITS, COI,
etc.), as long as it is properly formated (fasta file, with headers in
sintax format).

> [!NOTE]
> **sintax format**: the reference database (in fasta format) must
> contain taxonomic information in the header of each sequence in the
> form of a string starting with `;tax=` and followed by a
> comma-separated list of up to nine taxonomic identifiers. Each
> taxonomic identifier must start with an indication of the rank by
> one of the letters `d` (for domain), `k` (kingdom), `p` (phylum),
> `c` (class), `o` (order), `f` (family), `g` (genus), `s` (species),
> or `t` (strain). The letter is followed by a colon (`:`) and the
> name of that rank. Commas and semicolons are not allowed in the name
> of the rank. Non-ascii characters should be avoided in the names.


## Pipeline summary

By default, the pipeline currently performs the following:

- basecalling and demultiplexing of pod5 ('super accurate') with
  [dorado](https://github.com/nanoporetech/dorado)
- trimming of reads with
  [cutadapt](https://cutadapt.readthedocs.io/en/stable/)
- taxonomic assignment with
  [vsearch](https://github.com/torognes/vsearch) (sintax)
- build an occurrence table (using a dependency-free
  [Python](https://www.python.org/) 3 script; standard library only)
- optionally, render interactive
  [Krona](https://github.com/marbl/Krona) charts from the occurrence
  tables (`--krona`)

Fastq files are grouped by barcode and each barcode is processed as an
independent, parallel task (the reference database is loaded once per
barcode). The barcode is read from the file path, so both demultiplexed
subfolders (`fastq_pass/barcode01/…`) and a flat directory with the
barcode embedded in the filename (`…_barcode01_0.fastq.gz`) work; a
sibling `fastq_fail/` is ignored.

The basecalling step can be skipped if `fastq` files are already
available — and it must be, on a cluster: see the basecalling note below.
The model, kit and compute device are all parameters
(`--basecall_model`, `--basecall_kit`, `--basecall_device`), and the model
is cached after its first download.


## Usage

First, you need to prepare a `config` file, with the parameters for
your project.

```
// nf-pore2taxa workflow

workDir = "/big/drive/projects/project_ID/work"

params {
    pod5_dir          = "/big/drive/runs/run_ID/pod5"
    fastq_dir         = "/big/drive/projects/project_ID/data/run_ID"
    sintax_references = "/safe/data/references.fasta.gz"
    // Single output directory: tables, per_barcode/, Krona and
    // pipeline_info/ all land here, and the raw data stays read-only.
    outdir            = "/big/drive/projects/project_ID/results"
    table_name        = "sintax.tsv"
    primer_f = "GTACACACCGCCCGTCG"
    primer_r = "CGCCTSCSCTTANTDATATGC"

    // Set to true if basecalling was already done
    // and fastq_dir already exists
    skip_basecall     = false

    // Basecalling (only used when skip_basecall = false). These were
    // hardcoded until v1.11.0, so a different kit meant editing the
    // shell script. Model: the short form gets the flowcell/chemistry
    // prefix 'dna_r10.4.1_e8.2_400bps_'; pass a full dorado model name
    // for other chemistry (e.g. "dna_r9.4.1_e8_hac@v3.3.0").
    basecall_model    = "sup@v5.2.0"
    basecall_kit      = "EXP-PBC096"
    basecall_device   = "cuda:0"          // or cpu, cuda:all, cuda:0,1
    // The ~1 GB model is downloaded once and kept here, outside the work
    // directory, so later runs need neither the download nor a network.
    basecall_model_dir = "/big/drive/dorado_models"

    // Primer-presence filtering. true (default): drop reads in which a
    // primer is not found (strict amplicon filtering). false: keep every
    // read, trimming primers only where they are found.
    discard_untrimmed = true

    // Seed for vsearch's random generator in the sintax step. 0 (default)
    // picks a pseudo-random seed each run; a positive integer gives
    // reproducible single-threaded assignments.
    randseed          = 0

    // Cap each barcode at this many reads before trimming (0 = keep all,
    // the default). A positive value pools the barcode's fastq files and
    // subsamples them (seeded by randseed) so only that many reads are
    // processed and assigned — handy for a quick preview or to even out
    // sampling depth across barcodes.
    subsample         = 0

    // Render interactive Krona HTML charts from the occurrence tables
    // (one dataset per barcode). false (default) skips it. Requires
    // KronaTools (ktImportText), provided by the conda profile.
    krona             = false

    // publishDir mode. 'link' (default) requires workDir and the
    // data/results directories to share a filesystem; use 'copy' when
    // they are on different filesystems. Also accepted: 'copyNoFollow',
    // 'symlink', 'rellink' (the link modes require cleanup = false).
    publish_mode      = "link"

    // Delete the work directory when the run succeeds. false (default)
    // keeps it, so `-resume` works across separate invocations and a
    // run that looks wrong can still be inspected. Set true (or pass
    // --cleanup) for throwaway runs; `nextflow clean -f` does the same
    // afterwards.
    cleanup           = false

    // Ceiling on any single task's cpu / memory request. Defaults to
    // what the machine has, so nothing needs setting here; lower them
    // to leave headroom for other work on a shared workstation.
    // max_cpus       = 8
    // max_memory     = "32.GB"
}
```

> [!IMPORTANT]
> **Basecalling is local-only.** `dorado` is an Oxford Nanopore GPU binary
> that is not on bioconda, so it is in neither the conda environment nor any
> container, and the cluster profiles route jobs by memory and time — it
> would land on a CPU node. A run that requests basecalling under a scheduler
> is refused at startup. Basecall on the GPU workstation, then run the rest
> on the cluster with `--skip_basecall`. Set `--basecall_device cpu` if you
> have no GPU at all (slow, but it works).

> [!NOTE]
> **Primer filtering (`discard_untrimmed`)**: by default a read is kept
> only when both the forward primer and the reverse-complemented reverse
> primer are located; reads with no detectable primer are discarded. Set
> `discard_untrimmed = false` to keep every read instead (useful for
> already-trimmed inputs or quick exploratory profiles), in which case
> off-target reads may also be assigned a taxonomy.

> [!NOTE]
> **Subsampling (`subsample`)**: when set to a positive integer, each
> barcode's fastq files are pooled and randomly subsampled to that many
> reads *before* primer trimming (using `randseed` for reproducibility), so
> only that many reads are processed and assigned. Because the cap is applied
> before primer filtering, the number of *assigned* reads may be smaller than
> the cap when `discard_untrimmed = true`. Leave at `0` (default) to keep
> every read.

> [!WARNING]
> By default, intermediate files are linked (hardlinks), so `workDir`
> and `fastq_dir`/`results_table` must be on the same filesystem. If they
> are not, set `publish_mode = "copy"` to fall back to real copies (hard
> links cannot cross filesystems).

> [!NOTE]
> **`cleanup` and the link publish modes**: `symlink`/`rellink` publish
> *pointers* into the work directory, so they only make sense while the
> work directory survives. Combining either with `cleanup = true` would
> leave every published output — the occurrence tables, the per-barcode
> `.sintax` files, the Krona charts — a dangling link, so the pipeline
> refuses that combination at startup instead of producing it.

> [!NOTE]
> **Reproducibility**: `randseed` only makes a run exactly replayable when
> the assignment step runs single-threaded — `vsearch --sintax` is
> order-dependent across threads. Setting a seed therefore prints a warning
> unless the threads are capped (`--max_cpus 1`). The startup log records
> every effective parameter, so a run's own log says what produced its
> tables.

> [!NOTE]
> **Resources**: the per-step requests are written for a well-provisioned
> machine (the taxonomic assignment asks for 20 cores and 16 GB), and every
> request is then *clamped* to `max_cpus`/`max_memory`, which default to
> what your machine actually has. So the pipeline runs unmodified on a
> laptop or a workstation — it simply uses fewer threads — and no config
> editing is needed to fit a smaller box. The startup log reports the
> effective ceiling, so a run that used fewer threads than the config asks
> for is explicable. Lower the two values to leave room for other work.

> [!NOTE]
> **Resuming a run**: because `cleanup` defaults to `false`, `-resume`
> works across separate invocations. Adding fastq files to `fastq_dir`
> (a topped-up library, or a second flow cell for one barcode) and
> re-running with `-resume` re-processes only the barcodes whose files
> changed, and rebuilds the tables; the other barcodes are cache hits.

### Try it first

Before pointing the pipeline at your own data, run the bundled demo. It needs
no flags and no data of your own:

```bash
nextflow run main.nf -profile demo
```

That runs the whole pipeline against the small synthetic dataset in
[`assets/demo/`](assets/demo) and writes `demo_results/`, so you can tell a
broken environment from awkward data before either is in play. Add an
environment profile to check that too, e.g. `-profile demo,conda`. The reads
are synthetic and not biologically meaningful — what it demonstrates is that
the tools, the wiring and your environment work end to end.

Now, you can run the pipeline using:

```bash
nextflow \
    run main.nf \
    -config /path/to/myproject.config
```

Parameters can also be passed via the command-line, if need be. A parameter
name the pipeline does not recognise is rejected at startup, with the nearest
match suggested:

```
$ nextflow run main.nf --subsampl 100 ...
[ERROR] Parameter validation failed:
  - unknown parameter 'subsampl'. Did you mean 'subsample'? Run with --help
    for the full list.
```

so a typo cannot quietly leave the real parameter at its default. For a
summary of every parameter and profile, run:

```bash
nextflow run main.nf --help
```

### Running on a cluster

Scheduler execution is supported. Five institutional profiles ship ready to
use — they imply slurm, so never list `slurm` as well:

```bash
nextflow run main.nf -profile abims,apptainer -config myproject.config \
    --skip_basecall --fastq_dir /path/to/run --slurm_account my_account
```

| Profile | Site |
| ------- | ---- |
| `abims` | ABiMS, Roscoff (requires `--slurm_account`) |
| `genotoul` | Genotoul, Toulouse |
| `ifb_core` | IFB Core cluster |
| `meso` | MESO@LR / CIRAD dedicated partitions |
| `saga` | Saga, Sigma2 (Norway) |
| `slurm` | generic slurm; set your own queue/account/ceiling |

For a site not listed, use `-profile slurm` with a `-c site.config` (copy
[`conf/site.config.example`](conf/site.config.example)), or add a profile
from [`conf/clusters/_template.config`](conf/clusters/_template.config).
Tell the pipeline how big your reference database is
(`--reference_size_gb`) and the assignment step will size its memory
request accordingly instead of using a fixed fallback.

> [!IMPORTANT]
> **Basecalling is local-only.** `dorado` is an Oxford Nanopore GPU binary
> that is not on bioconda, so it is in neither the conda environment nor any
> container, and the cluster profiles route jobs to partitions by memory and
> time — basecalling would land on a CPU node. The pipeline therefore
> **refuses at startup** if you ask for basecalling under a scheduler.
> Basecall on the GPU workstation, then run the (much cheaper) rest on the
> cluster with `--skip_basecall` and `--fastq_dir` pointing at the result.

### Providing the dependencies

`cutadapt` and `vsearch` (and `python3`) must be available. The simplest
way is the bundled `conda` profile, which resolves them from the pinned
[`environment.yml`](environment.yml):

```bash
nextflow run main.nf -profile standard,conda -config /path/to/myproject.config
```

On a cluster, prefer a container to conda — conda on a shared filesystem is
slow and a shared cache races between concurrent runs. Add an engine profile
and Seqera Wave builds the image from the same pinned `environment.yml`, so
there is nothing to publish or maintain:

```bash
nextflow run main.nf -profile abims,apptainer -config myproject.config
```

`apptainer`, `singularity`, `docker` and `podman` are all available.

Otherwise, ensure `cutadapt` and `vsearch` (>= 2.31.0) are on your `PATH`.
Basecalling (`dorado`, `pigz`) is **not** provided by the `conda` profile —
`dorado` is an Oxford Nanopore GPU binary — so it must be installed
separately when `skip_basecall = false`.


## Pipeline output

Everything a run produces goes under `--outdir`:

```
outdir/
├── sintax.tsv                  the filtered occurrence table
├── sintax_optimistic.tsv       the optimistic one
├── sintax.krona.html           (with --krona)
├── sintax_optimistic.krona.html
├── per_barcode/
│   ├── barcode01.sintax        per-barcode assignments
│   └── barcode01.log           its cutadapt log
└── pipeline_info/
    ├── software_versions.yml
    ├── params.json
    ├── execution_report.html
    ├── execution_timeline.html
    ├── execution_trace.txt
    └── pipeline_dag.html
```

One directory to archive, and `fastq_dir` is never written to — so it can be
read-only, and two projects may share one.

> [!NOTE]
> **Migrating from before v1.12.0**: `results_table` still works and still
> puts your tables exactly where they were, with a deprecation warning — its
> parent becomes `outdir` and its basename `table_name`. The per-barcode files
> move to `outdir/per_barcode/`; pass `--publish_beside_reads` to keep writing
> them into the read tree as well. Both are removed at v2.0.0.

Two tab-separated tables with identified taxa as rows, and barcode IDs
(i.e, samples) as columns. The first line is the header line (column
names). An additional column with the total number of reads for each
taxa is also provided (column number 2). Barcodes without any
assignments are grouped at the far-right of the table.

Here is a tiny output table example with only two barcodes, and two
identified taxa:

| taxonomy        | total | barcode03 | barcode01 |
|-----------------|------:|----------:|----------:|
| d:Fungi ...     |  1234 |      1234 |         0 |
| d:Viridiplantae |    42 |        42 |         0 |

`barcode01` is empty (no assigned reads), so it appears last.

The second output table, marked as *optimistic*, has the same
structure as the first table. It contains full taxonomic assignments,
including assignments that are below the probability threshold (0.9).

Every run also writes a `pipeline_info/` directory beside the results
table, so a run can explain itself long after the fact:

| File | What it records |
| ---- | --------------- |
| `software_versions.yml` | the version of every tool that ran (`vsearch`, `cutadapt`, KronaTools, Python, and `dorado` when basecalling happened), plus the pipeline release and the Nextflow that ran it |
| `params.json` | the *effective* configuration — every parameter as it was actually in force, after defaults, aliases and command-line overrides |
| `execution_report.html` | per-task resource use, runtimes, exit codes |
| `execution_timeline.html` | when each task ran |
| `execution_trace.txt` | the same as a TSV, with requested vs observed cpu/memory per task |
| `pipeline_dag.html` | the workflow graph |

Archive that directory alongside the tables and two labs can diff exactly
what differed between their runs. The reports use fixed filenames and are
refreshed in place, so a `-resume` describes the resumed run; copy
`pipeline_info/` first if you need to keep an earlier one.

When `--krona` is set, the pipeline also writes two interactive
[Krona](https://github.com/marbl/Krona) charts beside the tables, each
named after the table it was built from: `sintax.tsv` yields
`sintax.krona.html`, and `sintax_optimistic.tsv` yields
`sintax_optimistic.krona.html`. Set `--table_name` and the charts follow,
so runs launched in parallel produce charts that can still be told apart
once they are gathered into one directory or a browser's download folder.
Each is a single self-contained HTML holding one dataset per barcode (a
per-sample dropdown), so a whole run's taxonomic profiles can be explored
in a browser. The hierarchy is taken directly from the tables' taxonomy
column; barcodes with no assigned reads are omitted. This step needs
KronaTools (`ktImportText`), which the `conda` profile provides; Krona's
text mode requires no NCBI taxonomy database.


## Testing

The repository ships with a test suite covering the pipeline's
custom code (driver shell scripts, the Python table builder, Nextflow
modules and workflow). External tools (`dorado`, `cutadapt`, `vsearch`)
are not re-tested. See [`SPECIFICATIONS.md`](SPECIFICATIONS.md)
for the catalogue of behaviours under test — it is authoritative, and carries
the test-first cycle contributors follow — plus
[`DECISIONS.md`](DECISIONS.md) for questions that block a spec, and
[`tests/README.md`](tests/README.md) for the layout.

```bash
bash tests/run_all.sh           # python + bats + nf-test
python3 -m unittest discover -s tests/bin -p 'test_*.py'  # python unit tests
bats tests/bin/                 # shell + Python CLI integration tests
bats tests/config/              # config invariants, publish modes, -resume
nf-test test tests/             # pipeline tests only
```

Test dependencies: `python3` (standard library only), `bats >= 1.5`,
`nf-test`, and the runtime dependencies of the pipeline itself
(`cutadapt`, `vsearch >= 2.31.0`).


## Road-map

- [X] eliminate variability due to sintax? not currently possible
- [X] `assign_with_sintax.sh` eliminate fastq to fasta conversion,
      cutadapt can read `fastq.gz` directly
- [X] write unit tests using nextflow's tooling (see `tests/`)
- [ ] refactor `assign_with_sintax.sh`. Use `nextflow` to find and
      loop over the `fastq.gz` files. Operate on each file
      independently, publish back the results in the same directory
- [X] add a module that checks if binaries (cutadapt, vsearch, dorado)
      are in PATH? already done by the different scripts, but should
      be done earlier
- [ ] add a module that checks parameters and dependencies before
      running any computation. Do we need to pass parameters that are
      not used? for instance, if we skip basecalling, do we need to
      pass the path to `pod5` files?
- [ ] add a cleanup module (remove `done.txt` files, work sub-folders,
      etc.
- [X] eliminate dependency to `R` and the `tidyverse` package, rewrite
      script in python (`bin/build_occurrence_table.py`, standard
      library only)


## See also

- [NanoASV](https://github.com/ImagoXV/NanoASV): a snakemake-based
  workflow for Nanopore amplicon sequencing (16S/18S SSU rRNA)
