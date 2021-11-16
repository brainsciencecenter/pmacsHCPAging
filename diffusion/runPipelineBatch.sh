#!/bin/bash

scriptPath=$(readlink -f "$0")
scriptDir=$(dirname "${scriptPath}")

function usage() {
  echo "Usage:
  $0 [-h] [-B src:dest,...,src:dest] \\
     -i /path/to/data -s session [-g [gdcoeffs]] [-p] [-- other args to run script]

  Use the -h option to see detailed help.

"
}

function help() {
    usage
  echo "
  This script handles various configuration options and bind points needed to run containerized
  HCP Pipelines on the cluster. Requires singularity.

  This is a wrapper to modified versions of the HCP Pipeline example batch scripts, modified to run on the
  BSC cluster and expecting data from the HCP-Aging project.

Use absolute paths, as these have to be mounted in the container. Participant data should be organized
in HCP format.

Required args:

  -i /path/to/data
    Input directory on the local file system. Will be bound to /data/input inside the container and passed
    to the HCP scripts as the StudyFolder.

  -s session
    Imaging session to process, under /path/to/data/session. Will be passed to the HCP script as the Subject.

Options:

  -B src:dest[,src:dest,...,src:dest]
     Use this to add mount points to bind inside the container, that aren't handled by other options.
     'src' is an absolute path on the local file system and 'dest' is an absolute path inside the container.
     Several bind points are always defined inside the container including \$HOME, \$PWD (where script is
     executed from), and /tmp (more on this below). Additionally, BIDS input (-i), output (-o), and FreeSurfer
     output dirs (-f) are bound automatically.

  -g /path/to/gdcoeffs
     Gradient distortion coefficients, on the local file system.

  -p
     Print the singularity call, rather than running it. The command is always printed for logging purposes,
     but if you just want a command to run interactively, use this option.

  -h
     Prints this help message.


*** Multi-threading and memory use ***

The number of available cores (numProcs) is derived from the environment variable \${LSB_DJOB_NUMPROC},
which is the number of slots reserved in the call to bsub.

"
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi


gdCoeffs="NONE"
printOnly=0
# HCP talks about "Subject" for processing, but it usually organizes data as Subject_Session
# This variable should contain Subject_Session
session=""
studyFolder=""
userBindPoints=""

while getopts "B:g:i:s:h" opt; do
  case $opt in
    B) userBindPoints=$OPTARG;;
    g) gdCoeffs=$OPTARG;;
    h) help; exit 1;;
    i) studyFolder=$OPTARG;;
    p) printOnly=1;;
    s) session=$OPTARG;;
    \?) echo "Unknown option $OPTARG"; exit 2;;
    :) echo "Option $OPTARG requires an argument"; exit 2;;
  esac
done

shift $((OPTIND-1))

# Script to run in container image
pipelineScript="${scriptDir}/DiffusionPreprocessingBatch.sh"
image="/project/detre_1/containers/hcppipelines-4.3.0-3.sif"

if [[ ! -f $image ]]; then
  echo "Cannot find requested container $image"
  exit 1
fi

if [[ ! -d "${studyFolder}/${session}/unprocessed/3T/Diffusion" ]]; then
  echo "Cannot find diffusion data in ${studyFolder}/${session}/unprocessed/3T/Diffusion"
  exit 1
fi

if [[ ! -d "${studyFolder}/${session}/T1w" ]]; then
  echo "Structural preprocessing must be run before diffusion, cannot find T1w processing in in ${studyFolder}/${session}"
  exit 1
fi

if [[ -z "${LSB_JOBID}" ]]; then
  echo "This script must be run within a (batch or interactive) LSF job"
  exit 1
fi

sngl=$( which singularity ) ||
    ( echo "Cannot find singularity executable. Try module load singularity/3.8.3"; exit 1 )

if [[ ! -d "$subjectsDir" ]]; then
  echo "Cannot find input directory $subjectsDir"
  exit 1
fi


# Set a job-specific temp dir
if [[ ! -d "$SINGULARITY_TMPDIR" ]]; then
  echo "Setting SINGULARITY_TMPDIR=/scratch"
  export SINGULARITY_TMPDIR=/scratch
fi

jobTmpDir=$( mktemp -d -p ${SINGULARITY_TMPDIR} hcpAgingDMRI.${LSB_JOBID}.XXXXXXXX.tmpdir )

if [[ ! -d "$jobTmpDir" ]]; then
  echo "Could not create job temp dir ${jobTmpDir}"
  exit 1
fi

# Not all software uses TMPDIR
# module DEV/singularity sets SINGULARITYENV_TMPDIR=/scratch
# We will make a temp dir there and bind to /tmp in the container
export SINGULARITYENV_TMPDIR="/tmp"

# singularity args
singularityArgs="--cleanenv \
  --no-home \
  -B ${jobTmpDir}:/tmp \
  -B ${studyFolder}:/data/input"

# Args we pass to the pipeline script
pipelineScriptArgs="--StudyFolder=/data/input --Subject=${session} --NumCPUs ${LSB_DJOB_NUMPROC}"

if [[ -f "$gdCoeffs" ]]; then
  singularityArgs="$singularityArgs \
  -B ${gdCoeffs}:/metadata/gdcoeffs/coeff.grad"
  pipelineScriptArgs="$pipelineScriptArgs \
  --GDCoeffs /metadata/gdcoeffs/coeff.grad"
fi

if [[ -n "$userBindPoints" ]]; then
  singularityArgs="$singularityArgs \
  -B $userBindPoints"
fi

pipelineUserArgs="$*"

echo "
--- args passed through to pipeline ---
$*
---
"

echo "
--- Script options ---
container image        : $image
Subject directory      : $subjectDir
Sessions               : $session
User bind points       : $userBindPoints
Number of cores        : $numProcs
---
"

echo "
--- Container details ---"
singularity inspect $image
echo "---
"

cmd="singularity run \
  $singularityArgs \
  $image \
  $pipelineScript \
  $pipelineScriptArgs \
  $pipelineUserArgs"

echo "
--- pipeline command ---
$cmd
---
"

if [[ $printOnly -eq 1 ]]; then
  echo "Script run in print only mode, exiting now"
  exit 0
fi

$cmd
singExit=$?

if [[ $singExit -ne 0 ]]; then
  echo "Container exited with non-zero code $singExit"
fi

# Set to 0 to leave tmp output for debuggings
cleanup=1

if [[ $cleanup -eq 1 ]]; then
  echo "Removing temp dir ${jobTmpDir}"
  rm -rf ${jobTmpDir}
else
  echo "Leaving temp dir ${jobTmpDir}"
fi

exit $singExit