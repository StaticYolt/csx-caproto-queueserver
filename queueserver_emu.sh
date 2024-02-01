#!/bin/bash -uem

function usage() {
  sed 's/^  //' << EOF

  Start a queueserver run eigine with caproto-emulated beamline hardware.

  USAGE: ${0##*/} [--install-conda][--install-mongo][--install-redis] \\
                  [--env][--default-config][--download-cache-dir] \\
                  [--profile-name][--help|-h]

  --help or -h
                  Display this message and exit.
  --install-[conda|mongo|redis]
                  These will install respective dependencies
  --env=CONDA_ENV_NAME or --env CONDA_ENV_NAME
                  Selects the conda environment. Defalts to 2023-3.3-py310-tiled.
  --default-config
                  Writes (or overwrites) the configurations for all dependencies
                  including Olog, databroker, tiled, and kafka
  --download-cache-dir=DIR or --download-cache-dir DIR
                  Choose a cache directory for downloaded components (conda envs,
                  profiles, etc).
  --profile-name=PROFILE_NAME or --profile-name PROFILE_NAME
                  Set the ipython startup profile name. Defaults to "test"
EOF
}

# default options
PROFILE_REPO="git@github.com:NSLS-II-CSX/profile_collection.git"
PROFILE_BRANCH="qserver"
INSTALL_CONDA=false
INSTALL_MONGO=false
INSTALL_REDIS=false
DEFAULT_CONFIG=false
SKIP_PROFILE=false
CONDA_PREFIX="${CONDA_PREFIX:-$HOME/miniconda}"
CONDA_ENV_NAME="2023-3.3-py310-tiled"
CACHE_DIR=.

ZENODO_INFO="
  env                  id       checksum
  2022-2.2-py39-tiled  6499325  1ce49c8810ce714ca39d47d1cd734e47
  2023-3.3-py310-tiled 10148425 0a47934380db013b36f3e089afdff6aa
"

function pick() {
  [[ -z $1 ]] && echo "$2" && return 1 || <<<$1 sed 's/=$//'
}

while (($#)); do
  arg="${1}="
  arg2="${2:-}"
  key="${arg%%=*}"
  val="${arg#*=}"
  case "$key" in
  --install-conda)
    INSTALL_CONDA=true
    CONDA_PREFIX=$(pick "$val" "$arg2") || shift
    ;;
  --install-mongo)
    INSTALL_MONGO=true
    ;;
  --install-redis)
    INSTALL_REDIS=true
    ;;
  --default-config)
    DEFAULT_CONFIG=true
    ;;
  --env)
    CONDA_ENV_NAME=$(pick "$val" "$arg2") || shift
    ;;
  --download-cache-dir)
    CACHE_DIR=$(pick "$val" "$arg2") || shift
    ;;
  --skip-profile-creation)
    SKIP_PROFILE=true
    ;;
  --profile-name)
    TEST_PROFILE=$(pick "$val" "$arg2") || shift
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    echo "ERROR: argument invalid: '${arg%%=*}'" >&2
    usage >&2
    exit 1
    ;;
  esac
  shift
done

cd "$CACHE_DIR"

##[section]Starting: * check the env
echo "Setting up env variables"
ZENODO_ID=$(<<<$ZENODO_INFO awk -venv="$CONDA_ENV_NAME" '$1==env {print $2}')
MD5_CHECKSUM=$(<<<$ZENODO_INFO awk -venv="$CONDA_ENV_NAME" '$1==env {print $3}')
export CONDA_ENV_NAME="$CONDA_ENV_NAME"
export ZENODO_ID="$ZENODO_ID"
export MD5_CHECKSUM="$MD5_CHECKSUM"
export BEAMLINE_ACRONYM=CSX
export BLUESKY_KAFKA_BOOTSTRAP_SERVERS=
export BLUESKY_KAFKA_PASSWORD=
export CAPROTO_COMMAND="python -m caproto.ioc_examples.pathological.spoof_beamline"
export CONDA_CHANNEL_NAME=conda-forge
export EPICS_CA_ADDR_LIST=127.0.0.1
export EPICS_CA_AUTO_ADDR_LIST=NO
export MPLBACKEND=Qt5Agg
export OPHYD_CONTROL_LAYER=pyepics
export OPHYD_TIMEOUT=60
export PYTHON_VERSION=3.9
export TEST_PROFILE="${TEST_PROFILE:-test}"
export USE_EPICS_IOC=0

##[section]Starting: * get configs (pyOlog, databroker, tiled, kafka)
if $DEFAULT_CONFIG; then
  echo "pyOlog config:"
  wget https://raw.githubusercontent.com/NSLS-II/profile-collection-ci/master/configs/pyOlog.conf -O $HOME/.pyOlog.conf
  cat $HOME/.pyOlog.conf

  echo "Classic databroker v0/v1 config:"
  databroker_conf_dir="$HOME/.config/databroker"
  beamline_acronym="${BEAMLINE_ACRONYM,,}"
  databroker_bl_conf="${beamline_acronym}.yml"
  mkdir -v -p ${databroker_conf_dir}
  wget https://raw.githubusercontent.com/NSLS-II/profile-collection-ci/master/configs/databroker.yml -O ${databroker_conf_dir}/_legacy_config.yml
  cp -v ${databroker_conf_dir}/_legacy_config.yml ${databroker_conf_dir}/${databroker_bl_conf}
  cat ${databroker_conf_dir}/_legacy_config.yml
  cat ${databroker_conf_dir}/${databroker_bl_conf}

  echo "Tiled profile config:"
  tiled_profiles_dir="$HOME/.config/tiled/profiles/"
  mkdir -v -p "${tiled_profiles_dir}"
  sed 's/^  //' << EOF > "${tiled_profiles_dir}/profiles.yml"
  ${beamline_acronym:-local}:
    direct:
      authentication:
        allow_anonymous_access: true
      trees:
      - tree: databroker.mongo_normalized:Tree.from_uri
        path: /
        args:
          uri: mongodb://localhost:27017/metadatastore-local
          asset_registry_uri: mongodb://localhost:27017/asset-registry-local
EOF
  cat ${tiled_profiles_dir}/profiles.yml

  echo "Kafka config:"
  sed 's/^  //' << EOF > kafka.yml
  ---
    abort_run_on_kafka_exception: false
    bootstrap_servers:
      - localhost:9092
    runengine_producer_config:
      security.protocol: PLAINTEXT
EOF

  echo "SUDO: Placing kafka config in /etc/bluesky"
  sudo mkdir -v -p /etc/bluesky/
  sudo mv -v kafka.yml /etc/bluesky/kafka.yml
  cat /etc/bluesky/kafka.yml

fi

##[section]Starting: * prepare a test profile dir
if ! "$SKIP_PROFILE"; then
  echo "Preparing test profile"
  rm -rfv profile_collection
  git clone "$PROFILE_REPO"
  (
    cd profile_collection
    git checkout "$PROFILE_BRANCH"
    rm -rfv ~/.ipython/profile_${TEST_PROFILE}/
    mkdir -pv ~/.ipython/profile_${TEST_PROFILE}/
    cp -rv startup ~/.ipython/profile_${TEST_PROFILE}/
    # rm -fv ~/.ipython/profile_${TEST_PROFILE}/startup/*.py
  )
fi

##[section]Starting: * install required packages
echo "Installing requirements..."
if $INSTALL_MONGO; then
  echo "SUDO: Installing mongodb"
  sudo apt-get update
  sudo apt-get install -y lsb-release
  wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | sudo apt-key add -
  echo "deb [ arch=$(dpkg --print-architecture) ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/6.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list
  sudo apt-get install -y mongodb-org
fi

if $INSTALL_REDIS; then
  echo "SUDO: Installing redis"
  sudo apt-get clean
  sudo apt-get update
  sudo apt-get install -y redis
fi

##[section]Starting: * start mongodb service
if ! systemctl is-active --quiet mongod; then
  echo "SUDO: Starting mongo daemon"
  sudo systemctl start mongod
fi
systemctl status mongod.service --lines 0 --no-pager

##[section]Starting: * start redis service
if ! systemctl is-active --quiet redis-server.service; then
  echo "SUDO: Starting redis server"
  sudo systemctl start redis-server.service
fi
systemctl status redis-server.service --lines 0 --no-pager

##[section]Starting: * setup conda env
if $INSTALL_CONDA; then
  echo "Installing conda"
  wget --progress=dot:giga https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O miniconda.sh
  bash ./miniconda.sh -b -p $CONDA_PREFIX
fi
source "${CONDA_PREFIX}/etc/profile.d/conda.sh"
echo "Looking for conda env..."
set +u # conda has unbound variables!
conda deactivate
conda activate "${CONDA_ENV_NAME}" || {
  set -u
  md5sum --status --check <(echo "${MD5_CHECKSUM} ${CONDA_ENV_NAME}.tar.gz") ||
    echo "Downloading conda env..." &&
    wget --progress=dot:giga  "https://zenodo.org/record/${ZENODO_ID}/files/${CONDA_ENV_NAME}.tar.gz?download=1" -O "${CONDA_ENV_NAME}.tar.gz"
  md5sum --check <(echo "${MD5_CHECKSUM} ${CONDA_ENV_NAME}.tar.gz")
  echo "Extracting conda env..."
  mkdir -v -p "${CONDA_PREFIX}/envs/${CONDA_ENV_NAME}"
  tar -xvf "${CONDA_ENV_NAME}.tar.gz" -C "${CONDA_PREFIX}/envs/${CONDA_ENV_NAME}"
  set +u # conda has unbound variables!
  conda activate "${CONDA_PREFIX}/envs/${CONDA_ENV_NAME}"
  conda unpack && echo "Unpacked successfully!"
  set -u
}


##[section]Starting: * perform beamline-specific actions
echo "Performing beamline-specific tasks..."
case "${BEAMLINE_ACRONYM,,}" in
csx)
  # Create non-standard directories:
  csx_cfg_dir=/nsls2/data/csx/shared/config/
  if [[ ! -d "$csx_cfg_dir" ]]; then
    mkdir -v -p "$csx_cfg_dir" ||
    (
      echo "Error: Couldn't create dir: ${csx_cfg_dir}"
      exit 1
    )
  fi
  ;;
esac

##[section]Starting: * run IPython with startup files
if [ ! -z "${USE_EPICS_IOC}" -a "${USE_EPICS_IOC}" == "1" ]; then
  echo "Not using caproto-spoof-beamline IOC as instructed by .ci/bl-specific.sh"
else
  # TODO: revert it once https://github.com/caproto/caproto/pull/695 is merged/released.
  # echo -e "\n" | caproto-spoof-beamline &
  echo | ${CAPROTO_COMMAND} &
  trap 'kill -SIGINT %1; echo exiting...' EXIT
  # Solve a missing "caRepeater" binary (same reason as in
  # https://github.com/bluesky/tutorial/blob/master/binder/postBuild):
  ln -svf caproto-repeater "${CONDA_PREFIX}/bin/caRepeater"
fi

# Monkey-patch the default timeout for the ophyd signals:
if [ "$OPHYD_CONTROL_LAYER" == "pyepics" ]; then
  connection_timeout=""
fi

# ipython --profile="${TEST_PROFILE}"
start-re-manager --startup-dir=$HOME/.ipython/profile_test/startup --keep-re --use-ipython-kernel=ON --ignore-invalid-plans=ON
