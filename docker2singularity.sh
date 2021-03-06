#! /bin/bash
#
# docker2singularity.sh will convert a docker image into a singularity
# Must be run with sudo to use docker commands (eg aufs)
#
# NOTES:
# If the docker image uses both ENTRYPOINT and CMD the latter will be ignored
#
# KNOWN ISSUES:
# Currently ENTRYPOINTs and CMDs with commas in the arguments are not supported
#
# USAGE: docker2singularity.sh ubuntu:14.04
#
# Optional: You can override the list of mountpoints created in the container 
# by setting MOUNTPOINTS environment variable

MOUNTPOINTS="${_MOUNTPOINTS:-/oasis /projects /scratch /local-scratch /work /home1 /corral-repl /beegfs /share/PI /extra}"

set -o errexit
set -o nounset

if [ -z $1 ]; then
    echo "no Docker image specified!";
    exit 1;
else
    image=$1
fi


################################################################################
### CONTAINER RUNNING ID #######################################################
################################################################################

runningid=`docker run -d $image tail -f /dev/null`

# Full id looks like
# sha256:d59bdb51bb5c4fb7b2c8d90ae445e0720c169c553bcf553f67cb9dd208a4ec15

# Take the first 12 characters to get id of container
container_id=`echo ${runningid} | cut -c1-12`

# Network address, if needed
network_address=`docker inspect --format="{{.NetworkSettings.IPAddress}}" $container_id`


################################################################################
### IMAGE NAME #################################################################
################################################################################

image_name=`docker inspect --format="{{.Config.Image}}" $container_id`

# using bash substitution
# removing special chars [perhaps echo + sed would be better for other chars]
image_name=${image_name//\//_}
image_name=${image_name/:/_}

# following is the date of the container, not the docker image.
creation_date=`docker inspect --format="{{.Created}}" $image`

################################################################################
### IMAGE SIZE #################################################################
################################################################################

size=`docker inspect --format="{{.Size}}" $image`
# convert size in MB (it seems too small for singularity containers ...?). Add 1MB to round up (minimum).
size=`echo $(($size/1000000+1))`

# for small containers (less than 7MB), double the size
# otherwise, add half the container size
if [ "$size" -lt "7" ]; then
    size=`echo $(($size*2))`
else
    # Docker container quay.io/biocontainers/rust:1.14.0--0 required 1.66*size, so rounding up here
    size=`echo $(($size+$size*7/10))`
fi

echo "Size: $size MB for the singularity container"

################################################################################
### IMAGE CREATION #############################################################
################################################################################
TMPDIR=$(mktemp -u -d)
mkdir -p $TMPDIR

creation_date=`echo ${creation_date} | cut -c1-10`
new_container_name=/tmp/$image_name-$creation_date-$container_id.img
echo "(1/9) Creating an empty image..."
singularity create -s $size $new_container_name
echo "(2/9) Importing filesystem..."
docker export $container_id | singularity import $new_container_name
docker inspect $container_id >> $TMPDIR/singularity.json
singularity copy $new_container_name $TMPDIR/singularity.json /

# Bootstrap the image to set up scripts for environment setup
echo "(3/9) Bootstrapping..."
singularity bootstrap $new_container_name
chmod a+rw -R $TMPDIR

################################################################################
### SINGULARITY RUN SCRIPT #####################################################
################################################################################
echo "(4/9) Adding run script..."
CMD=$(docker inspect --format='{{json .Config.Cmd}}' $image)
if [[ $CMD != [* ]]; then
    if [[ $CMD != "null" ]]; then
        CMD="/bin/sh -c "$CMD
    fi
fi
# Remove quotes, commas, and braces
CMD=`echo "${CMD//\"/}" | sed 's/\[//g' | sed 's/\]//g' | sed 's/,//g'`

ENTRYPOINT=$(docker inspect --format='{{json .Config.Entrypoint}}' $image)
if [[ $ENTRYPOINT != [* ]]; then
    if [[ $ENTRYPOINT != "null" ]]; then
        ENTRYPOINT="/bin/sh -c "$ENTRYPOINT
    fi
fi

# Remove quotes, commas, and braces
ENTRYPOINT=`echo "${ENTRYPOINT//\"/}" | sed 's/\[//g' | sed 's/\]//g' | sed 's/,/ /g'`

echo '#!/bin/sh' > $TMPDIR/singularity
if [[ $ENTRYPOINT != "null" ]]; then
    echo $ENTRYPOINT '$@' >> $TMPDIR/singularity;
else
    if [[ $CMD != "null" ]]; then
        echo $CMD '$@' >> $TMPDIR/singularity;
    fi
fi

chmod +x $TMPDIR/singularity
singularity copy $new_container_name $TMPDIR/singularity /

################################################################################
### SINGULARITY ENVIRONMENT ####################################################
################################################################################
echo "(5/9) Setting ENV variables..."
# some containers have env at '/bin/env', not '/usr/bin/env', so use OR to get environment
docker run --rm --entrypoint="/usr/bin/env" $image > $TMPDIR/docker_environment 2> /dev/null || docker run --rm --entrypoint="/bin/env" $image > $TMPDIR/docker_environment

# don't include HOME and HOSTNAME - they mess with local config
sed -i '/^HOME/d' $TMPDIR/docker_environment
sed -i '/^HOSTNAME/d' $TMPDIR/docker_environment
sed -i 's/^/export /' $TMPDIR/docker_environment
singularity copy $new_container_name $TMPDIR/docker_environment /
singularity exec --writable $new_container_name /bin/sh -c "echo '. /docker_environment' >> /environment"
rm -rf $TMPDIR

################################################################################
### Permissions ################################################################
################################################################################
echo "(6/9) Adding mount points..."
echo "      ${MOUNTPOINTS}"
singularity exec --writable --contain $new_container_name /bin/sh -c "mkdir -p ${MOUNTPOINTS}"

# making sure that any user can read and execute everything in the container
echo "(7/9) Fixing permissions..."
singularity exec --writable --contain $new_container_name /bin/sh -c "find /* -maxdepth 0 -not -path '/dev*' -not -path '/proc*' -not -path '/sys*' -exec chmod a+r -R '{}' \;"

# Ubuntu generates benign warnings with the find command.  Squelch these errors if we are on Ubuntu
buildname=$(singularity exec --contain $new_container_name /bin/sh -c "head -n 1 /etc/issue")
if [[ $buildname =~ Ubuntu|Debian ]]  ; then
    singularity exec --writable --contain $new_container_name /bin/sh -c "find / -ignore_readdir_race \( -type f -o -type d \) -perm -u+x ! -perm -o+x ! -path '/dev*' ! -path '/proc*' ! -path '/sys*' -exec chmod a+x '{}' \; 2> /dev/null"
else
    # use syntax compatible with BusyBox find
    singularity exec --writable --contain $new_container_name /bin/sh -c "find / \( -type f -o -type d \) -perm -u+x ! -perm -o+x ! -path '/dev*' ! -path '/proc*' ! -path '/sys*' -exec chmod a+x '{}' \;"
fi

echo "(8/9) Stopping and removing the container..."
docker stop -t 0 $container_id
docker rm $container_id

echo "(9/9) Moving the image to the output folder..."
rsync --info=progress2 /tmp/$image_name-$creation_date-$container_id.img /output/
