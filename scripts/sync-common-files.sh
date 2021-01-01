#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

# -----------------------------------------------------------------------------
# Globals
# -----------------------------------------------------------------------------
declare -r SCRIPT=${0##*/}
declare -r VERSION=0.4.1
declare -r SCRIPT_DIR=$(readlink --canonicalize $(dirname ${0}))
declare -r BASE_DIR=$(readlink --canonicalize $(dirname ${0})/..)
declare -r COMMONFILES_DIR="${BASE_DIR}/CommonFiles"
declare -r INCLUDES_DIR="${COMMONFILES_DIR}/_includes"
declare -r TIMESTAMP=$(date +%F)
declare -r LINE=$(printf "%0.1s" -{1..80})
declare -r POWERSHELL=$(which pwsh 2>/dev/null || which powershell 2>/dev/null)
declare -g BRANCH=sync/update-${TIMESTAMP}
declare -g DISPLAY_PORT=:7777
declare -g MESSAGE="Sync common files - ${TIMESTAMP}"
declare -g BUILD_METHOD=powershell
declare -g NO_PR=false
declare -g FORCE=
declare -g TEMPLATE=false
declare -g START_X=false
declare -g NO_BUILD=false
declare -a REPOS=()

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------
function start_x() {
  [[ ${START_X} == false ]] && return 0
  export DISPLAY=${DISPLAY_PORT}
  pkill -f "Xvfb ${DISPLAY}" || :
  sleep 1
  Xvfb ${DISPLAY} -ac &
}

# -----------------------------------------------------------------------------

function build_with_powershell() {
  ${POWERSHELL} -ExecutionPolicy ByPass -File Other/Update/Update.ps1
}

# -----------------------------------------------------------------------------

function build_with_docker() {
  ${SCRIPT_DIR}/docker-build.sh --up-release
}

# -----------------------------------------------------------------------------

function build_release() {
  case ${BUILD_METHOD} in
  docker) build_with_docker;;
  *)      build_with_powershell;;
  esac
}

# -----------------------------------------------------------------------------

function sync_repo() {
  local dir=${1}
  cd ${dir}
  git checkout master
  git fetch --all
  git pull origin master
  if git branch | grep -q "sync/update-${TIMESTAMP}"; then
    git checkout ${BRANCH}
  else
    git checkout -b ${BRANCH}
  fi
  rsync -av --exclude=${INCLUDES_DIR##*/} ${COMMONFILES_DIR}/./ .
  replace_includes
  replace_placeholders ${dir}
  git add .
  git status
  if ! git commit -a -m "${MESSAGE}"; then
    git checkout master
    git branch -D ${BRANCH}
  else
    [[ ${NO_BUILD} == false ]] && build_release
    git push ${FORCE:+--force} origin ${BRANCH}
    create_pull_request
    git checkout master
  fi
}

# -----------------------------------------------------------------------------

function create_pull_request() {
  [[ ${NO_PR} == true ]] && return 0
  hub pull-request -p -b ${BRANCH} -m "${MESSAGE}"
}

# -----------------------------------------------------------------------------

function replace_placeholders() {
  local dir=${1}; shift;
  local app_name=${dir##*/}
  [[ ${app_name} =~ Template$ ]] && return 0
  sed -i "s/{{ AppName }}/${app_name}/g" README.md
}

# -----------------------------------------------------------------------------

function replace_includes() { 
  for file in $(find ${INCLUDES_DIR} -name "*.md"); do
    local basename=${file##*/}
    local start="<!-- Start include ${basename} -->"
    local end="<!-- End include ${basename} -->"
    sed -i -e "/${start}/,/${end}/{
      /${start}/!{
        /${end}/!d;
        e cat '${file}'
      } 
    }" README.md 
    
  done
}

# -----------------------------------------------------------------------------

function print_header() {
   local ${repo_name}=${1}
   echo
   echo ${LINE}
   echo ${repo_name}
   echo ${LINE}
}

# -----------------------------------------------------------------------------

function sync_repos() {
  local -a modules=( ${@} )
  cd ${BASE_DIR}
  if [[ ${TEMPLATE} == true ]]; then
    modules=$(ls -d *Template)
  elif [[ -z ${modules:-} ]]; then
    modules=$(ls -d *Portable)
  fi
  for repo_name in ${modules[@]}; do
    print_header "${repo_name}"
    ( sync_repo "${repo_name}"; )
  done
}

# -----------------------------------------------------------------------------

function usage() {
  local exit_code=${1:-1}; shift;
  cat <<USAGE

  Usage:
    ${SCRIPT} [-X] [-h] [directory [..]]

  Options:
    -h | --help       This message
    -d | --docker     Build with docker instead of powershell
    -f | --force      Force the git push to the remote repository
    -m | --message    Set commit message for Git commit
                      Default: "${MESSAGE}"
    -B | --no-build   Do not build the installer package.
    -T | --template   Only sync with the template repository.
    -P | --no-pr      Do not create a pull-request.
    -X | --start-x    Start a hidden X server for the build to go through.

USAGE
  exit ${exit_code}
}

# -----------------------------------------------------------------------------

function parse_options() {
  while [[ ${#} -gt 0 ]]; do
    case ${1} in
    -d|--docker)   BUILD_METHOD=docker;;
    -f|--force)    FORCE=true;;
    -m|--message)  shift; MESSAGE="${1}";;
    -X|--start-x)  START_X=true;;
    -B|--no-build) NO_BUILD=true;;
    -T|--template) NO_BUILD=true; TEMPLATE=true;;
    -P|--no-pr)    NO_PR=true;;
    -h|--help)    usage 0;;
    *Portable)    REPOS=( ${REPOS[@]:-} ${1} );;
    *)           usage 1;;
    esac
    shift
  done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
parse_options "${@}"
start_x
sync_repos "${REPOS[@]}"
