#!/usr/bin/env bats
#
# CLU-01..CLU-09: the slurm profile, the five institutional cluster
# profiles, and the container engine profiles.
#
# Run with:
#   bats tests/config/cluster_profiles.bats
#
# Config resolution only — no scheduler, no container engine, no image
# build, so this runs in CI with nothing but Nextflow installed. That is
# the point: the whole class of bug these guard against is a profile that
# *resolves wrongly*, which is invisible until a real submission and cheap
# to catch here. Real sbatch submission and a real image build stay manual
# smoke tests at the adopting site; a fake scheduler would only prove the
# fake works.
#
# The profiles are imported from nf-metabarcoding — same author, same
# users, same sites — whose conf/clusters/ files carry only site facts.
#
# Basecalling is local-only (dorado is a GPU binary outside the packaged
# environment, and the queue closures route by memory/time, so BASECALL
# would land on a CPU node). CLU-09 pins the refusal.

bats_require_minimum_version 1.5.0

# The five sites shipped, with the ceiling each declares.
readonly SITES="abims genotoul ifb_core meso saga"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    if ! command -v nextflow > /dev/null 2>&1 ; then
        skip "nextflow not in PATH"
    fi
    FIXTURES="${REPO_ROOT}/tests/fixtures"
    cd "${REPO_ROOT}" || return 1
}

flat() {
    nextflow config -flat -profile "$1" 2> /dev/null
}

# The `cpus` entry of process.resourceLimits, whichever way this Nextflow
# renders it. `nextflow config -flat` gives every nested map key a dotted
# row of its own from 26.04 on:
#
#   process.resourceLimits.cpus = 512
#
# while 25.10.x and earlier print the map whole, on one line:
#
#   process.resourceLimits = [cpus:512, memory:'2 TB', time:'30d']
#
# The CI matrix spans both versions on purpose (see the header), so a
# pattern that knows only one of them reports a missing ceiling on the
# other — a failure with nothing wrong behind it. Matching both keeps the
# assertion about the site's value rather than about the renderer.
resource_limits_cpus() {
    flat "$1" \
        | sed -nE -e 's/^process\.resourceLimits\.cpus = ([0-9]+)$/\1/p' \
                  -e 's/^process\.resourceLimits = \[.*cpus:([0-9]+).*$/\1/p'
}

# ------------------------------------------------------------------- CLU-01

@test "CLU-01 every shipped profile resolves" {
    local profile
    for profile in standard slurm cluster ${SITES} \
                   conda apptainer singularity docker podman ; do
        nextflow config -flat -profile "${profile}" > /dev/null 2>&1 || {
            echo "-profile ${profile} did not resolve:"
            nextflow config -flat -profile "${profile}" 2>&1 | head -5
            return 1
        }
    done
}

@test "CLU-01b an executor profile composes with an engine profile" {
    # How a site actually runs it: -profile abims,apptainer.
    local profile
    for profile in slurm,apptainer abims,apptainer meso,singularity \
                   standard,conda saga,docker ; do
        nextflow config -flat -profile "${profile}" > /dev/null 2>&1 || {
            echo "-profile ${profile} did not resolve"; return 1
        }
    done
}

# ------------------------------------------------------------------- CLU-02

@test "CLU-02 a cluster profile implies slurm without naming it" {
    # Each site includes conf/slurm.config, so a user never lists `slurm`.
    local site
    for site in ${SITES} ; do
        run flat "${site}"
        [[ "${output}" == *"process.executor = 'slurm'"* ]] || {
            echo "-profile ${site} did not set the slurm executor"; return 1
        }
    done
}

@test "CLU-02b the slurm profile carries the submission plumbing" {
    run flat slurm
    for key in params.slurm_queue params.slurm_account \
               params.slurm_clusterOptions params.slurm_queue_size \
               process.clusterOptions executor.queueSize ; do
        [[ "${output}" == *"${key}"* ]] || {
            echo "slurm profile is missing ${key}"; return 1
        }
    done
}

# ------------------------------------------------------------------- CLU-03

@test "CLU-03 each site sets its own resource ceiling" {
    # A site's ceiling must be its largest node, so the retry escalation is
    # clamped to something that exists rather than looping to failure.
    local site cpus
    for site in ${SITES} ; do
        cpus="$(flat "${site}" | sed -nE 's/^params\.max_cpus = ([0-9]+)$/\1/p')"
        [ -n "${cpus}" ] || { echo "${site}: no max_cpus"; return 1; }
        # Every shipped site is far larger than any workstation.
        [ "${cpus}" -ge 64 ] || { echo "${site}: max_cpus=${cpus} looks wrong"; return 1; }
        # And resourceLimits is rebuilt from it, not left at the default.
        [ "$(resource_limits_cpus "${site}")" = "${cpus}" ] || {
            echo "${site}: resourceLimits.cpus != max_cpus (${cpus})"; return 1
        }
    done
}

@test "CLU-03b a site ceiling is NOT the running host's capacity" {
    # The whole point: params.max_cpus auto-detects locally, which under a
    # scheduler would describe the submit host and silently shrink every
    # submitted job. A cluster profile must override it.
    local host site cpus
    host="$(nproc --all)"
    for site in ${SITES} ; do
        cpus="$(flat "${site}" | sed -nE 's/^params\.max_cpus = ([0-9]+)$/\1/p')"
        if [ "${cpus}" -eq "${host}" ] ; then
            skip "this host has ${host} cores, same as ${site}: cannot discriminate"
        fi
    done
    # Reaching here means no site echoed the host's core count.
    [ -n "${host}" ]
}

@test "CLU-03c walltime is set under slurm and absent locally" {
    # Without a `time` directive every job inherits the queue default and
    # is killed there. The local executor has no walltime enforcer, so the
    # directives live in conf/slurm.config only.
    run flat slurm
    [[ "${output}" == *"process.time"* ]]

    run flat standard
    [[ "${output}" != *"process.time"* ]]
}

# ------------------------------------------------------------------- CLU-04

@test "CLU-04 'cluster' is an exact alias of 'slurm'" {
    # `cluster` shipped from v1.0.0 and project configs use it; it must keep
    # resolving identically rather than quietly diverging.
    run bash -c "diff <(nextflow config -flat -profile cluster 2>/dev/null | sort) \
                      <(nextflow config -flat -profile slurm   2>/dev/null | sort)"
    [ "${status}" -eq 0 ] || { echo "cluster and slurm differ:"; echo "${output}"; return 1; }
}

# ------------------------------------------------------------------- CLU-05

@test "CLU-05 sites enable slurm job arrays" {
    # One task per barcode, up to 96 a run: exactly the submission load
    # arrays exist to reduce.
    local site
    for site in ${SITES} ; do
        run flat "${site}"
        [[ "${output}" == *"process.array = 50"* ]] || {
            echo "${site} does not batch tasks into job arrays"; return 1
        }
    done
}

# ------------------------------------------------------------------- CLU-06

@test "CLU-06 engine profiles enable the engine plus Wave" {
    run flat apptainer
    [[ "${output}" == *"apptainer.enabled = true"* ]]
    [[ "${output}" == *"apptainer.autoMounts = true"* ]]
    [[ "${output}" == *"wave.enabled = true"* ]]

    run flat singularity
    [[ "${output}" == *"singularity.enabled = true"* ]]
    [[ "${output}" == *"wave.enabled = true"* ]]
}

@test "CLU-06b an engine profile must NOT enable native conda" {
    # conda.enabled is the switch for Nextflow's own conda integration,
    # independent of Wave. With both on, Nextflow ALSO runs a local
    # `conda env create` on the launch node — which on an HPC login node
    # blocks on a slow solve and can fail, stalling the run before a single
    # task is submitted. Wave needs only the process `conda` directive.
    local engine
    for engine in apptainer singularity docker podman ; do
        run flat "${engine}"
        [[ "${output}" != *"conda.enabled = true"* ]] || {
            echo "-profile ${engine} switches on native conda as well as Wave"
            return 1
        }
        # ...but the per-process spec Wave reads must be present.
        [[ "${output}" == *"'withName:SINTAX'.conda"* ]] || {
            echo "-profile ${engine} has no conda spec for Wave to build from"
            return 1
        }
    done
}

@test "CLU-06c the engine mounts survive includeConfig on a site profile" {
    # Dotted assignment, never a block-form `apptainer { }` scope: reached
    # through includeConfig on Nextflow 25.10.x, a block silently drops the
    # engine profile's `enabled = true`, the container is disabled, and the
    # run falls back to a local conda env with no error. This asserts both
    # halves survive together.
    run flat abims,apptainer
    [[ "${output}" == *"apptainer.enabled = true"* ]]
    [[ "${output}" == *"apptainer.runOptions = '-B /shared'"* ]]
}

# ------------------------------------------------------------------- CLU-07

@test "CLU-07 BASECALL is never containerised or conda-packaged" {
    # dorado is not on bioconda, so it is in neither environment.yml nor any
    # image built from it. A conda directive on BASECALL would hand it an
    # environment without the one tool it needs.
    local profile
    for profile in conda apptainer singularity docker podman abims,apptainer ; do
        run flat "${profile}"
        [[ "${output}" != *"'withName:BASECALL'.conda"* ]] || {
            echo "-profile ${profile} packages BASECALL"; return 1
        }
    done
}

# ------------------------------------------------------------------- CLU-08

@test "CLU-08 the shipped site list matches the registered profiles" {
    # A conf/clusters/<name>.config with no profile is dead config; a
    # profile with no file fails to resolve (CLU-01). Keep them in step.
    local file name
    for file in "${REPO_ROOT}"/conf/clusters/*.config ; do
        name="$(basename "${file}" .config)"
        [ "${name}" = "_template" ] && continue
        grep -qE "includeConfig +'conf/clusters/${name}\.config'" \
             "${REPO_ROOT}/nextflow.config" || {
            echo "conf/clusters/${name}.config is not registered as a profile"
            return 1
        }
    done
    # The template is NOT registered: it is a starting point, not a site.
    # Matched on the includeConfig line specifically — the file is
    # legitimately *mentioned* in a comment pointing users at it.
    run ! grep -qE "includeConfig +'conf/clusters/_template\.config'" \
                   "${REPO_ROOT}/nextflow.config"
}

# ------------------------------------------------------------------- CLU-09

@test "CLU-09 basecalling under a scheduler is refused at startup" {
    # Rather than submitting a job to a node with no GPU and no dorado,
    # then failing after a queue wait with an error whose cause is far from
    # its reason.
    cd "${BATS_TEST_TMPDIR}" || return 1
    mkdir -p pod5 data/fastq_pass
    run nextflow run "${REPO_ROOT}/main.nf" -profile slurm \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        --pod5_dir "${BATS_TEST_TMPDIR}/pod5" \
        --fastq_dir "${BATS_TEST_TMPDIR}/data" \
        --sintax_references "${FIXTURES}/references.fasta" \
        --results_table "${BATS_TEST_TMPDIR}/out.tsv" \
        --primer_f "GTACACACCGCCCGTCG" --primer_r "CGCCTSCSCTTANTDATATGC"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"basecalling is not supported under the 'slurm' executor"* ]]
    # The message must say what to do instead, not just refuse.
    [[ "${output}" == *"skip_basecall"* ]]
}

@test "CLU-09b local basecalling is still allowed" {
    # The guard is about schedulers, not about basecalling.
    cd "${BATS_TEST_TMPDIR}" || return 1
    mkdir -p pod5 data/fastq_pass
    run nextflow run "${REPO_ROOT}/main.nf" -profile standard \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        --pod5_dir "${BATS_TEST_TMPDIR}/pod5" \
        --fastq_dir "${BATS_TEST_TMPDIR}/data" \
        --sintax_references "${FIXTURES}/references.fasta" \
        --results_table "${BATS_TEST_TMPDIR}/out.tsv" \
        --primer_f "GTACACACCGCCCGTCG" --primer_r "CGCCTSCSCTTANTDATATGC"
    # It will fail for want of dorado/a GPU, but NOT at validation.
    [[ "${output}" != *"basecalling is not supported"* ]]
}

@test "CLU-09c a site that requires an account refuses without one" {
    cd "${BATS_TEST_TMPDIR}" || return 1
    mkdir -p data/fastq_pass
    run nextflow run "${REPO_ROOT}/main.nf" -profile abims \
        -work-dir "${BATS_TEST_TMPDIR}/work" \
        --skip_basecall true \
        --fastq_dir "${BATS_TEST_TMPDIR}/data" \
        --sintax_references "${FIXTURES}/references.fasta" \
        --results_table "${BATS_TEST_TMPDIR}/out.tsv" \
        --primer_f "GTACACACCGCCCGTCG" --primer_r "CGCCTSCSCTTANTDATATGC"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"'slurm_account' is required on this cluster"* ]]
    # Actionable: it names both ways to supply one.
    [[ "${output}" == *"--slurm_account"* ]]
    [[ "${output}" == *"site.config"* ]]
}

@test "CLU-09d a site that does not require an account runs without one" {
    # Only abims sets require_slurm_account; the others must not inherit it.
    local site
    for site in genotoul ifb_core meso saga ; do
        run flat "${site}"
        [[ "${output}" != *"params.require_slurm_account = true"* ]] || {
            echo "${site} unexpectedly requires an account"; return 1
        }
    done
}
