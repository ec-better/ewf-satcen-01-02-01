#!/bin/bash

# define the exit codes
SUCCESS=0
ERR_NO_URL=5
ERR_NO_LOCAL_PRD=8
ERR_JAVA=9
ERR_PUBLISH=40

node="satcen-mtc"

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
    algorithm=$( ciop-getparam algorithm )
  
    cd ${TMPDIR}

    num_steps=8

    
    i=0
    for prd in ${s1_pair}
    do
        ciop-log "INFO" "Retrieve ${prd}"
        online_resource="$( opensearch-client ${prd} enclosure )"
        [[ -z ${online_resource} ]] && return ${ERR_NO_URL}

        local_s1_prd="$( ciop-copy -U -o ${TMPDIR} ${online_resource} )"
        [[ -z ${local_s1_prd} ]] && return ${ERR_NO_LOCAL_PRD}

        [[ $i == 0 ]] && {
        
            master_identifier="$( opensearch-client ${prd} identifier )"
            start_date="$( opensearch-client ${prd} startdate )"

        } || {

            slave_identifier="$( opensearch-client ${prd} identifier )"
            end_date="$( opensearch-client ${prd} enddate )"
        }
  
        ciop-log "INFO" "Adding ${local_s1_prd}"  
        s1_local[${i}]=${local_s1_prd}

       ((i++))
    done

    # invoke satcen JAVA app
    ciop-log "INFO" "Invoke SATCEN application"
    timeout 1h bash -c "/opt/satcen-mtc/bin/mtc ${algorithm} ${TMPDIR} ${master_identifier} \"${crop_wkt}\"" 1>&2 

    [ $? != 0 ] && return ${ERR_JAVA}

    for s1 in ${s1_local[@]}
    do 
        ciop-log "INFO" "Delete ${s1}"
        rm -fr ${s1}
    done

    output_name=${master_identifier}_${slave_identifier}_${algorithm} 
 
    ciop-log "INFO" "(6 of ${num_steps}) Compress results"  
    tar -C ${TMPDIR} -czf ${TMPDIR}/${output_name}.tgz MTC SLC_STACK
    ciop-publish -m ${TMPDIR}/${output_name}.tgz || return ${ERR_PUBLISH}  
 
    # .properties 
    echo "title=${master_identifier}_${slave_identifier}" > ${TMPDIR}/${output_name}.properties
    echo "date=${start_date}/${end_date}" >> ${TMPDIR}/${output_name}.properties
    echo "geometry=${crop_wkt}" >> ${TMPDIR}/${output_name}.properties

    ciop-publish -m ${TMPDIR}/${output_name}.properties

    # clean-up
    ciop-log "INFO" "(8 of ${num_steps}) Clean up" 
    rm -fr ${output_name}.tgz
    rm -fr MTC
    rm -fr SLC_STACK
  
}
