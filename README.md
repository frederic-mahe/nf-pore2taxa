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

Fastq files are grouped by barcode and each barcode is processed as an
independent, parallel task (the reference database is loaded once per
barcode). The barcode is read from the file path, so both demultiplexed
subfolders (`fastq_pass/barcode01/…`) and a flat directory with the
barcode embedded in the filename (`…_barcode01_0.fastq.gz`) work; a
sibling `fastq_fail/` is ignored.

The basecalling step can be skipped if `fastq` files are already
available.


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
    results_table     = "/big/drive/projects/project_ID/results/sintax.tsv"
    primer_f = "GTACACACCGCCCGTCG"
    primer_r = "CGCCTSCSCTTANTDATATGC"

    // Set to true if basecalling was already done
    // and fastq_dir already exists
    skip_basecall     = false

    // Primer-presence filtering. true (default): drop reads in which a
    // primer is not found (strict amplicon filtering). false: keep every
    // read, trimming primers only where they are found.
    discard_untrimmed = true

    // publishDir mode. 'link' (default) requires workDir and the
    // data/results directories to share a filesystem; use 'copy' when
    // they are on different filesystems.
    publish_mode      = "link"
}
```

> [!NOTE]
> **Primer filtering (`discard_untrimmed`)**: by default a read is kept
> only when both the forward primer and the reverse-complemented reverse
> primer are located; reads with no detectable primer are discarded. Set
> `discard_untrimmed = false` to keep every read instead (useful for
> already-trimmed inputs or quick exploratory profiles), in which case
> off-target reads may also be assigned a taxonomy.

> [!WARNING]
> By default, intermediate files are linked (hardlinks), so `workDir`
> and `fastq_dir`/`results_table` must be on the same filesystem. If they
> are not, set `publish_mode = "copy"` to fall back to real copies (hard
> links cannot cross filesystems).

Now, you can run the pipeline using:

```bash
nextflow \
    run main.nf \
    -config /path/to/myproject.config
```

Parameters can also be passed via the command-line, if need be. For a
summary of every parameter and profile, run:

```bash
nextflow run main.nf --help
```

### Providing the dependencies

`cutadapt` and `vsearch` (and `python3`) must be available. The simplest
way is the bundled `conda` profile, which resolves them from the pinned
[`environment.yml`](environment.yml):

```bash
nextflow run main.nf -profile standard,conda -config /path/to/myproject.config
```

Otherwise, ensure `cutadapt` and `vsearch` (>= 2.31.0) are on your `PATH`.
Basecalling (`dorado`, `pigz`) is **not** provided by the `conda` profile —
`dorado` is an Oxford Nanopore GPU binary — so it must be installed
separately when `skip_basecall = false`.


## Pipeline output

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


## Testing

The repository ships with a test suite covering the pipeline's
custom code (driver shell scripts, the Python table builder, Nextflow
modules and workflow). External tools (`dorado`, `cutadapt`, `vsearch`)
are not re-tested. See [`tests/SPECIFICATIONS.md`](tests/SPECIFICATIONS.md)
for the catalogue of behaviours under test, and
[`tests/README.md`](tests/README.md) for the layout.

```bash
bash tests/run_all.sh           # python + bats + nf-test
python3 -m unittest discover -s tests/bin -p 'test_*.py'  # python unit tests
bats tests/bin/                 # shell + Python CLI integration tests
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
