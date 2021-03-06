#!/bin/bash
set -e
set -u
set -o pipefail

# ----------------------------------------------------------------------------------------------------------------------
# resolve_version()
#
# Resolves the version of a release artifact. Projects are free to implement this any way they see necessary.
#
# Args:
#   - None
#
# Returns:
#   String indicating the version of the release artifact.
#
resolve_version() {
  local result=$( \
    grep version gradle.properties | \
    awk -F= '{print $2}' | \
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  )

  echo "$result"
}

# ----------------------------------------------------------------------------------------------------------------------
# before_packer()
#
# Custom logic that needs to be executed before the packer process begins, for example, moving one or more files into
# a different directory.
#
# Args:
#   - None
#
# Returns:
#   - None
#
before_packer() {
  mkdir -p dist/files
  cp discovery-*/build/distributions/discovery-*-${version}.tgz dist/files/
  cd dist/
}

# ----------------------------------------------------------------------------------------------------------------------
# Configurable parameters
#
# OK to edit these as necessary.
#
# 'build_dir'         - directory where packer builder should store state or configuration generated for the build.
# 'template_file'     - the packer template file containing instructions for packer to process.
# 'variable_file'     - the file that will contain generated variables for packer to use in the ${template_file}.
# 'discovery_version' - the version of the discovery service being baked

build_dir=build
template_file="packer.json"
variable_file="${build_dir}/packer-vars.json"
version=$(resolve_version)

# ----------------------------------------------------------------------------------------------------------------------
# Operational parameters
#
# Do NOT modify unless you understand what you're doing.
#
# 'is_travis' indicates whether we are running on Travis CI or not
# 'build_token' a unique token generated for the build and only used when default values need to be generated.
# 'build_runner' the name of the build runner (basically $USER).
# 'build_number' the number of the build being run.
# 'build_branch' the name of the branch being build against.
# 'build_commit' the Git commit for the current build or snapshot-$(build_token).
# 'packer_exec' the name or path of alternative packer.io binary; useful in RedHat land where a packer binary already exists on the OS and a different name must be used.

is_travis=${TRAVIS:=false}
build_branch=${TRAVIS_BRANCH:=$(git rev-parse --abbrev-ref HEAD)}
build_pull_request=${TRAVIS_PULL_REQUEST:="false"}
build_token=$(python  -c 'import uuid; print str(uuid.uuid4()).replace("-", "")')
build_number=${TRAVIS_BUILD_NUMBER:="snapshot"}
build_commit=${TRAVIS_COMMIT:="snapshot-${build_token}"}

packer_exec=${PACKER_EXEC:="packer"}

if [[ "$is_travis" == "true" && "$build_pull_request" == "true" ]]; then
    echo "--> Skipping AMI creation: Pull Request (branch: $build_branch, pull: $build_pull_request)"
    exit 0
fi

if [ "$is_travis" = "true" ]; then build_runner="travis"; else build_runner=${USER:="unknown"}; fi

echo "--> Building service images"
echo "--  travis = '${is_travis}'"
echo "--  branch = '${build_branch}'"
echo "--  number = '${build_number}'"
echo "--  runner = '${build_runner}'"
echo "--  commit = '${build_commit}'"
echo "--  discovery version = '${version}'"

echo "--> Generating build variables"
mkdir -p ${build_dir}
cat << EOF > "${variable_file}"
{
  "build_number": "${build_number}",
  "builder": "${build_runner}",
  "branch": "${build_branch}",
  "commit": "${build_commit}",
  "discovery_version": "${version}"
}
EOF
echo "--  Generated build variables"

echo "--> Validating and building packer template"

before_packer

${packer_exec} validate -var-file=../${variable_file} ${template_file}
${packer_exec} build -machine-readable -var-file=../${variable_file} ${template_file} | tee packer.log

echo "--> Done!"