#!/bin/bash

set -euxo pipefail

. filcryo.sh

download_snapshot "$1"
