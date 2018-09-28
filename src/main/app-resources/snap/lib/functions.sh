#!/bin/bash

set -x

# define the exit codes
SUCCESS=0
ERR_NO_URL=5
ERR_NO_MASTER=8
ERR_NO_SLAVE=9
ERR_NO_S1_MASTER_MTD=10
ERR_NO_S1_SLAVE_MTD=12
ERR_SNAP=15
ERR_COMPRESS=20
ERR_GDAL=25
ERR_PUBLISH=40

node="snap"

# add a trap to exit gracefully
function cleanExit ()
{
  local retval=$?
  local msg=""
  case "${retval}" in
    ${SUCCESS}) msg="Processing successfully concluded";;
    ${ERR_NO_URL}) msg="The Sentinel-1 product online resource could not be resolved";;
    ${ERR_NO_PRD}) msg="The Sentinel-1  product could not be retrieved";;
    ${ERR_JAVA}) msg="SatCen app failed to process";;
    ${ERR_GDAL}) msg="GDAL failed to convert result to tif";;
    ${ERR_COMPRESS}) msg="Failed to compress results";;
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
    wkt="$( ciop-getparam wkt )"
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
        [[ -z ${local_s1_prd} ]] && return ${ERR_NO_SLAVE}

        [[ $i == 0 ]] && {
        
            master_identifier="$( opensearch-client ${prd} identifier )"
            start_date="$( opensearch-client ${prd} startdate )"
            wkt_prd="$( opensearch-client ${prd} wkt )"
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
    /opt/satcen-mtc/bin/mtc ${algorithm} \
                            ${TMPDIR} \
                            ${master_identifier} \
                            "${wkt}" 1>&2 || return ${ERR_JAVA}


    for s1 in ${s1_local[@]}
    do 
        ciop-log "INFO" "Delete ${s1}"
        rm -fr ${s1}
    done

    ciop-log "INFO" "(6 of ${num_steps}) Compress results"  
    tar -C ${TMPDIR} -czf ${TMPDIR}/${algorithm}.tgz MTC SLC_STACK
    ciop-publish -m ${TMPDIR}/${algorithm}.tgz || return ${ERR_PUBLISH}  
 
    # .properties 
    echo "title=${master_identifier}_${slave_identifier}" > ${TMPDIR}/${algorithm}.properties
    echo "date=${start_date}/${end_date}" >> ${TMPDIR}/${algorithm}.properties
    echo "geometry=${wkt_prd}" >> ${TMPDIR}/${algorithm}.properties

    ciop-publish -m ${TMPDIR}/${algorithm}.properties

    # clean-up
    ciop-log "INFO" "(8 of ${num_steps}) Clean up" 
    rm -fr ${algorithm}.tgz
    rm -fr MTC
    rm -fr SLC_STACK
  
}
