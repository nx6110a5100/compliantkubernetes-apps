#!/bin/bash

# This file is not supposed to be executed on it's own, but rather is sourced
# by the other scripts in this path. It holds common paths and functions that
# are used throughout all of the scripts.

: "${CK8S_CONFIG_PATH:?Missing CK8S_CONFIG_PATH}"

# shellcheck disable=SC2034
ck8s_cloud_providers=(
    "aws"
    "baremetal"
    "citycloud"
    "exoscale"
    "safespring"
    "upcloud"
    "elastx"
)

# shellcheck disable=SC2034
ck8s_flavors=(
    "dev"
    "prod"
)

CK8S_AUTO_APPROVE=${CK8S_AUTO_APPROVE:-"false"}

# Create CK8S_CONFIG_PATH if it does not exist and make it absolute
mkdir -p "${CK8S_CONFIG_PATH}"
CK8S_CONFIG_PATH=$(readlink -f "${CK8S_CONFIG_PATH}")
export CK8S_CONFIG_PATH

here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
root_path="${here}/.."
config_template_path="${root_path}/config"
# TODO: these are used by sourced scripts.
# Should we export all "externally" used variables?
# shellcheck disable=SC2034
scripts_path="${root_path}/scripts"
# shellcheck disable=SC2034
pipeline_path="${root_path}/pipeline"

sops_config="${CK8S_CONFIG_PATH}/.sops.yaml"
state_path="${CK8S_CONFIG_PATH}/.state"
default_config_path="${CK8S_CONFIG_PATH}/defaults"
# shellcheck disable=SC2034
backup_config_path="${CK8S_CONFIG_PATH}/backups"

declare -A config
declare -A secrets

# Reserving for the merged config files.
config["config_file_wc"]=""
config["config_file_sc"]=""

config["default_common"]="${default_config_path}/common-config.yaml"
config["default_wc"]="${default_config_path}/wc-config.yaml"
config["default_sc"]="${default_config_path}/sc-config.yaml"

config["override_common"]="${CK8S_CONFIG_PATH}/common-config.yaml"
config["override_wc"]="${CK8S_CONFIG_PATH}/wc-config.yaml"
config["override_sc"]="${CK8S_CONFIG_PATH}/sc-config.yaml"

config["kube_config_sc"]="${state_path}/kube_config_sc.yaml"
config["kube_config_wc"]="${state_path}/kube_config_wc.yaml"

secrets["secrets_file"]="${CK8S_CONFIG_PATH}/secrets.yaml"
secrets["s3cfg_file"]="${state_path}/s3cfg.ini"

log_info_no_newline() {
    echo -e -n "[\e[34mck8s\e[0m] ${*}" 1>&2
}

log_info() {
    log_info_no_newline "${*}\n"
}

log_warning_no_newline() {
    echo -e -n "[\e[33mck8s\e[0m] ${*}" 1>&2
}

log_warning() {
    log_warning_no_newline "${*}\n"
}

log_error_no_newline() {
    echo -e -n "[\e[31mck8s\e[0m] ${*}" 1>&2
}

log_error() {
    log_error_no_newline "${*}\n"
}

# Merges all yaml files in order
# Usage: yq_merge <files...>
yq_merge() {
    # shellcheck disable=SC2016
    yq4 eval-all --prettyPrint 'explode(.) as $item ireduce ({}; . * $item )' "${@}"
}

# Reads the path to a block from one file containing the value
# Usage: yq_read_block <source> <value>
yq_read_block() {
    source=$1
    value=$2
    # shellcheck disable=SC2140
    yq4 ".. | select(tag != \"!!map\" and . == \"${value}\") | path |
    with(.[]; . = (\"\\\"\" + .) + \"\\\"\" ) |
    \".\" + join \".\"" "${source}" | \
             sed -r 's/\."[0-9]+".*//' | sed -r 's/\\//g' | uniq
}

# Copies a block from one file to another
# Usage: yq_copy_block <source> <target> <key>
yq_copy_block() {
    prefix=$(yq4 -n ".$3 | path | reverse | .[] as \$i ireduce(\".\"; \"{\\\"\" + \$i + \"\\\":\" + . + \"}\")")
    yq4 ".${3}" "${1}" -o json | \
    yq4 "${prefix}" | \
    yq4 eval-all 'select(fi == 0) * select(fi == 1)' -i "${2}" - --prettyPrint
}

# Usage: yq_copy_commons <source1> <source2> <target>
yq_copy_commons() {
    source1=$1
    source2=$2
    target=$3

    keys=$(yq_merge "${source1}" "${source2}" | \
           yq4 '.. | select(tag != "!!map") | path |
           with(.[]; . = ("\"" + .) + "\"" ) |
           join "."' | \
           sed -r 's/\."[0-9]+".*//' | \
           sed -r 's/\\//g' | \
           uniq)
    for key in ${keys}; do
        compare=$(diff <(yq4 -oj ".${key}" "${source1}" ) <(yq4 -oj ".${key}" "${source2}" ) || true)
        if [[ -z "${compare}" ]]; then
            value=$(yq4 ".${key}" "${source1}" )
            if [[ -z "${value}" ]]; then
                log_error "Unknown key to copy from: ${key}"
                exit 1
            fi
            yq_copy_block "${source1}" "${target}" "${key}"
        fi
    done
}

# Usage: yq_copy_changes <source1> <source2> <target>
yq_copy_changes() {
    source1=$1
    source2=$2
    target=$3

    keys=$(yq4 '.. | select(tag != "!!map") | path |
           with(.[]; . = ("\"" + .) + "\"" ) |
           join "."' "$source2" | \
           sed -r 's/\."[0-9]+".*//' | uniq)
    for key in ${keys}; do
        compare=$(diff <(yq4 -oj ".${key}" "${source1}" ) <(yq4 -oj ".${key}" "${source2}" ) || true)
        if [[ -n "${compare}" ]]; then
            if [[ -n "$(yq4 ".${key} | select(tag == \"\") | alias" "${source2}")" ]]; then
                # Creating placeholder for alias
                yq4 -i ".${key} = {}" "${target}"
            else
                yq_copy_block "${source2}" "${target}" "${key}"
            fi
        fi
    done

    anchors="$(yq4 '.. | select(anchor != "") | path | with(.[]; . = ("\"" + .) + "\"" ) | join "."' "${source2}")"
    for anchor in ${anchors}; do
        name="$(yq4 ".$anchor | anchor" "${source2}")"
        # Protecting anchor from unwanted change
        yq4 -i ".$anchor = (load(\"$source2\") | .$anchor)" "${target}"
        # Putting anchor in place
        yq4 -i ".$anchor anchor = \"$name\"" "${target}"
    done

    # The alias function will return leaf values, but they don't have a tag so filter on those
    aliases="$(yq4 '.. | select(tag == "") | alias | path | with(.[]; . = ("\"" + .) + "\"" ) | join "."' "${source2}")"
    for alias in ${aliases}; do
        name="$(yq4 ".$alias | alias" "${source2}")"
        # Putting alias in place
        yq4 -i ".$alias alias = \"$name\"" "${target}"
    done
}

# Usage: yq_copy_values <source1> <source2> <target> <value>
yq_copy_values() {
    source1=$1
    source2=$2
    target=$3
    value=$4

    keys=$(yq_read_block "${source1}" "${value}")
    for key in ${keys}; do
        compare=$(yq4 "${key}" "${source2}")
        if [[ "${compare}" == "null" ]]; then
            yq_copy_block "${source1}" "${target}" "${key:1}"
        fi
    done
}

array_contains() {
    local value="${1}"
    shift
    for element in "${@}"; do
        [ "${element}" = "${value}" ] && return 0
    done
    return 1
}

check_config()  {
    for config in "${@}"; do
        if [[ ! -f "${config}" ]]; then
            log_error "ERROR: could not find file ${config}"
            exit 1
        elif [[ ! ${config} =~ ^.*\.(yaml|yml) ]]; then
            log_error "ERROR: file ${config} must be a yaml file"
            exit 1
        fi
    done
}

# Usage: merge_config <default_config> <override_config> <merged_config>
# Merges the common-default, wc|sc-default, common-override, then wc|sc-override into one.
merge_config() {
    yq_merge "${config[default_common]}" "$1" "${config[override_common]}" "$2" > "$3"
}

# Usage: load_config <wc|sc>
# Loads and merges the configuration into a usable tempfile at config[config_file_<wc|sc>].
load_config() {
    check_config "${config[default_common]}" "${config[override_common]}"

    if [[ "${1}" == "sc" ]]; then
        check_config "${config[default_sc]}" "${config[override_sc]}"
        config[config_file_sc]=$(mktemp)
        append_trap "rm ${config[config_file_sc]}" EXIT
        merge_config "${config[default_sc]}" "${config[override_sc]}" "${config[config_file_sc]}"

    elif [[ "${1}" == "wc" ]]; then
        check_config "${config[default_wc]}" "${config[override_wc]}"
        config[config_file_wc]=$(mktemp)
        append_trap "rm ${config[config_file_wc]}" EXIT
        merge_config "${config[default_wc]}" "${config[override_wc]}" "${config[config_file_wc]}"

    else
        log_error "Error: usage load_config <wc|sc>"
        exit 1
    fi
}

version_get() {
    pushd "${root_path}" > /dev/null || exit 1
    git describe --exact-match --tags 2> /dev/null || git rev-parse HEAD
    popd > /dev/null || exit 1
}

# Check if the config version matches the current CK8S version.
# TODO: Simple hack to make sure version matches, we need to have a proper way
#       of making sure that the version is supported in the future.
validate_version() {
    version=$(version_get)
    if [[ "${1}" == "sc" ]]; then
        merged_config="${config[config_file_sc]}"
    elif [[ "${1}" == "wc" ]]; then
        merged_config="${config[config_file_wc]}"
    else
        echo log_error "Error: usage validate_version <wc|sc>"
        exit 1
    fi
    ck8s_version=$(yq4 '.global.ck8sVersion' "${merged_config}")
    if [[ -z "$ck8s_version" ]]; then
        log_error "ERROR: No version set. Run init to generate config."
        exit 1
    elif [ "${ck8s_version}" != "any" ] \
        && [ "${version}" != "${ck8s_version}" ]; then
        log_error "ERROR: Version mismatch. Run init to update config."
        log_error "Config version: ${ck8s_version}"
        log_error "CK8S version: ${version}"
        exit 1
    fi
}

# Make sure that all required configuration options are set in the config.
# TODO: Simple hack to make sure configuration is valid, we need to have a
#       proper way of making sure that the configuration is valid in the
#       future.
validate_config() {
    log_info "Validating $1 config"
    validate() {
        merged_config="${1}"
        template_config="${2}"

        # Loop all lines in ${template_config} and warns if same option is not available in ${merged_config}
        options=$(yq_read_block "${template_config}" "set-me")
        maybe_exit="false"
        for opt in ${options}; do
            compare=$(diff <(yq4 -oj "${opt}" "${template_config}") <(yq4 -oj "${opt}" "${merged_config}") || true)
            if [[ -z "${compare}" ]]; then
                log_warning "WARN: ${opt} is not set in config"
                maybe_exit="true"
            fi
        done

        if ${maybe_exit} && ! ${CK8S_AUTO_APPROVE}; then
            echo -n -e "[\e[34mck8s\e[0m] Do you want to abort? (y/n): " 1>&2
            read -r reply
            if [[ "${reply}" == "y" ]]; then
                exit 1
            fi
        fi
    }

    template_file=$(mktemp)
    append_trap "rm ${template_file}" EXIT

    if [[ $1 == "sc" ]]; then
        check_config "${config_template_path}/config/common-config.yaml" \
                     "${config_template_path}/config/sc-config.yaml" \
                     "${config_template_path}/secrets/sc-secrets.yaml"
        yq_merge "${config_template_path}/config/common-config.yaml" \
                 "${config_template_path}/config/sc-config.yaml" \
                  > "${template_file}"
        validate "${config[config_file_sc]}" "${template_file}"
        validate "${secrets[secrets_file]}" "${config_template_path}/secrets/sc-secrets.yaml"
    elif [[ $1 == "wc" ]]; then
        check_config "${config_template_path}/config/common-config.yaml" \
                     "${config_template_path}/config/wc-config.yaml" \
                     "${config_template_path}/secrets/wc-secrets.yaml"
        yq_merge "${config_template_path}/config/common-config.yaml" \
                 "${config_template_path}/config/wc-config.yaml" \
                  > "${template_file}"
        validate "${config[config_file_wc]}" "${template_file}"
        validate "${secrets[secrets_file]}" "${config_template_path}/secrets/wc-secrets.yaml"
    else
        log_error "ERROR: usage validate_config <sc|wc>"
        exit 1
    fi
}

validate_sops_config() {
    if [ ! -f "${sops_config}" ]; then
        log_error "ERROR: SOPS config not found: ${sops_config}"
        exit 1
    fi

    rule_count=$(yq4 '.creation_rules | length' "${sops_config}")
    if [ "${rule_count:-0}" -gt 1 ]; then
        log_error "ERROR: SOPS config has more than one creation rule."
        exit 1
    fi

    fingerprints=$(yq4 '.creation_rules[0].pgp' "${sops_config}")
    if ! [[ "${fingerprints}" =~ ^[A-Z0-9,' ']+$ ]]; then
        log_error "ERROR: SOPS config contains no or invalid PGP keys."
        log_error "fingerprints=${fingerprints}"
        log_error "Fingerprints must be uppercase and separated by colon."
        log_error "Delete or edit the SOPS config to fix the issue"
        log_error "SOPS config: ${sops_config}"
        exit 1
    fi
}

# Load and validate all configuration options from the config path.
# Usage: config_load <sc|wc> [sk]
config_load() {
    load_config "$1"

    if [[ "--skip-validation" != "${2:-''}" ]]; then
        validate_version "$1"
        validate_config "$1"
        validate_sops_config
    fi
}

# Normally a signal handler can only run one command. Use this to be able to
# add multiple traps for a single signal.
append_trap() {
    cmd="${1}"
    signal="${2}"

    if [ "$(trap -p "${signal}")" = "" ]; then
        # shellcheck disable=SC2064
        trap "${cmd}" "${signal}"
        return
    fi

    previous_trap_cmd() { printf '%s\n' "$3"; }

    new_trap() {
        eval "previous_trap_cmd $(trap -p "${signal}")"
        printf '%s\n' "${cmd}"
    }

    # shellcheck disable=SC2064
    trap "$(new_trap)" "${signal}"
}

# Write PGP fingerprints to SOPS config
sops_config_write_fingerprints() {
    yq4 -n ".creation_rules[0].pgp = \"${1}\"" > "${sops_config}" || \
      (log_error "ERROR: Failed to write fingerprints" && rm "${sops_config}" && exit 1)
}

# Encrypt stdin to file. If the file already exists it's overwritten.
sops_encrypt_stdin() {
    sops --config "${sops_config}" -e --input-type "${1}" \
         --output-type "${1}" /dev/stdin > "${2}"
}

# Encrypt a file in place.
sops_encrypt() {
    # https://github.com/mozilla/sops/issues/460
    if grep -F -q 'sops:' "${1}" || \
        grep -F -q '"sops":' "${1}" || \
        grep -F -q '[sops]' "${1}" || \
        grep -F -q 'sops_version=' "${1}"; then
        log_info "Already encrypted ${1}"
        return
    fi

    log_info "Encrypting ${1}"

    sops --config "${sops_config}" -e -i "${1}"
}

# Check that a file exists and is actually encrypted using SOPS.
sops_decrypt_verify() {
    if [ ! -f "${1}" ]; then
        log_error "ERROR: Encrypted file not found: ${1}"
        exit 1
    fi

    # https://github.com/mozilla/sops/issues/460
    if ! grep -F -q 'sops:' "${1}" && \
       ! grep -F -q '"sops":' "${1}" && \
       ! grep -F -q '[sops]' "${1}" && \
       ! grep -F -q 'sops_version=' "${1}"; then
        log_error "NOT ENCRYPTED: ${1}"
        exit 1
    fi
}

# Decrypt a file in place and encrypt it again at exit.
#
# Run this inside a sub-shell to encrypt the file again as soon as it's no
# longer used. For example:
# (
#   sops_decrypt config
#   command --config config
# )
# TODO: This is bad since it makes the decrypted secrets touch the filesystem.
#       We should try to remove this asap.
sops_decrypt() {
    log_info "Decrypting ${1}"

    sops_decrypt_verify "${1}"

    sops --config "${sops_config}" -d -i "${1}"
    append_trap "sops_encrypt ${1}" EXIT
}

# Temporarily decrypts a file and runs a command that can read it once.
sops_exec_file() {
    sops_decrypt_verify "${1}"

    sops --config "${sops_config}" exec-file "${1}" "${2}"
}

# The same as sops_exec_file except the decrypted file is written as a normal
# file on disk while it's being used.
# This should only be used if absolutely necessary, for example where the
# decrypted file needs to be read more than once.
# TODO: Try to eliminate this in the future.
sops_exec_file_no_fifo() {
    sops_decrypt_verify "${1}"

    sops --config "${sops_config}" exec-file --no-fifo "${1}" "${2}"
}

# Temporarily decrypts a file and loads the content as environment variables
# that will only be available to a command.
sops_exec_env() {
    sops_decrypt_verify "${1}"

    sops --config "${sops_config}" exec-env "${1}" "${2}"
}

# Run a command with the secrets config options available as environment
# variables.
with_config_secrets() {
    sops_decrypt_verify "${secrets[secrets_file]}"

    sops_exec_env "${secrets[secrets_file]}" "${*}"
}


# Run a command with KUBECONFIG set to a temporarily decrypted file.
with_kubeconfig() {
    kubeconfig="${1}"
    shift

    if [ ! -f "${kubeconfig}" ]; then
      log_error "ERROR: Kubeconfig not found: ${kubeconfig}"
      exit 1
    fi

    if grep -F -q 'sops:' "${kubeconfig}" || \
        grep -F -q '"sops":' "${kubeconfig}" || \
        grep -F -q '[sops]' "${kubeconfig}" || \
        grep -F -q 'sops_version=' "${kubeconfig}"; then
        log_info "Using encrypted kubeconfig ${kubeconfig}"

        # TODO: Can't use a FIFO since we can't know that the kubeconfig is not
        #       read multiple times. Let's try to eliminate the need for writing
        #       the kubeconfig to disk in the future.
        sops_exec_file_no_fifo "${kubeconfig}" 'KUBECONFIG="{}" '"${*}"
    else
        log_info "Using unencrypted kubeconfig ${kubeconfig}"
        # shellcheck disable=SC2048
        KUBECONFIG=${kubeconfig} ${*}
    fi
}

# Runs a command with S3COMMAND_CONFIG_FILE set to a temporarily decrypted
# file.
with_s3cfg() {
    s3cfg="${1}"
    shift
    # TODO: Can't use a FIFO since the s3cfg is read mulitiple times when a
    #       bucket needs to be created.
    sops_exec_file_no_fifo "${s3cfg}" 'S3COMMAND_CONFIG_FILE="{}" '"${*}"
}
