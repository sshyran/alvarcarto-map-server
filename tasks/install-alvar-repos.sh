#!/bin/bash

set -e
set -x
[ -z "$ALVAR_MAP_SERVER_DATA_DIR" ] && echo "ALVAR_MAP_SERVER_DATA_DIR environment variable is not set." && exit 1;

sudo apt-get install -y libcairo2-dev libjpeg8-dev libpango1.0-dev libgif-dev build-essential g++

source $ALVAR_MAP_SERVER_REPOSITORY_DIR/tasks/install-alvar-repo-render.sh
source $ALVAR_MAP_SERVER_REPOSITORY_DIR/tasks/install-alvar-repo-cartocss.sh "$1"
source $ALVAR_MAP_SERVER_REPOSITORY_DIR/tasks/install-alvar-repo-placement.sh
source $ALVAR_MAP_SERVER_REPOSITORY_DIR/tasks/install-alvar-repo-tile.sh
source $ALVAR_MAP_SERVER_REPOSITORY_DIR/tasks/install-alvar-repo-http-cache.sh


nvm use 10.20.1

cd $ALVAR_MAP_SERVER_REPOSITORY_DIR
# Use pm2@3.x version until this is solved: https://github.com/Unitech/pm2/issues/4686
npm install -g pm2@3.x.x

npm i mustache

# This step assumes that the installation dir contains <env>.secrets.json file with secrets
if [ "$ALVAR_ENV" = "qa" ] || [ "$ALVAR_ENV" = "docker" ]; then
    node tools/replace-secrets.js confs/pm2.qa.json "$ALVAR_MAP_SERVER_INSTALL_DIR/qa.secrets.json" > confs/chosen-pm2.json
else
    node tools/replace-secrets.js confs/pm2.json "$ALVAR_MAP_SERVER_INSTALL_DIR/prod.secrets.json" > confs/chosen-pm2.json
fi

pm2 start confs/chosen-pm2.json

sleep 3
sudo env PATH=$PATH:/home/alvar/.nvm/versions/node/v10.20.1/bin /home/alvar/.nvm/versions/node/v10.20.1/lib/node_modules/pm2/bin/pm2 startup systemd -u alvar --hp /home/alvar
sleep 2
pm2 save

echo "Waiting until services have started .."
sleep 120

if [ "$ALVAR_ENV" != "docker" ]; then
  echo "Installing cron task to restart services when needed .."
  echo -e "$(crontab -l 2>/dev/null)\n*/5 * * * * /bin/bash -c 'source $HOME/.bashrc; bash $ALVAR_MAP_SERVER_REPOSITORY_DIR/tools/health-check.sh'" | crontab -
fi


if [ "$1" != "warm_caches" ]; then
  echo "Skipping warm_caches step"
  exit 0;
fi

echo "Warming caches .. warning: this may take a very long time!"

npm install -g @alvarcarto/tilewarm
curl -O https://raw.githubusercontent.com/alvarcarto/tilewarm/master/geojson/world.geojson
curl -O https://raw.githubusercontent.com/alvarcarto/tilewarm/master/geojson/all-cities.geojson

# Iterate all styles (~12) in cartocss repo
# For each style we need to fetch 80k + 13k = ~100k tiles, this totals 1.2M tile requests
# If request takes 1000ms on average, this process takes 333h ~= 14d
for i in $(find "$ALVAR_MAP_SERVER_INSTALL_DIR/mapnik-styles/" -name '*.xml');
do
  style=$(basename "$i" .xml)

  if [ "$ALVAR_SERVER_ENV" == "reserve" ]; then
    # 1-8 zoom levels for whole world is 80k tiles
    echo "Warming caches (production) with world.geojson for style $style .."
    NODE_OPTIONS=--max_old_space_size=4096 tilewarm "http://$IP:8002/bw/{z}/{x}/{y}/tile.png" --input world.geojson --max-retries 20 --retry-base-timeout 100 -c 'z < 7 ? 1 : 5' --zoom 1-8 --verbose

    # 9-10 zoom levels for all cities is 13k tiles
    echo "Warming caches (production) with all-cities.geojson for style $style .."
    NODE_OPTIONS=--max_old_space_size=4096 tilewarm "http://$IP:8002/bw/{z}/{x}/{y}/tile.png" --input all-cities.geojson --max-retries 10 --retry-base-timeout 100 -c 20 --zoom 10 --verbose
  else
    # 10 zoom level for all cities is 13k tiles
    echo "Warming caches (qa) with all-cities.geojson for style $style .."
    NODE_OPTIONS=--max_old_space_size=4096 tilewarm "http://$IP:8002/bw/{z}/{x}/{y}/tile.png" --input all-cities.geojson -c 20 --zoom 10 --verbose
  fi
done
