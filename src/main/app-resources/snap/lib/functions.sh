#!/bin/bash

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
    ${ERR_NO_MASTER}) msg="The Sentinel-1 master product could not be retrieved";;
    ${ERR_NO_SLAVE}) msg="The Sentinel-1 slave product could not be retrieved";;
    ${ERR_NO_S1_MASTER_MTD}) msg="Could not find Sentinel-1 master product metadata file";;
    ${ERR_NO_S1_SLAVE_MTD}) msg="Could not find Sentinel-1 slave product metadata file";;
    ${ERR_SNAP}) msg="SNAP GPT failed";;
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

  SNAP_REQUEST=${_CIOP_APPLICATION_PATH}/${node}/etc/snap_request.xml

  params=$( xmlstarlet sel -T -t -m "//parameters/*" -v . -n ${SNAP_REQUEST} | grep '${' | grep -v '${in1}' | grep -v '${in2}' | grep -v '${out}' | sed 's/\${//' | sed 's/}//' )

  touch ${TMPDIR}/snap.params

  for param in ${params} 
  do 
    value="$( ciop-getparam $param)"
    [[ ! -z "${value}" ]] && echo "$param=${value}" >> ${TMPDIR}/snap.params
  done
  
  ciop-publish -m ${TMPDIR}/snap.params

  export SNAP_HOME=/opt/snap6
  export PATH=${SNAP_HOME}/bin:${PATH}
  export SNAP_VERSION=$( cat ${SNAP_HOME}/VERSION.txt )

  export export PATH=/opt/anaconda/bin:${PATH}

  return 0
  
}

function main() {

  set_env || exit $?
  
  slave=$( cat /dev/stdin ) 
  master=$( ciop-getparam master )

  cd ${TMPDIR}

  num_steps=8

  ciop-log "INFO" "(1 of ${num_steps}) Resolve Sentinel-1 master online resource"
  online_resource="$( opensearch-client ${master} enclosure )"
  [[ -z ${online_resource} ]] && return ${ERR_NO_URL}

  ciop-log "INFO" "(2 of ${num_steps}) Retrieve Sentinel-1 master product from ${online_resource}"
  local_master="$( ciop-copy -o ${TMPDIR} ${online_resource} )"
  [[ -z ${local_master} ]] && return ${ERR_NO_MASTER} 

  # find MTD file in ${local_master}
  s1_master_mtd="$( find ${local_master} -name "manifest.safe" )"

  [[ -z "${s1_master_mtd}" ]] && return ${ERR_NO_S1_MASTER_MTD}

  s1_local[0]=${local_master}
  s1_mtd[0]=${s1_master_mtd}
 
  ciop-log "INFO" "(3 of ${num_steps}) Resolve Sentinel-1 slave online resource"
  online_resource="$( opensearch-client ${slave} enclosure )"
  [[ -z ${online_resource} ]] && return ${ERR_NO_URL}

  ciop-log "INFO" "(4 of ${num_steps}) Retrieve Sentinel-1 slave product from ${online_resource}"
  local_slave="$( ciop-copy -o ${TMPDIR} ${online_resource} )"
  [[ -z ${local_slave} ]] && return ${ERR_NO_SLAVE}

  s1_slave_mtd="$( find ${local_slave} -name "manifest.safe" )"
  [[ -z "${s1_slave_mtd}" ]] && return ${ERR_NO_S1_SLAVE_MTD}
 
  ciop-log "INFO" "Adding ${s1_slave_mtd}"  
  s1_local[1]=${local_slave}
  s1_mtd[1]=${s1_slave_mtd}
 
  out=${local_master}_result

  ciop-log "INFO" "(5 of ${num_steps}) Invoke SNAP GPT"

  gpt -x \
    ${SNAP_REQUEST} \
    -Pin1=${s1_mtd[0]} \
    -Pin2=${s1_mtd[1]} \
    -Pout=${out} \
    -p ${TMPDIR}/snap.params 1>&2 || return ${ERR_SNAP} 

  for s1 in ${s1_local[@]}
  do 
    ciop-log "INFO" "Delete ${s1}"
    rm -fr ${s1}
  done

  ciop-log "INFO" "(6 of ${num_steps}) Compress results"  
  tar -C ${TMPDIR} -czf ${out}.tgz $( basename ${out}).dim $( basename ${out}).data || return ${ERR_COMPRESS}
  ciop-publish -m ${out}.tgz || return ${ERR_PUBLISH}  
 
  rm -fr ${out}.tgz
 
  ciop-log "INFO" "(7 of ${num_steps}) Convert to geotiff and PNG image formats"
  
  # Convert to GeoTIFF
  for img in $( find ${out}.data -name '*.img' )
  do 
    target=${out}_$( basename ${img} | sed 's/.img//' )
    
    gdal_translate ${img} ${target}.tif || return ${ERR_GDAL}
    ciop-publish -m ${target}.tif || return ${ERR_PUBLISH}
  
    gdal_translate -of PNG -a_nodata 0 -scale 0 1 0 255 ${target}.tif ${target}.png || return ${ERR_GDAL_QL}
    ciop-publish -m ${target}.png || return ${ERR_PUBLISH}
  
    listgeo -tfw ${target}.tif 
    [[ -e ${target}.tfw ]] && {
      mv ${target}.tfw ${target}.pngw
      ciop-publish -m ${target}.pngw || return ${ERR_PUBLISH}
      rm -f ${target}.pngw  
    }

    rm -fr ${target}.tif ${target}.png 
 
  done
  
  ciop-log "INFO" "(8 of ${num_steps}) Clean up" 
  # clean-up
  rm -fr ${out}*
  
}
