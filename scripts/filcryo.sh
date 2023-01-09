#!/bin/bash

set -uo pipefail

# export_range instructs lotus to do a chain export from the given height until 2890 epochs later.
function export_range {
    local START="$1"
    local END
    (( "END=${START}+2880" ))
    echo "$(date): Exporting snapshot from ${START} until ${END} (+10 extra)"
    (( "END+=10" ))
    lotus chain export-range --internal --messages --receipts --stateroots --workers 50 --head "@${END}" --tail "@${START}" --write-buffer=5000000 export.car
    echo "$(date): Finished exporting snapshot from ${START} until ${END}"
    mkdir -p finished_snapshots
    mv snapshot_"${START}"_*.car finished_snapshots/
    # FIXME: null rounds
    return 0
}

# compress_snapshot compresses a snapshot starting on the given epoch.
function compress_snapshot {
    local START=$1

    pushd finished_snapshots || return 1
    echo "$(date): Compressing snapshot for ${START}"
    zstd --fast --rm --no-progress -T0 snapshot_"${START}"_*.car && \
	echo "$(date): Finished compressing snapshot for ${START}"
    popd || return 1
    return 0
}

# download_snapshot downloads the snapshot for the given epoch from gcloud storage and decompresses it.
function download_snapshot {
    local START=$1

    # Verify the snapshot exists. Exits with error otherwise.
    snapshot_url=$(gcloud storage ls "gs://fil-mainnet-archival-snapshots/historical-exports/snapshot_${START}_*_*.car.zst") || return 1
    
    snapshot_name=$(basename "${snapshot_url}")
    mkdir -p downloaded_snapshots
    pushd downloaded_snapshots || return 1
    gsutil cp "${snapshot_url}" .
    zstd --rm -d "${snapshot_name}"
    popd || return 1

    echo "Snapshot downloaded and decompressed successfully"
    return 0
}

# get_last_epoch prints the last epoch available in the bucket. This is the
# epoch on which the next snapshot should start.
function get_last_epoch {
    # snapshot_2295360_2298242_1667419153.car.zst
    # -> 2295360 + 2880
    # -> 2298240

    local last_epoch
    last_epoch=$(gcloud storage ls gs://fil-mainnet-archival-snapshots/historical-exports/ | xargs -n1 basename | cut -d'_' -f 2 | sort -n | tail -n1)
    (( "last_epoch=${last_epoch}+2880" ))
    echo "${last_epoch}"
    return 0
}

# get last snapshot epoch returns the epoch of the last available snapshot so it can be used with
# download_snapshot
function get_last_snapshot_epoch {
    local last_epoch
    last_epoch=$(gcloud storage ls gs://fil-mainnet-archival-snapshots/historical-exports/ | xargs -n1 basename | cut -d'_' -f 2 | sort -n | tail -n1)
    echo "${last_epoch}"
    return 0
}
    
# import_snapshot imports an snapshot corresponding to the given epoch into lotus with --halt-after-import.
function import_snapshot {
    local START=$1
    
    echo "$(date): Importing snapshot"
    lotus daemon --import-snapshot snapshot_"${START}"_*.car --halt-after-import
    return 0
}

# start_lotus launches lotus daemon with the given daemon arguments and waits until it is running.
function start_lotus {
    echo "$(date): Launching Lotus daemon: ${1:-}"
    # shellcheck disable=SC2086
    nohup lotus daemon ${1:-} &>>lotus.log & # run in background!
    echo "$(date): Waiting for lotus to start"
    while ! lotus sync status; do
	sleep 10
    done
    sleep 5
    return 0
}

# stop_lotus stops the lotus daemon gracefully
function stop_lotus {
    echo "$(date): Shutting down lotus"
    lotus daemon stop
    sleep 20
    return 0
}

# upload_snapshot uploads the snapshot for the given epoch to the gcloud storage bucket.
function upload_snapshot {
    local START=$1
    
    pushd finished_snapshots || return 1
    echo "$(date): Uploading snapshot for ${START}"
    gsutil cp snapshot_"${START}"_*.car.zst "gs://fil-mainnet-archival-snapshots/historical-exports/"
    echo "$(date): Finished uploading snapshot for ${START}"
    rm snapshot_"${START}"_*.car.zst
    popd || return 1
    return 0
}

# wait_for_epoch waits for lotus to be synced up to the given epoch + 2880 +
# 905 epochs: it waits until we can make a 24h snapshot that starts on the given epoch, with the end epoch having reached finality.
function wait_for_epoch {
    local START="$1"
    local END
    (( "END=${START}+2880+900+5" ))

    echo "$(date): Waiting for Lotus to sync until ${END}"

    while true; do
	local current_height
	current_height=$(lotus chain list --count 1 | cut -d ':' -f 1) || { sleep 1; continue; }
	echo "current height: ${current_height}"

	if [[ "${current_height}" -ge "${END}" ]]; then
	    break
	fi
	sleep 10
    done
    echo "$(date): Lotus reached ${END}"
}