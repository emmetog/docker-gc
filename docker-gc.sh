#!/usr/bin/env bash

set -o errexit

CONTAINERS_TO_PRUNE=""
DRY_RUN=false
DOCKER=docker
IMAGES_TO_PRUNE=""
PID_DIR=/var/run
STATE_DIR=/var/lib/docker-gc

for pid in $(pidof -s docker-gc); do
    if [[ $pid != $$ ]]; then
        echo "[$(date)] : docker-gc : Process is already running with PID $pid"
        exit 1
    fi
done

trap "rm -f -- '$PID_DIR/dockergc'" EXIT

echo $$ > $PID_DIR/dockergc



while [[ $# > 0 ]]
do
    key="$1"

    case $key in
        -n|--dry-run)
            DRY_RUN=true
        ;;
        -v|--verbose)
            verbose=true
        ;;
        -c|--containers)
            CONTAINERS_TO_PRUNE="$2"
            shift # past argument
        ;;
        -i|--images)
            IMAGES_TO_PRUNE="$2"
            shift # past argument
        ;;
        *)
            echo "Docker garbage collection: remove unused containers and images."
            echo "Usage: ${0##*/} [--dry-run] [--verbose]"
            echo "   -n, --dry-run: dry run: display what would get removed."
            echo "   -v, --verbose: verbose output."
            exit 1
        ;;
    esac
    shift
done



# Get containers to remove from the variable
if [ -z $CONTAINERS_TO_PRUNE ] && [ -z $IMAGES_TO_PRUNE ]; then
    echo "No CONTAINERS_TO_PRUNE or IMAGES_TO_PRUNE, specify regexes in order to select containers and images for pruning";
    exit 0
fi

echo "Pruning containers that match this regex: $CONTAINERS_TO_PRUNE"
echo "Pruning unused images that match this regex: $IMAGES_TO_PRUNE"

function compute_exclude_ids() {
    # Find images that match patterns in the EXCLUDE_FROM_GC file and put their
    # id prefixes into $INCLUDE_IDS_FILE, prefixed with ^

    PROCESSED_INCLUDES="processed_includes.tmp"
    # Take each line and put a space at the beginning and end, so when we
    # grep for them below, it will effectively be: "match either repo:tag
    # or imageid".  Also delete blank lines or lines that only contain
    # whitespace
    echo $IMAGES_TO_PRUNE | sed 's/^\(.*\)$/ \1 /' | sed '/^ *$/d' > $PROCESSED_INCLUDES

    # The following looks a bit of a mess, but here's what it does:
    # 1. Get images
    # 2. Skip header line
    # 3. Turn columnar display of 'REPO TAG IMAGEID ....' to 'REPO:TAG IMAGEID'
    # 4. find lines that contain things mentioned in PROCESSED_EXCLUDES
    # 5. Grab the image id from the line
    # 6. Prepend ^ to the beginning of each line

    # What this does is make grep patterns to match image ids mentioned by
    # either repo:tag or image id for later greppage
    $DOCKER images \
        | tail -n+2 \
        | sed 's/^\([^ ]*\) *\([^ ]*\) *\([^ ]*\).*/ \1:\2 \3 /' \
        | grep -f $PROCESSED_INCLUDES 2>/dev/null \
        | cut -d' ' -f3 \
        | sed 's/^/^/' > images.keep
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

function log() {
    echo "$1"
}

function container_log() {
    prefix=$1
    filename=$2

    while IFS='' read -r containerid
    do
        log "$prefix $containerid $(docker inspect -f {{.Name}} $containerid)"
    done < "$filename"
}

function image_log() {
    prefix=$1
    filename=$2

    while IFS='' read -r imageid
    do
        log "$prefix $imageid $(docker inspect -f {{.RepoTags}} $imageid)"
    done < "$filename"
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
                echo "Marking container $line for removal ($CONTAINER_NAME)"
                echo $line >> containers.reap.tmp
            else
                echo "Container $line is stopped but is not old enough, not pruning"
            fi
        else
            echo "Container $CONTAINER_NAME does not match container regex"
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

compute_exclude_ids

$DOCKER images -q --no-trunc | sort | uniq > images.all

# Find images that are created at least GRACE_PERIOD_SECONDS ago
echo -n "" > images.reap.tmp
cat images.all | while read line
do
    # Disregard images that don't match our regexes.
    while read IMAGE_ID_TO_KEEP; do
        if [[ ! $line =~ $IMAGE_ID_TO_KEEP ]]; then
            CREATED=$(${DOCKER} inspect -f "{{.Created}}" ${line})
            ELAPSED=$(elapsed_time $CREATED)
            if [[ $ELAPSED -gt $GRACE_PERIOD_SECONDS ]]; then
                echo "Marking image $line for removal ($IMAGE_NAME)"
                echo $line >> images.reap.tmp
            else
                echo "Image $IMAGE_NAME is unused but is not old enough, not pruning"
            fi
        else
            echo "Image $IMAGE_NAME does not match image regex"
        fi
    done < images.keep
done
comm -23 images.reap.tmp images.used  > images.reap || true



# ----------- REAP CONTAINERS -------------#

while read line; do
    if [[ $DRY_RUN ]]; then
        echo "DRY RUN: Would have removed container $line"
    else
        container_log "Container removed" containers.reap
        #xargs -n 1 $DOCKER rm -f --volumes=true < containers.reap &>/dev/null || true
    fi
done < containers.reap



# ----------- REAP CONTAINERS -------------#

while read line; do
    if [[ $DRY_RUN ]]; then
        echo "DRY RUN: Would have removed image $line"
    else
        image_log "Removing image" images.reap
        #xargs -n 1 $DOCKER rmi $FORCE_IMAGE_FLAG < images.reap &>/dev/null || true
    fi
done < images.reap
