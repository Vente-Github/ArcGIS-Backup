#!/bin/bash

while getopts t:f:p option
do
	case "${option}" in
		t) TYPE=${OPTARG};;
		f) FILE_CONFIG=${OPTARG};;
		p) PREFIX=${OPTARG};;
	esac
done

# Extrae las variables de entorno para generar el fichero de configuración
WGD_PREFIX="${PREFIX:-WGD_}"
env_vars=($(env | grep "${WGD_PREFIX}"))

env_vars+=("${WGD_PREFIX}SHARED_LOCATION=${BACKUP_LOCATION_ROOT}\\\\${TYPE}\\\\temporal")
env_vars+=("${WGD_PREFIX}BACKUP_LOCATION=${BACKUP_LOCATION_ROOT}\\\\${TYPE}\\\\")
env_vars+=("WGD_BACKUP_RESTORE_MODE=${TYPE}")

# Crea el fichero de configuración
for var in "${env_vars[@]}"
do
	IFS='=' read -ra ADDR <<< "${var}"
	name=$(echo "${ADDR[0]}" | sed "s/^${WGD_PREFIX}//g")
	echo "${name} = ${ADDR[1]}" >> "${FILE_CONFIG}"
done

if [ -f "${FILE_CONFIG}" ];
then
	echo -e "${INFO_COLOR}The webgisdr.properties is successfully created${NULL_COLOR}"
else
	echo -e "${FAIL_COLOR}The configuration file is not created${NULL_COLOR}"
fi