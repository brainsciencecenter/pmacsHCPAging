#!/bin/bash

get_batch_options() {
    local arguments=("$@")

    unset command_line_specified_study_folder
    unset command_line_specified_subj
    unset command_line_gdcoeffs

    local index=0
    local numArgs=${#arguments[@]}
    local argument

    while [ ${index} -lt ${numArgs} ]; do
        argument=${arguments[index]}

        case ${argument} in
            --StudyFolder=*)
                command_line_specified_study_folder=${argument#*=}
                index=$(( index + 1 ))
                ;;
            --Subject=*)
                command_line_specified_subj=${argument#*=}
                index=$(( index + 1 ))
                ;;
            --GDCoeffs)
                command_line_gdcoeffs=${argument#*=}
                index=$(( index + 1 ))
                ;;
	    *)
		echo ""
		echo "ERROR: Unrecognized Option: ${argument}"
		echo ""
		exit 1
		;;
        esac
    done
}

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 --StudyFolder=folder --Subject=\"subjectID [subjectID]...\" [--GDCoeffs=/path/to/gdc.coeff]"
    exit 1
fi

get_batch_options "$@"

EnvironmentScript="${HCPPIPEDIR}/SetUpHCPPipeline.sh" #Pipeline environment script
Gdcoeffs="NONE"

if [ -n "${command_line_specified_study_folder}" ]; then
    StudyFolder="${command_line_specified_study_folder}"
else
    echo "Study folder is required"
    exit 1
fi

if [ -n "${command_line_specified_subj}" ]; then
    Subjlist="${command_line_specified_subj}"
else
    echo "Subject list is required"
fi

if [ -n "${command_line_gdcoeffs}" ]; then
    Gdcoeffs="${command_line_gdcoeffs}"
fi


# Requirements for this script
#  installed versions of: FSL, FreeSurfer, Connectome Workbench (wb_command), gradunwarp (HCP version)
#  environment: HCPPIPEDIR, FSLDIR, FREESURFER_HOME, CARET7DIR, PATH for gradient_unwarp.py

#Set up pipeline environment variables and software
source ${EnvironmentScript}

# Log the originating call
echo "$@"

#Assume that submission nodes have OPENMP enabled (needed for eddy - at least 8 cores suggested for HCP data)
#if [ X$SGE_ROOT != X ] ; then
#    QUEUE="-q verylong.q"
    QUEUE=""
#fi

PRINTCOM=""


########################################## INPUTS ########################################## 

#Scripts called by this script do assume they run on the outputs of the PreFreeSurfer Pipeline,
#which is a prerequisite for this pipeline

#Scripts called by this script do NOT assume anything about the form of the input names or paths.
#This batch script assumes the HCP raw data naming convention, e.g.

#	${StudyFolder}/${Subject}/unprocessed/3T/Diffusion/${SubjectID}_3T_DWI_dir95_RL.nii.gz
#	${StudyFolder}/${Subject}/unprocessed/3T/Diffusion/${SubjectID}_3T_DWI_dir96_RL.nii.gz
#	${StudyFolder}/${Subject}/unprocessed/3T/Diffusion/${SubjectID}_3T_DWI_dir97_RL.nii.gz
#	${StudyFolder}/${Subject}/unprocessed/3T/Diffusion/${SubjectID}_3T_DWI_dir95_LR.nii.gz
#	${StudyFolder}/${Subject}/unprocessed/3T/Diffusion/${SubjectID}_3T_DWI_dir96_LR.nii.gz
#	${StudyFolder}/${Subject}/unprocessed/3T/Diffusion/${SubjectID}_3T_DWI_dir97_LR.nii.gz

#Change Scan Settings: Echo Spacing and PEDir to match your images
#These are set to match the HCP Protocol by default

#If using gradient distortion correction, use the coefficents from your scanner
#The HCP gradient distortion coefficents are only available through Siemens
#Gradient distortion in standard scanners like the Trio is much less than for the HCP Skyra.

######################################### DO WORK ##########################################

for Subject in $Subjlist ; do
  echo $Subject

  #Input Variables
  SubjectID="$Subject" #Subject ID Name
  RawDataDir="$StudyFolder/$SubjectID/unprocessed/3T/Diffusion" #Folder where unprocessed diffusion data are

  # PosData is a list of files (separated by ‘@‘ symbol) having the same phase encoding (PE) direction
  # and polarity. Similarly for NegData, which must have the opposite PE polarity of PosData.
  # The PosData files will come first in the merged data file that forms the input to ‘eddy’.
  # The particular PE polarity assigned to PosData/NegData is not relevant; the distortion and eddy
  # current correction will be accurate either way.
  #
  # NOTE that PosData defines the reference space in 'topup' and 'eddy' AND it is assumed that
  # each scan series begins with a b=0 acquisition, so that the reference space in both
  # 'topup' and 'eddy' will be defined by the same (initial b=0) volume.
  #
  # On Siemens scanners, we typically use 'R>>L' ("RL") as the 'positive' direction for left-right
  # PE data, and 'P>>A' ("PA") as the 'positive' direction for anterior-posterior PE data.
  # And conversely, "LR" and "AP" are then the 'negative' direction data.
  # However, see preceding comment that PosData defines the reference space; so if you want the
  # first temporally acquired volume to define the reference space, then that series needs to be
  # the first listed series in PosData.
  #
  # Note that only volumes (gradient directions) that have matched Pos/Neg pairs are ultimately
  # propagated to the final output, *and* these pairs will be averaged to yield a single
  # volume per pair. This reduces file size by 2x (and thence speeds subsequent processing) and
  # avoids having volumes with different SNR features/ residual distortions.
  # [This behavior can be changed through the hard-coded 'CombineDataFlag' variable in the
  # DiffPreprocPipeline_PostEddy.sh script if necessary].

  PosData="${RawDataDir}/${SubjectID}_dMRI_dir98_PA.nii.gz@${RawDataDir}/${SubjectID}_dMRI_dir99_PA.nii.gz"
  NegData="${RawDataDir}/${SubjectID}_dMRI_dir98_AP.nii.gz@${RawDataDir}/${SubjectID}_dMRI_dir99_AP.nii.gz"

  # "Effective" Echo Spacing of dMRI image (specified in *msec* for the dMRI processing)
  # EchoSpacing = 1/(BWPPPE * ReconMatrixPE)
  #   where BWPPPE is the "BandwidthPerPixelPhaseEncode" = DICOM field (0019,1028) for Siemens, and
  #   ReconMatrixPE = size of the reconstructed image in the PE dimension
  # In-plane acceleration, phase oversampling, phase resolution, phase field-of-view, and interpolation
  # all potentially need to be accounted for (which they are in Siemen's reported BWPPPE)
  EchoSpacing=0.6899980000

  PEdir=2 #Use 1 for Left-Right Phase Encoding, 2 for Anterior-Posterior

  ${HCPPIPEDIR}/DiffusionPreprocessing/DiffPreprocPipeline.sh \
      --posData="${PosData}" --negData="${NegData}" \
      --path="${StudyFolder}" --subject="${SubjectID}" \
      --echospacing="${EchoSpacing}" --PEdir=${PEdir} \
      --gdcoeffs="${Gdcoeffs}" \
      --printcom=$PRINTCOM

done
