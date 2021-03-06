#!/usr/bin/env bash
#
# This script will compile the deb packages for the package names given as
# argument using the most recent source available in the Debian sid
# repositories for the specified version of Ubuntu or Debian.
#
# The version of Ubuntu or Debian specified does not have to be the same as the
# installed version of Ubuntu or Debian because the packages will be built in a
# chrooted environment using pbuilder-dist. This assumes that your Ubuntu or
# Debian version has the required package dependency versions available (which
# for xrdp and xorgxrdp it likely will).
#
# This allows you to upgrade to a more recent version of xrdp than is available
# in the system repositories.
#
# The downloaded source packages are verified using the Debian GPG keys. The
# compiled deb packages can be installed with `apt-get install -f` as usual.
#
# This script will prompt for a sudo password because it calls pbuilder-dist.
#
# Example: To compile the version of xrdp currently available in Debian sid for
# Ubuntu 20.04 LTS run the following:
# $ builder.sh build focal xrdp
#
# This script will then download the source package of xrdp from the
# repositories of Debian sid. The xrdp source package will be verified using
# the Debian GPG keys. A pbuilder environment will be created for Ubuntu 20.04.
# This will work even if the system is running a different version of Ubuntu or
# distribution, such as Ubuntu 21.10 or Debian 11. Thus a single system can
# generate deb packages for multiple different systems.
#
# Multiple packages can be downloaded and with a single run of the script.
#
# Example:
# $ builder.sh build focal xrdp xorgxrdp
#
# The packages will be built in the order written, i.e., first xrdp then
# xorgxrdp. Because xorgxrdp depends on xrdp, we need to first build xrdp then
# xorgxrdp in that order.
#
# If you already have pbuilder or pbuilder-dist configured on your system then
# this script ignore the any configuration or existing distribution base.tgz.
#
# This script creates three sub-directories in the same directory as this
# script:
#  - The 'source-packages' directory will contain the downloaded source
#    packages.
#  - The 'DIST-deb-packages' directory will contain the deb packages built for
#    the Ubuntu or Debian release with codename DIST.
#  - The 'pbuilder-working-dir' directory is the working directory for pbuilder
#    and contains all pbuilder files.
#
# One way to archive the source packages and deb packages is to check them into
# version control: check this script into a git repository, and commit any new
# source packages and deb packages in the 'source-packages' and 'deb-packages'
# directories each time the script is run. The 'pbuilder-working-dir' directory
# should be added to the .gitignore file.
#
# You can search for the most recent version of a package on the Debian Package
# Tracker: https://tracker.debian.org/
#
# Running this script again with the same arguments will fetch the most recent
# versions of the packages and build the corresponding deb packages.
#

set -o pipefail

#
# Directory that contains this script.
#
script_dir="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

#
# Root all the files created by pbuilder-dist in the specified directory to
# keep things tidy.
#
# pbuilder-dist will store all the files it generates in directory set by the
# PBUILDFOLDER environment variable. See man pbuilder-dist.
#
export PBUILDFOLDER="$script_dir/pbuilder-working-dir"

#
# Print the help message.
#
function print_help
{
    echo "Build source packages from Debian unstable."
    echo
    echo "Available commands:"
    echo "    build DIST PACKAGES...    Build the packages for the specified distribution,"
    echo "                              where DIST is the codename of the version of Ubuntu"
    echo "                              or Debian and PACKAGES... is the packages to build."
    echo
    echo "    clean                     Delete all temporary files."
    echo "    clean DIST                Delete all temporary files for the specified"
    echo "                              distribution only."
    echo
    echo "    help                      Show this help screen."
    echo
    echo "Examples:"
    echo "    $0 build focal xrdp xorgxrdp"
    echo "    $0 build buster xrdp"
}

#
# Command line options.
#
if [[ "$#" -eq 0 || ("$#" -eq 1 && "$1" = "help") ]]
then
    print_help
    exit 0
elif [[ "$#" -eq 1 && "$1" = "clean" ]]
then
    rm -rf "$PBUILDFOLDER"
    exit 0
elif [[ "$#" -eq 2 && "$1" = "clean" ]]
then
    #
    # Check whether the distribution has been previously downloaded by checking
    # fpr the file $PBUILDFOLDER/${2}-base.tgz.
    #
    if [ -f "$PBUILDFOLDER/${2}-base.tgz" ]
    then
        #
        # These paths depend on the directory layout we use in the script below
        # and on the names of the files generated by pbuilder-dist.
        #
        rm -f "$PBUILDFOLDER/${2}-base.tgz"
        rm -rf "$PBUILDFOLDER/${2}_build_result"
        rm -rf "$PBUILDFOLDER/${2}_result"
        exit 0
    else
        >&2 echo "ERROR: No files for distribution $2."
        exit 1
    fi
elif [[ "$#" -lt 3 || "$1" != "build" ]]
then
    print_help
    exit 1
fi

#
# The packages to be built in order (starting from third argument).
#
packages_to_build="${@:3}"

#
# We call this variable debian_dist so as not to get it confused with the DIST
# variable set by pbuilder and exported to the .pbuilderrc and hook files.
#
debian_dist="$2"
#
# We do not want to maintain a list of valid codenames but instead check if the
# codename is all lowercase letters and no spaces.
#
if [[ ! $debian_dist =~ ^[a-z]+$ ]]
then
    >&2 echo "ERROR: Not a valid Ubuntu or Debian codename."
    exit 1
fi

#
# Checks that the named external program exists on the path, and if not exits.
#
# param: $program_name - name of the executable that must be on the path.
#
function require_program
{
    local readonly program_name="$1"
    if ! command -v $program_name &> /dev/null
    then
        >&2 echo "ERROR: ${program_name} could not be found."
        exit 1
    fi
}

#
# Check that the required programs are installed on the PATH so that the script
# does not fail halfway through.
#
require_program rsync
require_program pull-debian-source
require_program dscverify
require_program pbuilder-dist

#
# Directory to which the source packages will be downloaded.
#
source_package_dir="$script_dir/source-packages"

#
# Directory to which the Debian binary packages will be put.
#
deb_package_output_dir="$script_dir/${debian_dist}-deb-packages"

if [ ! -d "$PBUILDFOLDER" ]
then
    echo "Creating PBUILDFOLDER directory."
    mkdir -p "$PBUILDFOLDER"
    if [ $? -ne 0 ]
    then
        >&2 echo "ERROR: Could not create PBUILDFOLDER directory."
        exit 1
    fi
fi

#
# The directory for the resultant files of the pbuilder build. This directory
# will be created by pbuilder-dist.
#
build_result_dir="$PBUILDFOLDER/${debian_dist}_build_result"

#
# Directory containing the .pbuilderrc file and the hooks directory.
#
config_dir="$PBUILDFOLDER/config"
config_file="$config_dir/.pbuilderrc"

#
# Hooks directory containing the single hook file we need.
#
hooks_dir="$config_dir/pbuilder-hooks"
hook_file="$hooks_dir/D10addsource"

#
# Directory to store the Debian keyring file.
#
keyring_dir="$PBUILDFOLDER/keyring"

#
# Make directories that do not exist.
#
[ -d $build_result_dir ] || mkdir $build_result_dir
[ -d $source_package_dir ] || mkdir $source_package_dir
[ -d $deb_package_output_dir ] || mkdir $deb_package_output_dir
[ -d $config_dir ] || mkdir $config_dir
[ -d $hooks_dir ] || mkdir $hooks_dir
[ -d $keyring_dir ] || mkdir $keyring_dir

#
# Download the current keyring for verifying packages.
#
rsync -az keyring.debian.org::keyrings/keyrings/debian-keyring.gpg "$keyring_dir"
if [ $? -ne 0 ]
then
    >&2 echo "ERROR: Could not download Debian keyring."
    exit 1
fi

#
# Make `.pbuilderrc` remembering to escape dollar where necessary.
#
# There is not good way to obtain the build result directory from within
# `.pbuilderrc` when writing a standalone `.pbuilderrc` file because
# `pbuilder-dist` does not export an environment variable with the build result
# directory. This can be confirmed by inspecting the output of `printenv`.
# However, in this case we are generating it with a heredoc and so can just
# hardcode it into the generated file.
#
# We check the existence of the directory to aid debugging in case anything
# goes wrong.
#
# The pbuilder-dist man page says that the default build result directory is
# `~/pbuilder/` unless the `--buildresult` option or the `PBUILDFOLDER`
# environment variable is set.
#
# Need to change working directory to $BUILDRESULT before running
# `apt-ftparchive` so that the path of the filenames in the Packages file are
# relative to $BUILDRESULT.
#
# Mount the $BUILDRESULT directory can be used as a local directory within the
# chroot.
#
cat << EOF > "$config_file"
BUILDRESULT="$build_result_dir"
if [ -d "\$BUILDRESULT" ]
then
    echo "INFO: Assuming build result directory located at '\$BUILDRESULT'."
else
    echo "ERROR: Build result directory '\$BUILDRESULT' does not exist."
    exit 1
fi
( cd \$BUILDRESULT; apt-ftparchive packages . > \$BUILDRESULT/Packages )
BINDMOUNTS="\$BUILDRESULT"
HOOKDIR="$hooks_dir"
EOF

#
# Generate the hook file.
#
# The first 7 lines are the same as the above heredoc.
#
# The purpose of the hook is to add the previously build packages from the
# build result directory satisfy dependencies.
#
# We need to manually add the local repository to /etc/apt/sources.list
# because setting OTHERMIRROR has not effect.
# See https://bugs.launchpad.net/ubuntu/+source/ubuntu-dev-tools/+bug/1004579
#     https://bugs.launchpad.net/ubuntu/+source/ubuntu-dev-tools/+bug/371221
#
cat << EOF > "$hook_file"
BUILDRESULT="$build_result_dir"
if [ -d "\$BUILDRESULT" ]
then
    echo "INFO: Assuming build result directory located at '\$BUILDRESULT'."
else
    echo "ERROR: Build result directory '\$BUILDRESULT' does not exist."
    exit 1
fi
echo "deb [trusted=yes] file:\$BUILDRESULT ./" >> /etc/apt/sources.list
apt-get update
EOF

#
# The hook file needs execute permission set.
#
chmod +x "$hook_file"

#
# Map from a package to the filename (excluding file extension).
#
declare -A package_filename

#
# Download each source packages from Debian sid into the source directory.
#
# We could have instead taken the source packages from another Ubuntu version.
# For example:
# $ pull-lp-source xrdp jammy
#
# Get the packages with `--download-only` to skip extracting the package. We
# skip verifying the packages because we do this separately using the most
# recent GPG keys.
#
pushd "$source_package_dir"
for p in $packages_to_build
do
    #
    # Output from pull-debian-source when package already in working directory:
    # $ pull-debian-source --download-only --no-verify-signature xorgxrdp
    # Found xorgxrdp 1:0.2.17-1 in sid
    # Downloading xorgxrdp_0.2.17.orig.tar.gz from deb.debian.org (0.469 MiB)
    # Downloading xorgxrdp_0.2.17-1.debian.tar.xz from deb.debian.org (0.007 MiB)
    #
    # Output from pull-debian-source when package not in working directory:
    # $ pull-debian-source --download-only --no-verify-signature xorgxrdp
    # Found xorgxrdp 1:0.2.17-1 in sid
    #
    # We obtain the version of the package from the first line of output (there
    # does not seem to be a better way).
    #
    # Get the version from the first line output while still printing the
    # output to the terminal.
    #
    # Pipeline errors were set to not be masked above (hence error code check).
    #
    { version=$(pull-debian-source --no-verify-signature --download-only $p 2>&1 | tee /dev/fd/3 | grep "^Found" | cut -d' ' -f3); } 3>&1
    if [ $? -ne 0 ]
    then
        >&2 echo "ERROR: Failed to pull $p."
        exit 1
    fi

    #
    # Remove the epoch: from the version number (e.g., xorgxrdp current has
    # Debian version 1:0.2.17-1. See `man deb-version` for details.
    #
    version=${version#*:}

    filename="${p}_${version}.dsc"
    package_filename[$p]="${p}_${version}"

    #
    # Check the file exists: if it does not then something has gone wrong
    # (e.g., we did not extract the version correctly from the output).
    #
    if [ ! -f "$filename" ]
    then
        >&2 echo "ERROR: File $filename does not exist for package $p."
        exit 1
    fi

    #
    # Verify the package with the current set of keys.
    #
    dscverify --keyring "$keyring_dir/debian-keyring.gpg" "$filename"
    if [ $? -ne 0 ]
    then
        >&2 echo "ERROR: Failed to verify $filename for package $p."
        exit 1
    fi
done
popd

#
# If the distribution for the environment does not exist then create it,
# otherwise update it.
#
pbuilder_operation="create"
if [ -f "$PBUILDFOLDER/$debian_dist-base.tgz" ]
then
    pbuilder_operation="update"
fi

#
# We specify `--configfile` here because we do not want to use the
# `.pbuilderrc` in the home directory if it exists.
#
pbuilder-dist $debian_dist $pbuilder_operation --configfile "$config_file"
if [ $? -ne 0 ]
then
    >&2 echo "ERROR: Failed to $pbuilder_operation $debian_dist environment."
    exit 1
fi

#
# Build each package and copy to the $deb_package_output_dir directory.
#
for p in $packages_to_build
do
    echo "===================================================================="
    echo "== Running pbuilder for package $p"
    echo "===================================================================="

    pbuilder-dist $debian_dist build --configfile "$config_file" --buildresult "$build_result_dir" "$source_package_dir/${package_filename[$p]}.dsc"
    if [ $? -ne 0 ]
    then
        >&2 echo "ERROR: Failed to build $p."
        exit 1
    fi

    #
    # The deb package filename has the format package_version_arch.deb.
    #
    # TODO: Here we assume that the architecture is amd64. We should check this
    # and not just assume it (although the script will exit with an error if
    # that assumption is wrong).
    #
    debfilename="${package_filename[$p]}_amd64.deb"
    cp "$build_result_dir/$debfilename" "$deb_package_output_dir"
    if [ $? -ne 0 ]
    then
        >&2 echo "ERROR: Failed to copy $debfilename to $deb_package_output_dir."
        exit 1
    fi
done

echo "Done."
