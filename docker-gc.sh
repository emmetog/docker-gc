#!/usr/bin/env bash

set -o errexit

CONTAINERS_TO_PRUNE=""
CLEANUP_DANGLING_IMAGES=true
DRY_RUN=false
DOCKER=docker
IMAGES_TO_PRUNE=""
PID_DIR=/var/run
STATE_DIR=/var/lib/docker-gc
VERBOSE=false

for pid in $(pidof -s docker-gc); do
    if [[ $pid != $$ ]]; then
        echo "[$(date)] : docker-gc : Process is already running with PID $pid"
        exit 1
    fi
done

trap "rm -f -- '$PID_DIR/dockergc'" EXIT

echo $$ > $PID_DIR/dockergc



for i in "$@"
do
    case $i in
        -d|--dry-run)
            DRY_RUN=true
        ;;
        -v|--verbose)
            VERBOSE=true
        ;;
        --no-prune-dangling)
            CLEANUP_DANGLING_IMAGES=false
        ;;
        -c=*|--containers=*)
            CONTAINERS_TO_PRUNE="${i#*=}"
        ;;
        -i=*|--images=*)
            IMAGES_TO_PRUNE="${i#*=}"
        ;;
        *)
            echo "Docker garbage collection: remove unused containers and images."
            echo "Usage: ${0##*/} [--containers=\"\"] [--images=\"\"] [--no-prune-dangling] [--verbose] [--dry-run]"
            echo "   -c, --containers:      a regular expression to match the containers to prune."
            echo "   -i, --images:          a regular expression to match the images to prune."
            echo "   --no-prune-dangling:   don't prune dangling images."
            echo "   -d, --dry-run:         dry run: display what would get removed."
            echo "   -v, --verbose:         verbose output."
            exit 1
        ;;
    esac
    shift
done

echo "---------------------------------"
if [ "$CONTAINERS_TO_PRUNE" != "" ]; then
    echo "Will prune stopped containers that match the regex \"$CONTAINERS_TO_PRUNE\""
else
    echo "Will NOT prune any containers (no --containers specified)"
fi

if [ "$IMAGES_TO_PRUNE" != "" ]; then
    echo "Will prune unused images that match the regex \"$IMAGES_TO_PRUNE\""
else
    echo "Will NOT prune any images (no --images specified)"
fi

if [ $CLEANUP_DANGLING_IMAGES = true ]; then
    echo "Will prune dangling images"
else
    echo "Will NOT prune dangling images"
fi
echo "---------------------------------"

function calculate_images_to_reap() {

    if [ "$IMAGES_TO_PRUNE" == "" ]; then
        touch images.reap
        return
    fi

    $DOCKER images --no-trunc \
         | tail -n+2 \
         | sed 's/^\([^ ]*\) *\([^ ]*\) *\([^ ]*\).*/ \1:\2 \3 /' \
         | grep "$IMAGES_TO_PRUNE" \
         | cut -d' ' -f3 > images.reap
}

function date_parse {
  if date --utc >/dev/null 2>&1; then
    # GNU/date
    echo $(date -u --date "${1}" "+%s")
  else
    # BSD/date
    echo $(date -j -u -f "%F %T" "${1}" "+%s")
  fi
}

# Elapsed time since a docker timestamp, in seconds
function elapsed_time() {
    # Docker 1.5.0 datetime format is 2015-07-03T02:39:00.390284991
    # Docker 1.7.0 datetime format is 2015-07-03 02:39:00.390284991 +0000 UTC
    utcnow=$(date -u "+%s")
    replace_q="${1#\"}"
    without_ms="${replace_q:0:19}"
    replace_t="${without_ms/T/ }"
    epoch=$(date_parse "${replace_t}")
    echo $(($utcnow - $epoch))
}

function log_verbose() {
    if [ $VERBOSE != false ]; then
        log "$1"
    fi
}
function log() {
    echo "$1"
}

function container_log() {
    prefix=$1
    filename=$2

    while IFS='' read -r containerid
    do
        log_verbose "$prefix $containerid $(docker inspect -f {{.Name}} $containerid)"
    done < "$filename"
}

function image_log() {
    prefix=$1
    filename=$2

    while IFS='' read -r imageid
    do
        log_verbose "$prefix $imageid $(docker inspect -f {{.RepoTags}} $imageid)"
    done < "$filename"
}

function get_image_name_from_id() {
    echo `$DOCKER inspect -f "{{index .RepoTags 0}}" "$1" 2> /dev/null || echo ""`
}
# Verify that docker is reachable
$DOCKER version 1>/dev/null

# Change into the state directory (and create it if it doesn't exist)
if [ ! -d "$STATE_DIR" ]
then
  mkdir -p $STATE_DIR
fi
cd "$STATE_DIR"



# ----------- COLLECT CONTAINERS -------------#

# List all currently existing containers
$DOCKER ps -a -q --no-trunc | sort | uniq > containers.all

# List running containers
$DOCKER ps -q --no-trunc | sort | uniq > containers.running
container_log "Container running" containers.running

# List containers that are not running
comm -23 containers.all containers.running > containers.exited
container_log "Container not running" containers.exited

# Find exited containers that finished at least GRACE_PERIOD_SECONDS ago
echo -n "" > containers.reap.tmp
cat containers.exited | while read line
do
    # Disregard containers that don't match our regexes.
    IFS=","
    for regex in $CONTAINERS_TO_PRUNE; do
        CONTAINER_NAME=$(${DOCKER} inspect -f "{{json .Name}}" ${line})
        if [[ "$CONTAINER_NAME" =~ "$regex" ]]; then

            EXITED=$(${DOCKER} inspect -f "{{json .State.FinishedAt}}" ${line})
            ELAPSED=$(elapsed_time $EXITED)
            if [[ $ELAPSED -gt $GRACE_PERIOD_SECONDS ]]; then
                log_verbose "Marking container $line for removal ($CONTAINER_NAME)"
                echo $line >> containers.reap.tmp
            else
                log_verbose "Container $line is stopped but is not old enough, not pruning"
            fi
        else
            log_verbose "Container $CONTAINER_NAME does not match container regex"
        fi
    done
done

# List containers that we will remove and exclude ids.
cat containers.reap.tmp | sort | uniq > containers.reap

# List containers that we will keep.
comm -23 containers.all containers.reap > containers.keep

# List images used by containers that we keep.
cat containers.keep |
xargs -n 1 $DOCKER inspect -f '{{.Image}}' 2>/dev/null |
sort | uniq > images.used


# ----------- COLLECT IMAGES -------------#

calculate_images_to_reap

# Find images that are created at least GRACE_PERIOD_SECONDS ago
echo -n "" > images.reap.tmp
cat images.reap | while read line
do
    IMAGE_NAME=`get_image_name_from_id $line`
    CREATED=$(${DOCKER} inspect -f "{{.Created}}" ${line})
    ELAPSED=$(elapsed_time $CREATED)
    if [[ $ELAPSED -gt $GRACE_PERIOD_SECONDS ]]; then
        log_verbose "Marking image for removal $line ($IMAGE_NAME)"
        echo $line >> images.reap.tmp
    else
        log_verbose "Image is unused but is not old enough, not pruning $IMAGE_NAME"
    fi
done
cat images.reap.tmp > images.reap



# ----------- REAP CONTAINERS -------------#

while read line; do
    CONTAINER_NAME=$(${DOCKER} inspect -f "{{json .Name}}" ${line})
    if [[ $DRY_RUN == true ]]; then
        log "DRY RUN: Would have removed container (and it's volumes) $line $CONTAINER_NAME"
    else
        container_log "Container (and attached volumes) removed" containers.reap
        xargs -n 1 $DOCKER rm -f --volumes=true < containers.reap &>/dev/null || true
    fi
done < containers.reap



# ----------- REAP IMAGES -------------#

while read line; do
    IMAGE_NAME=`get_image_name_from_id $line`
    if [[ $DRY_RUN == true ]]; then
        log "DRY RUN: Would have removed image $line $IMAGE_NAME"
    else
        image_log "Removing image" images.reap
        #xargs -n 1 $DOCKER rmi $FORCE_IMAGE_FLAG < images.reap &>/dev/null || true
    fi
done < images.reap



# ------------ CLEANUP DANGLING IMAGES -------------#
if [[ $CLEANUP_DANGLING_IMAGES ]]; then
    if [[ $DRY_RUN == true ]]; then
        log "DRY RUN: Would have removed dangling images"
    else
        log "Removing dangling images"
        $DOCKER rmi $($DOCKER images -q -f dangling=true)
    fi
fi