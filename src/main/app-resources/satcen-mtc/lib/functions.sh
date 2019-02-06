#!/bin/bash

# define the exit codes
SUCCESS=0
ERR_NO_URL=5
ERR_NO_LOCAL_PRD=8
ERR_JAVA=9
ERR_TIMEOUT=10
ERR_PUBLISH=40
TIMEOUT=180

node="satcen-mtc"

### trap error function only for runtime errors###
abort()
{   
    res=$?
    ciop-log "ERROR" "Unexpected error occurred. Exiting"
    ciop-log "INFO" "trapped code: $res"
    return ${ERR_JAVA}
}

trap 'abort' ABRT TERM INT
set -e

# add a trap to exit gracefully
function cleanExit ()
{
  local retval=$?
  local msg=""
  case "${retval}" in
    ${SUCCESS}) msg="Processing successfully concluded";;
    ${ERR_NO_URL}) msg="The Sentinel-1 product online resource could not be resolved";;
    ${ERR_NO_LOCAL_PRD}) msg="The Sentinel-1 product could not be retrieved";;
    ${ERR_JAVA}) msg="SatCen app failed to process";;
    ${ERR_TIMEOUT}) msg="SatCen app TIMEOUT reached (${TIMEOUT} minutes)";;
    ${ERR_PUBLISH}) msg="Failed to publish the results";;
    *) msg="Unknown error";;
 esac

  [ "${retval}" != "0" ] && ciop-log "ERROR" "Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"
  exit ${retval}
}

trap cleanExit EXIT

function set_env() {

    export PATH=/opt/satcen-mtc/bin:${PATH}

    return 0
  
}


function main() {

    set_env || exit $?
  
    s1_pair=$( cat /dev/stdin )
    crop_wkt="$( ciop-getparam crop_wkt )"
    algorithm="$( ciop-getparam algorithm )"
  
    cd ${TMPDIR}

    num_steps=9

    
    i=0
    for prd in ${s1_pair}
    do
        ciop-log "INFO" "Retrieve ${prd}"
        IFS=', ' read -r -a search <<< "$( opensearch-client ${prd} enclosure,identifier,startdate,enddate )"
        online_resource=${search[0]}
        identifier=${search[1]}
        start_date=${search[2]}
        end_date=${search[3]}
        
        [[ -z ${online_resource} ]] && return ${ERR_NO_URL}

        local_s1_prd="$( ciop-copy -U -o ${TMPDIR} ${online_resource} )"
        [[ -z ${local_s1_prd} ]] && return ${ERR_NO_LOCAL_PRD}

        [[ $i == 0 ]] && {
        
            master_identifier=${identifier}
            
        } || {

            slave_identifier=${identifier}
        }
  
        ciop-log "INFO" "Adding ${local_s1_prd}"  
        s1_local[${i}]=${local_s1_prd}

       ((i++))
    done

    # invoke satcen JAVA app
    ciop-log "INFO" "Invoke SATCEN application"
    
    timeout ${TIMEOUT}m bash -c "/opt/satcen-mtc/bin/mtc ${algorithm} ${TMPDIR} ${master_identifier} \"${crop_wkt}\"" 1>&2 
    res=$?
    
    [[ $res -eq 124 ]] && return ${ERR_TIMEOUT}
    [ $res != 0 ] && return ${ERR_JAVA}

    for s1 in ${s1_local[@]}
    do 
        ciop-log "INFO" "Delete ${s1}"
        rm -fr ${s1}
    done

    output_name=${master_identifier}_${slave_identifier}
    slc_out_name="SLC_${output_name}"
    mtc_out_name="MTC_${output_name}"
    
    ciop-log "INFO" "(6 of ${num_steps}) Create and publish results geotiff and related metadata"
    cp ${_CIOP_APPLICATION_PATH}/satcen-mtc/etc/graph_template.xml ${TMPDIR}/graph_template.xml

    for f in $(ls SLC_STACK/*.data/*.img)
    do 
        inputBand=$(basename ${f})
        inputBand=${inputBand%.*}
        sourceFile=$(ls SLC_STACK/*.dim)
        /opt/snap6/bin/gpt ${TMPDIR}/graph_template.xml -PsourceFile=${sourceFile}  -PtargetbasePath=${TMPDIR}/${slc_out_name} -PsourceBand=${inputBand}
        create_metadata "${slc_out_name}_${inputBand}" "${master_identifier}" "${slave_identifier}" "${crop_wkt}" "${start_date}" "${end_date}"
        echo "title=${slc_out_name}_${inputBand}" > ${TMPDIR}/${slc_out_name}_${inputBand}.properties
        echo "date=${start_date}/${end_date}" >> ${TMPDIR}/${slc_out_name}_${inputBand}.properties
        echo "geometry=${crop_wkt}" >> ${TMPDIR}/${slc_out_name}_${inputBand}.properties
        ciop-publish -m ${TMPDIR}/${slc_out_name}_${inputBand}.tif || return ${ERR_PUBLISH}
        ciop-publish -m ${TMPDIR}/${slc_out_name}_${inputBand}.properties || return ${ERR_PUBLISH}
        rm ${TMPDIR}/${slc_out_name}_${inputBand}.*
    done

    for f in $(ls MTC/*.data/*.img)
    do
        inputBand=$(basename ${f})
        inputBand=${inputBand%.*}
        sourceFile=$(ls MTC/*.dim)
        /opt/snap6/bin/gpt ${TMPDIR}/graph_template.xml -PsourceFile=${sourceFile}  -PtargetbasePath=${TMPDIR}/${mtc_out_name} -PsourceBand=${inputBand}
        echo "title=${mtc_out_name}_${inputBand}" > ${TMPDIR}/${mtc_out_name}_${inputBand}.properties
        echo "date=${start_date}/${end_date}" >> ${TMPDIR}/${mtc_out_name}_${inputBand}.properties
        echo "geometry=${crop_wkt}" >> ${TMPDIR}/${mtc_out_name}_${inputBand}.properties
        ciop-publish -m ${TMPDIR}/${mtc_out_name}_${inputBand}.tif || return ${ERR_PUBLISH}
        ciop-publish -m ${TMPDIR}/${mtc_out_name}_${inputBand}.properties || return ${ERR_PUBLISH}
        rm ${TMPDIR}/${mtc_out_name}_${inputBand}.*
    done
 
    ciop-log "INFO" "(7 of ${num_steps}) Compress dim results and create related metadata" 
    tar -C ${TMPDIR} -czf ${TMPDIR}/${output_name}.tgz MTC SLC_STACK

    # .properties 
    echo "title=${master_identifier}_${slave_identifier}" > ${TMPDIR}/${output_name}.properties
    echo "date=${start_date}/${end_date}" >> ${TMPDIR}/${output_name}.properties
    echo "geometry=${crop_wkt}" >> ${TMPDIR}/${output_name}.properties
    
    # publishing results
    ciop-log "INFO" "8 of ${num_steps}) Publish compressed results and metadata"

    ciop-publish -m ${TMPDIR}/${output_name}.tgz || return ${ERR_PUBLISH}
    ciop-publish -m ${TMPDIR}/${output_name}.properties

    
    # clean-up
    ciop-log "INFO" "(9 of ${num_steps}) Clean up" 
    rm -fr *${output_name}*
    rm -fr MTC
    rm -fr SLC_STACK
  
}
