#!/bin/bash
set -e
set -o pipefail

# initScript for Ubuntu 16.04 and Docker 18.09
# ------------------------------------------------------------------------------

readonly DOCKER_VERSION="18.09.6"
readonly NODE_ARCHITECTURE="x86_64"
readonly NODE_OPERATING_SYSTEM="Ubuntu_16.04"
readonly SWAP_FILE_PATH="/root/.__sh_swap__"
export docker_restart=false
export install_docker_only="$install_docker_only"

if [ -z "$install_docker_only" ]; then
  install_docker_only="false"
fi

check_init_input() {
  local expected_envs=(
    'NODE_ARCHITECTURE'
    'NODE_OPERATING_SYSTEM'
    'SHIPPABLE_RELEASE_VERSION'
    'SHIPPABLE_RUNTIME_VERSION'
    'EXEC_IMAGE'
    'REQKICK_DIR'
    'IS_SWAP_ENABLED'
    'REQKICK_DOWNLOAD_URL'
    'REPORTS_DOWNLOAD_URL'
    'EXECTEMPLATES_DIR'
    'REQEXEC_DIR'
    'EXECTEMPLATES_DOWNLOAD_URL'
    'REQEXEC_DOWNLOAD_URL'
  )

  check_envs "${expected_envs[@]}"
}

install_docker_prereqs() {
  echo "Installing docker prerequisites"

  update_cmd="apt-get update"
  exec_cmd "$update_cmd"

  install_prereqs_cmd="apt-get -yy install apt-transport-https git python-pip software-properties-common ca-certificates curl wget tar"
  exec_cmd "$install_prereqs_cmd"

  add_docker_repo_keys='curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -'
  exec_cmd "$add_docker_repo_keys"

  add_docker_repo='add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"'
  exec_cmd "$add_docker_repo"

  update_cmd="apt-get update"
  exec_cmd "$update_cmd"
}

install_prereqs() {
  local nodejs_version="8.16.0"

  echo "Installing prerequisite binaries"

  pushd /tmp
  echo "Installing node $nodejs_version"

  get_node_tar_cmd="wget https://nodejs.org/dist/v$nodejs_version/node-v$nodejs_version-linux-x64.tar.xz"
  exec_cmd "$get_node_tar_cmd"

  node_extract_cmd="tar -xf node-v$nodejs_version-linux-x64.tar.xz"
  exec_cmd "$node_extract_cmd"

  node_copy_cmd="cp -Rf node-v$nodejs_version-linux-x64/{bin,include,lib,share} /usr/local"
  exec_cmd "$node_copy_cmd"

  check_node_version_cmd="node -v"
  exec_cmd "$check_node_version_cmd"
  popd

  if ! [ -x "$(command -v jq)" ]; then
    echo "Installing jq"
    apt-get install -y jq
  fi

  exec_cmd "$update_cmd"
}

check_swap() {
  echo "Checking for swap space"

  swap_available=$(free | grep Swap | awk '{print $2}')
  if [ $swap_available -eq 0 ]; then
    echo "No swap space available, adding swap"
    is_swap_required=true
  else
    echo "Swap space available, not adding"
  fi
}

add_swap() {
  echo "Adding swap file"
  echo "Creating Swap file at: $SWAP_FILE_PATH"
  add_swap_file="touch $SWAP_FILE_PATH"
  exec_cmd "$add_swap_file"

  swap_size=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
  swap_size=$(($swap_size/1024))
  echo "Allocating swap of: $swap_size MB"
  initialize_file="dd if=/dev/zero of=$SWAP_FILE_PATH bs=1M count=$swap_size"
  exec_cmd "$initialize_file"

  echo "Updating Swap file permissions"
  update_permissions="chmod -c 600 $SWAP_FILE_PATH"
  exec_cmd "$update_permissions"

  echo "Setting up Swap area on the device"
  initialize_swap="mkswap $SWAP_FILE_PATH"
  exec_cmd "$initialize_swap"

  echo "Turning on Swap"
  turn_swap_on="swapon $SWAP_FILE_PATH"
  exec_cmd "$turn_swap_on"

}

check_fstab_entry() {
  echo "Checking fstab entries"

  if grep -q $SWAP_FILE_PATH /etc/fstab; then
    exec_cmd "echo /etc/fstab updated, swap check complete"
  else
    echo "No entry in /etc/fstab, updating ..."
    add_swap_to_fstab="echo $SWAP_FILE_PATH none swap sw 0 0 | tee -a /etc/fstab"
    exec_cmd "$add_swap_to_fstab"
    exec_cmd "echo /etc/fstab updated"
  fi
}

initialize_swap() {
  check_swap
  if [ "$is_swap_required" == true ]; then
    add_swap
  fi
  check_fstab_entry
}

docker_install() {
  echo "Installing docker"

  install_docker="apt-get install -q --force-yes -y -o Dpkg::Options::='--force-confnew' docker-ce=5:$DOCKER_VERSION~3-0~ubuntu-$(lsb_release -cs) docker-ce-cli=5:$DOCKER_VERSION~3-0~ubuntu-$(lsb_release -cs)"
  exec_cmd "$install_docker"

  get_static_docker_binary="wget https://download.docker.com/linux/static/stable/x86_64/docker-$DOCKER_VERSION.tgz -P /tmp/docker"
  exec_cmd "$get_static_docker_binary"

  extract_static_docker_binary="tar -xzf /tmp/docker/docker-$DOCKER_VERSION.tgz --directory /opt"
  exec_cmd "$extract_static_docker_binary"

  remove_static_docker_binary='rm -rf /tmp/docker'
  exec_cmd "$remove_static_docker_binary"

  enable_docker='systemctl enable docker'
  exec_cmd "$enable_docker"
}

check_docker_opts() {
  mkdir -p /etc/docker

  is_gce_header=$(curl -I -s metadata.google.internal | grep "Metadata-Flavor: Google") || true
  if [ -z "$is_gce_header" ]; then
    config="{\"graph\": \"/data\"}"
  else
    config="{\"graph\": \"/data\", \"mtu\": 1460 }"
  fi

  config_file="/etc/docker/daemon.json"
  if [ -f "$config_file" ] && [ "$(echo -e $config)" == "$(cat $config_file)" ]; then
    echo "Skipping adding config as its already added"
  else
    echo "Adding Docker config"
    echo -e "$config" > "$config_file"
    docker_restart=true
  fi
}

add_docker_proxy_envs() {
  mkdir -p /etc/systemd/system/docker.service.d

  proxy_envs="[Service]\nEnvironment="
  if [ ! -z "$SHIPPABLE_HTTP_PROXY" ]; then
    proxy_envs="$proxy_envs \"HTTP_PROXY=$SHIPPABLE_HTTP_PROXY\""
  fi

  if [ ! -z "$SHIPPABLE_HTTPS_PROXY" ]; then
    proxy_envs="$proxy_envs \"HTTPS_PROXY=$SHIPPABLE_HTTPS_PROXY\""
  fi

  if [ ! -z "$SHIPPABLE_NO_PROXY" ]; then
    proxy_envs="$proxy_envs \"NO_PROXY=$SHIPPABLE_NO_PROXY\""
  fi

  local docker_proxy_config_file="/etc/systemd/system/docker.service.d/proxy.conf"

  if [ -f "$docker_proxy_config_file" ] && [ "$(echo -e $proxy_envs)" == "$(cat $docker_proxy_config_file)" ]; then
    echo "Skipping Docker proxy config, as its already added"
  else
    echo "Adding Docker proxy config"
    echo -e "$proxy_envs" > "$docker_proxy_config_file"
    docker_restart=true
  fi
}

restart_docker_service() {
  echo "checking if docker restart is necessary"
  if [ $docker_restart == true ]; then
    echo "restarting docker service on reset"
    exec_cmd "systemctl daemon-reload"
    exec_cmd "service docker restart"
  else
    echo "docker_restart set to false, not restarting docker daemon"
  fi
}

install_ntp() {
  {
    check_ntp=$(service --status-all 2>&1 | grep ntp)
  } || {
    true
  }

  if [ ! -z "$check_ntp" ]; then
    echo "NTP already installed, skipping."
  else
    echo "Installing NTP"
    exec_cmd "apt-get install -y ntp"
    exec_cmd "service ntp restart"
  fi
}

fetch_reports_binary() {
  __process_marker "Installing report parser..."

  local reports_dir="/jfrog/reports"
  local reports_tar_file="reports.tar.gz"
  rm -rf $reports_dir
  mkdir -p $reports_dir
  pushd $reports_dir
    wget $REPORTS_DOWNLOAD_URL -O $reports_tar_file
    tar -xf $reports_tar_file
    rm -rf $reports_tar_file
  popd
}

fetch_reqKick() {
  __process_marker "Fetching reqKick..."
  local reqKick_tar_file="reqKick.tar.gz"

  rm -rf $REQKICK_DIR
  rm -rf $reqKick_tar_file
  pushd /tmp
    wget $REQKICK_DOWNLOAD_URL -O $reqKick_tar_file
    mkdir -p $REQKICK_DIR
    tar -xzf $reqKick_tar_file -C $REQKICK_DIR --strip-components=1
    rm -rf $reqKick_tar_file
  popd
  pushd $REQKICK_DIR
    npm install
  popd
}

fetch_reqExec_binary() {
  __process_marker "Fetching reqExec binary..."

  local reqExec_tar_file="reqExec.tar.gz"
  rm -rf $REQEXEC_DIR
  mkdir -p $REQEXEC_DIR
  pushd $REQEXEC_DIR
    wget $REQEXEC_DOWNLOAD_URL -O $reqExec_tar_file
    tar -xf $reqExec_tar_file
    rm -rf $reqExec_tar_file
  popd
}

fetch_execTemplates() {
  __process_marker "Fetching execTemplates..."
  local execTemplates_tar_file="execTemplates.tar.gz"

  rm -rf $EXECTEMPLATES_DIR
  rm -rf $execTemplates_tar_file
  pushd /tmp
    wget $EXECTEMPLATES_DOWNLOAD_URL -O $execTemplates_tar_file
    mkdir -p $EXECTEMPLATES_DIR
    tar -xzf $execTemplates_tar_file -C $EXECTEMPLATES_DIR --strip-components=1
    rm -rf $execTemplates_tar_file
  popd
}

before_exit() {
  echo $1
  echo $2

  echo "Node init script completed"
}

main() {
  if [ "$install_docker_only" == "true" ]; then
    trap before_exit EXIT
    exec_grp "install_docker_prereqs"

    trap before_exit EXIT
    exec_grp "docker_install"

    trap before_exit EXIT
    exec_grp "check_docker_opts"

    if [ ! -z "$SHIPPABLE_HTTP_PROXY" ] || [ ! -z "$SHIPPABLE_HTTPS_PROXY" ] || [ ! -z "$SHIPPABLE_NO_PROXY" ]; then
      trap before_exit EXIT
      exec_grp "add_docker_proxy_envs"
    fi

    trap before_exit EXIT
    exec_grp "restart_docker_service"
  else
    check_init_input

    trap before_exit EXIT
    exec_grp "install_docker_prereqs"

    trap before_exit EXIT
    exec_grp "install_prereqs"

    if [ "$IS_SWAP_ENABLED" == "true" ]; then
      trap before_exit EXIT
      exec_grp "initialize_swap"
    fi

    trap before_exit EXIT
    exec_grp "docker_install"

    trap before_exit EXIT
    exec_grp "check_docker_opts"

    if [ ! -z "$SHIPPABLE_HTTP_PROXY" ] || [ ! -z "$SHIPPABLE_HTTPS_PROXY" ] || [ ! -z "$SHIPPABLE_NO_PROXY" ]; then
      trap before_exit EXIT
      exec_grp "add_docker_proxy_envs"
    fi

    trap before_exit EXIT
    exec_grp "restart_docker_service"

    trap before_exit EXIT
    exec_grp "install_ntp"

    trap before_exit EXIT
    exec_grp "fetch_reports_binary"

    trap before_exit EXIT
    exec_grp "fetch_reqKick"

    trap before_exit EXIT
    exec_grp "fetch_reqExec_binary"

    trap before_exit EXIT
    exec_grp "fetch_execTemplates"
  fi
}

main
