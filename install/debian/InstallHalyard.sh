#!/usr/bin/env bash

set -e

function check_migration_needed() {
  set +e

  which dpkg &> /dev/null
  if [ "$?" = "0" ]; then
    dpkg -s spinnaker-halyard &> /dev/null

    if [ "$?" != "1" ]; then
      >&2 echo "Attempting to install halyard while a debian installation is present."
      >&2 echo "Please visit: http://spinnaker.io/setup/install/halyard_migration"
      exit 1
    fi
  fi
  set -e
}

function process_args() {
  while [ "$#" -gt "0" ]
  do
    local key="$1"
    shift
    case $key in
      --halyard-bucket-base-url)
        echo "halyard-bucket-base-url"
        HALYARD_BUCKET_BASE_URL="$1"
        shift
        ;;
      --download-with-gsutil)
        echo "download-with-gsutil"
        DOWNLOAD_WITH_GSUTIL=true
        ;;
      --spinnaker-repository)
        echo "spinnaker-repo"
        SPINNAKER_REPOSITORY_URL="$1"
        shift
        ;;
      --spinnaker-registry)
        echo "spinnaker-registry"
        SPINNAKER_DOCKER_REGISTRY="$1"
        shift
        ;;
      --spinnaker-gce-project)
        echo "spinnaker-gce-project"
        SPINNAKER_GCE_PROJECT="$1"
        shift
        ;;
      --config-bucket)
        echo "config-bucket"
        CONFIG_BUCKET="$1"
        shift
        ;;
      --user)
        echo "user"
        HAL_USER="$1"
        shift
        ;;
      --version)
        echo "version"
        HALYARD_VERSION="$1"
        shift
        ;;
      -y)
        echo "non-interactive"
        YES=true
        ;;
      --help|-help|-h)
        print_usage
        exit 13
        ;;
      *)
        echo "ERROR: Unknown argument '$key'"
        exit -1
    esac
  done
}

function get_user() {
  local user

  user=$(who -m | awk '{print $1;}')
  if [ -z "$YES" ]; then
    if [ "$user" = "root" ] || [ -z "$user" ]; then
      read -p "Please supply a non-root user to run Halyard as: " user
    fi
  fi

  echo $user
}

function configure_defaults() {
  if [ -z "$HAL_USER" ]; then
    HAL_USER=$(get_user)
  fi

  if [ -z "$HAL_USER" ]; then
    >&2 echo "You have not supplied a user to run Halyard as."
    exit 1
  fi

  if [ "$HAL_USER" = "root" ]; then
    >&2 echo "Halyard may not be run as root. Supply a user to run Halyard as: "
    >&2 echo "  sudo bash $0 --user <user>"
    exit 1
  fi

  set +e
  getent passwd $HAL_USER &> /dev/null

  if [ "$?" != "0" ]; then
    >&2 echo "Supplied user $HAL_USER does not exist"
    exit 1
  fi
  set -e

  if [ -z "$HALYARD_VERSION" ]; then
    HALYARD_VERSION="stable"
  fi

  echo "$(tput bold)Halyard version will be $HALYARD_VERSION $(tput sgr0)"

  if [ -z "$HALYARD_BUCKET_BASE_URL" ]; then
    HALYARD_BUCKET_BASE_URL="gs://spinnaker-artifacts/halyard"
  fi

  echo "$(tput bold)Halyard will be downloaded from $HALYARD_BUCKET_BASE_URL $(tput sgr0)"

  if [ -z "$CONFIG_BUCKET" ]; then
    CONFIG_BUCKET="halconfig"
  fi

  echo "$(tput bold)Halyard config will come from bucket gs://$CONFIG_BUCKET $(tput sgr0)"

  home=$(getent passwd $HAL_USER | cut -d: -f6)
  local halconfig_dir="$home/.hal"

  echo "$(tput bold)Halconfig will be stored at $halconfig_dir/config$(tput sgr0)"

  mkdir -p $halconfig_dir
  chown $HAL_USER $halconfig_dir

  mkdir -p /opt/spinnaker/config
  chmod +rx /opt/spinnaker/config

  cat > /opt/spinnaker/config/halyard.yml <<EOL
halyard:
  halconfig:
    directory: $halconfig_dir

spinnaker:
  artifacts:
    debianRepository: $SPINNAKER_REPOSITORY_URL
    dockerRegistry: $SPINNAKER_DOCKER_REGISTRY
    googleImageProject: $SPINNAKER_GCE_PROJECT
  config:
    input:
      bucket: $CONFIG_BUCKET
EOL

  echo $HAL_USER > /opt/spinnaker/config/halyard-user

  cat > $halconfig_dir/uninstall.sh <<EOL
#!/usr/bin/env bash

if [[ \`/usr/bin/id -u\` -ne 0 ]]; then
  echo "$0 must be executed with root permissions; exiting"
  exit 1
fi

read -p "This script uninstalls Halyard and deletes all of its artifacts, are you sure you want to continue? (Y/n): " yes

if [ "\$yes" != "y" ] && [ "\$yes" != "Y" ]; then
  echo "Aborted"
  exit 0
fi

rm /opt/halyard -rf
rm /var/log/spinnaker/halyard -rf

echo "Deleting halconfig and artifacts"
rm /opt/spinnaker/config/halyard* -rf
rm $halconfig_dir -rf
EOL

  chmod +x $halconfig_dir/uninstall.sh
  echo "$(tput bold)Uninstall script is located at $halconfig_dir/uninstall.sh$(tput sgr0)"
}


function print_usage() {
  cat <<EOF
usage: $0 [-y] [--version=<version>] [--user=<user>]
    -y                              Accept all default options during install
                                    (non-interactive mode).

    --halyard-bucket <name>         The bucket the Halyard JAR to be installed
                                    is stored in.

    --download-with-gsutil          If specifying a GCS bucket using
                                    --halyard-bucket, this flag causes the 
                                    install script to rely on gsutil and its 
                                    authentication to fetch the Halyard JAR.

    --config-bucket <name>          The bucket the your Bill of Materials and
                                    base profiles are stored in.

    --spinnaker-repository <url>    Obtain Spinnaker artifact debians from <url>
                                    rather than the default repository, which is
                                    $SPINNAKER_REPOSITORY_URL.

    --spinnaker-registry <url>      Obtain Spinnaker docker images from <url>
                                    rather than the default registry, which is
                                    $SPINNAKER_DOCKER_REGISTRY.

    --spinnaker-gce-project <name>  Obtain Spinnaker GCE images from <url>
                                    rather than the default project, which is
                                    $SPINNAKER_GCE_PROJECT.

    --version <version>             Specify the exact verison of Halyard to
                                    install.

    --user <user>                   Specify the user to run Halyard as. This
                                    user must exist.
EOF
}

function install_java() {
  set +e
  local java_version=$(java -version 2>&1 head -1)
  set -e

  if [[ "$java_version" == *1.8* ]]; then
    echo "Java is already installed & at the right version"
    return 0;
  fi

  if [ ! -f /etc/os-release ]; then
    >&2 "Unable to determine OS platform (no /etc/os-release file)"
    exit 1
  fi

  source /etc/os-release

  if [ "$ID" = "ubuntu" ]; then
    echo "Running ubuntu $VERSION_ID"
    # Java 8
    # https://launchpad.net/~openjdk-r/+archive/ubuntu/ppa
    add-apt-repository -y ppa:openjdk-r/ppa
    apt-get update ||:

    apt-get install -y --force-yes openjdk-8-jre

    # https://bugs.launchpad.net/ubuntu/+source/ca-certificates-java/+bug/983302
    # It seems a circular dependency was introduced on 2016-04-22 with an openjdk-8 release, where
    # the JRE relies on the ca-certificates-java package, which itself relies on the JRE. D'oh!
    # This causes the /etc/ssl/certs/java/cacerts file to never be generated, causing a startup
    # failure in Clouddriver.
    dpkg --purge --force-depends ca-certificates-java
    apt-get install ca-certificates-java
  elif [ "$ID" = "debian" ] && [ "$VERSION_ID" = "8" ]; then
    echo "Running debian 8 (jessie)"
    apt install -t jessie-backports openjdk-8-jre-headless ca-certificates-java
  elif [ "$ID" = "debian" ] && [ "$VERSION_ID" = "9" ]; then
    echo "Running debian 9 (stretch)"
    apt install -t stretch-backports openjdk-8-jre-headless ca-certificates-java
  else
    >&2 echo "Distribution $PRETTY_NAME is not supported yet - please file an issue"
    >&2 echo "  https://github.com/spinnaker/halyard/issues"
    exit 1
  fi
}

function install_halyard() {
  TEMPDIR=$(mktemp -d installhalyard.XXXX)
  pushd $TEMPDIR
  local gcs_bucket_and_file

  if [[ "$HALYARD_BUCKET_BASE_URL" != gs://* ]]; then
    >&2 echo "Currently installing halyard is only supported from a GCS bucket."
    >&2 echo "The --halyard-install-url parameter must start with 'gs://'."
    exit 1
  else
    gcs_bucket_and_file=${HALYARD_BUCKET_BASE_URL:5}/$HALYARD_VERSION/debian/halyard.tar.gz
  fi

  if [ -n "$DOWNLOAD_WITH_GSUTIL" ]; then
    gsutil cp gs://$gcs_bucket_and_file halyard.tar.gz
  else
    curl -O https://storage.googleapis.com/$gcs_bucket_and_file
  fi

  tar --no-same-owner --no-same-permissions -xvf halyard.tar.gz -C /opt

  groupadd halyard || true
  groupadd spinnaker || true
  usermod -G halyard -a $HAL_USER || true
  usermod -G spinnaker -a $HAL_USER || true
  chown $HAL_USER:halyard /opt/halyard

  mv /opt/hal /usr/local/bin
  chmod +x /usr/local/bin/hal

  if [ -f /opt/update-halyard ]; then
    mv /opt/update-halyard /usr/local/bin
    chmod +x /usr/local/bin/update-halyard
  else
    echo "No update script supplied with installer..."
  fi

  mkdir -p /var/log/spinnaker/halyard
  chown $HAL_USER:halyard /var/log/spinnaker/halyard
  chmod 755 /var/log/spinnaker/halyard

  popd
  rm -rf $TEMPDIR
}

check_migration_needed

process_args $@
configure_defaults

install_java
install_halyard

su -c "hal -v" -s /bin/bash $HAL_USER
