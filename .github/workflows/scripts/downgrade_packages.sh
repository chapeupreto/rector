#!/bin/bash
########################################################################
# This bash script downgrades the code to the selected PHP version
#
# Usage from within a GitHub workflow:
# .github/workflows/scripts/downgrade_packages.sh $target_php_version
# where $target_php_version is one of the following values:
# - 70 (for PHP 7.0)
# - 71 (for PHP 7.1)
# - 72 (for PHP 7.2)
# - 73 (for PHP 7.3)
# - 74 (for PHP 7.4)
#
# Currently highest PHP version from which we can downgrade:
# - 8.0
#
# Eg: To downgrade to PHP 7.1, execute:
# .github/workflows/scripts/downgrade_packages.sh 71
########################################################################
# Variables to modify when new PHP versions are released

supported_target_php_versions=(70 71 72 73 74)

declare -A downgrade_php_versions=( \
    [70]="7.1 7.2 7.3 7.4 8.0" \
    [71]="7.2 7.3 7.4 8.0" \
)
declare -A downgrade_php_whynots=( \
    [70]="7.0.* 7.1.* 7.2.* 7.3.* 7.4.*" \
    [71]="7.1.* 7.2.* 7.3.* 7.4.*" \
)
declare -A downgrade_php_sets=( \
    [70]="downgrade-php71 downgrade-php72 downgrade-php73 downgrade-php74 downgrade-php80" \
    [71]="downgrade-php72 downgrade-php73 downgrade-php74 downgrade-php80" \
)
declare -A package_excludes=( \
    ["rector/rector"]="$(pwd)/.docker/*';$(pwd)/.github/*';$(pwd)/bin/*';$(pwd)/ci/*';$(pwd)/docs/*';$(pwd)/tests/*';$(pwd)/**/tests/*';$(pwd)/packages/rector-generator/templates/*'" \
)

########################################################################
# Helper functions
# Failure helper function (https://stackoverflow.com/a/24597941)
function fail {
    printf '%s\n' "$1" >&2  ## Send message to stderr. Exclude >&2 if you don't want it that way.
    exit "${2-1}"  ## Return a code specified by $2 or 1 by default.
}

# Print array helpers (https://stackoverflow.com/a/17841619)
function join_by { local d=$1; shift; local f=$1; shift; printf %s "$f" "${@/#/$d}"; }
########################################################################

target_php_version=$1
if [ -z "$target_php_version" ]; then
    versions=$(join_by ", " ${supported_target_php_versions[@]})
    fail "Please provide to which PHP version to downgrade to ($versions) as first argument to the bash script"
fi

# Check the version is supported
if [[ ! " ${supported_target_php_versions[@]} " =~ " ${target_php_version} " ]]; then
    versions=$(join_by ", " ${supported_target_php_versions[@]})
    fail "Version $target_php_version is not supported for downgrading. Supported versions: $versions"
fi

target_downgrade_php_versions=($(echo ${downgrade_php_versions[$target_php_version]} | tr " " "\n"))
target_downgrade_php_whynots=($(echo ${downgrade_php_whynots[$target_php_version]} | tr " " "\n"))
target_downgrade_php_sets=($(echo ${downgrade_php_sets[$target_php_version]} | tr " " "\n"))

packages_to_downgrade=()
paths_to_downgrade=()
sets_to_downgrade=()

# Switch to production
composer install --no-dev

counter=1
while [ $counter -le ${#target_downgrade_php_versions[@]} ]
do
    pos=$(( $counter - 1 ))
    version=${target_downgrade_php_versions[$pos]}
    whynot=${target_downgrade_php_whynots[$pos]}
    set=${target_downgrade_php_sets[$pos]}
    echo Downgrading to PHP version "$version"

    # Obtain the list of packages for production that need a higher version that the input one.
    # Those must be downgraded
    PACKAGES=$(composer why-not php $whynot --no-interaction | grep -o "\S*\/\S*")
    if [ -n "$PACKAGES" ]; then
        for package in $PACKAGES
        do
            echo Analyzing package $package
            # Composer also analyzes the root project "rector/rector",
            # but its path is the root folder
            if [ $package = "rector/rector" ]
            then
                path=$(pwd)
            else
                # Obtain the package's path from Composer
                # Format is "package path", so extract the 2nd word with awk to obtain the path
                path=$(composer info $package --path | awk '{print $2;}')
            fi
            packages_to_downgrade+=($package)
            paths_to_downgrade+=($path)
            sets_to_downgrade+=($set)
        done
    else
        echo No packages to downgrade
    fi
    ((counter++))
done

# Switch to dev again
composer install

# Make sure that the number of packages, paths and sets is the same
# otherwise something went wrong
numberPackages=${#packages_to_downgrade[@]}
numberPaths=${#paths_to_downgrade[@]}
numberSets=${#sets_to_downgrade[@]}
if [ ! $numberPaths -eq $numberPackages ]; then
    fail "Number of paths ($numberPaths) and number of packages ($numberPackages) should not be different"
fi
if [ ! $numberSets -eq $numberPackages ]; then
    fail "Number of sets ($numberSets) and number of packages ($numberPackages) should not be different"
fi

# Execute Rector on all the paths
counter=1
while [ $counter -le $numberPackages ]
do
    pos=$(( $counter - 1 ))
    package_to_downgrade=${packages_to_downgrade[$pos]}
    path_to_downgrade=${paths_to_downgrade[$pos]}
    set_to_downgrade=${sets_to_downgrade[$pos]}
    exclude=${package_excludes[$package_to_downgrade]}

    # If more than one path, these are split with ";". Replace with space
    path_to_downgrade=$(echo "$path_to_downgrade" | tr ";" " ")
    exclude=$(echo "$exclude" | tr ";" " --exclude_paths=")

    echo "Running set ${set_to_downgrade} on package ${package_to_downgrade} on path(s) ${path_to_downgrade}"

    # Execute the downgrade
    # echo "bin/rector process $path_to_downgrade --set=$set_to_downgrade --exclude_paths=$exclude --dry-run --ansi"
    bin/rector process $path_to_downgrade --set=$set_to_downgrade --exclude_paths=$exclude --dry-run --ansi

    ((counter++))
done