#!/bin/bash

set -e
set -x
[ -z "$ALVAR_MAP_SERVER_DATA_DIR" ] && echo "ALVAR_MAP_SERVER_DATA_DIR environment variable is not set." && exit 1;

echo -e "Installing openstreetmap style.. "
echo -e "\nUsing osm2pgsql (openstreetmap-carto style) to import data ..\n"

source $ALVAR_MAP_SERVER_REPOSITORY_DIR/tasks/openstreetmap/install-osm2pgsql.sh
sudo apt-get update
sudo apt-get install -y osmctools

# Temporarily allow overcommit setting to allow faster osm2pgsql imports
sudo sysctl -w vm.overcommit_memory=1

# Set CPU scaling governor to perf mode:
# https://askubuntu.com/questions/20271/how-do-i-set-the-cpu-frequency-scaling-governor-for-all-cores-at-once
function setgov () {
  echo "$1" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
}

setgov performance

mkdir -p $HOME/osm
cd $HOME/osm
git clone https://github.com/gravitystorm/openstreetmap-carto.git openstreetmap-carto
cd openstreetmap-carto
git checkout 9f8fbffc4b1d177cf3dc2c173f68323ed792efdd

export PGPASSWORD=osm

if [ "$ALVAR_ENV" = "qa" ]; then
    echo -e "Running qa osm2pgsql command .."
    osm2pgsql -U osm -d osm -H localhost -P 5432 --create --slim \
      --flat-nodes $ALVAR_MAP_SERVER_DATA_DIR/osm2pgsql_flat_nodes.bin \
      --cache 4096 --number-processes 2 --hstore \
      --disable-parallel-indexing \
      --style openstreetmap-carto.style --multi-geometry \
      $ALVAR_MAP_SERVER_DATA_DIR/import-data.osm.pbf
else
    echo -e "Running prod osm2pgsql command .."
    osm2pgsql -U osm -d osm -H localhost -P 5432 --create --slim \
      --flat-nodes $ALVAR_MAP_SERVER_DATA_DIR/osm2pgsql_flat_nodes.bin \
      --cache 16000 --number-processes 4 --hstore \
      --disable-parallel-indexing \
      --style openstreetmap-carto.style --multi-geometry \
      $ALVAR_MAP_SERVER_DATA_DIR/import-data.osm.pbf
fi

psql -f indexes.sql postgres://osm:osm@localhost:5432/osm

# Get shapefiles. Retry if the downloading fails for some reason
for i in {1..5}; do ./scripts/get-shapefiles.py && break || sleep 15; done

# Remove quite large files which are not needed after import
rm $ALVAR_MAP_SERVER_DATA_DIR/osm2pgsql_flat_nodes.bin
rm $ALVAR_MAP_SERVER_DATA_DIR/import-data.osm.pbf

source $ALVAR_MAP_SERVER_REPOSITORY_DIR/tasks/openstreetmap/download-fonts.sh


