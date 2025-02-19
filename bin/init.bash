#!/bin/bash

# This script takes care of initializing a CK8S configuration path for apps.
# It writes the default configuration files to the config path and generates
# some defaults where applicable.
# It's not to be executed on its own but rather via `ck8s init`.

set -eu -o pipefail

here="$(dirname "$(readlink -f "$0")")"
# shellcheck source=bin/common.bash
source "${here}/common.bash"

# Load cloud provider, environment name, and flavor from config if available.
if [ -f "${config[default_common]}" ]; then
    cloud_provider=$(yq4 '.global.ck8sCloudProvider' "${config[default_common]}")
    environment_name=$(yq4 '.global.ck8sEnvironmentName' "${config[default_common]}")
    flavor=$(yq4 '.global.ck8sFlavor' "${config[default_common]}")
fi
if [ -z "${cloud_provider:-}" ]; then
    : "${CK8S_CLOUD_PROVIDER:?Missing CK8S_CLOUD_PROVIDER}"
elif [ -v CK8S_CLOUD_PROVIDER ] && [ "${CK8S_CLOUD_PROVIDER}" != "${cloud_provider}" ]; then
    log_error "ERROR: Cloud provider mismatch, '${cloud_provider}' in config and '${CK8S_CLOUD_PROVIDER}' in env"
    exit 1
else
    export CK8S_CLOUD_PROVIDER="${cloud_provider}"
fi
if [ -z "${environment_name:-}" ]; then
    : "${CK8S_ENVIRONMENT_NAME:?Missing CK8S_ENVIRONMENT_NAME}"
elif [ -v CK8S_ENVIRONMENT_NAME ] && [ "${CK8S_ENVIRONMENT_NAME}" != "${environment_name}" ]; then
    log_error "ERROR: Environment name mismatch, '${environment_name}' in config and '${CK8S_ENVIRONMENT_NAME}' in env"
    exit 1
else
    export CK8S_ENVIRONMENT_NAME="${environment_name}"
fi
if [ -z "${flavor:-}" ]; then
    : "${CK8S_FLAVOR:?Missing CK8S_FLAVOR}"
elif [ -v CK8S_FLAVOR ] && [ -n "${CK8S_FLAVOR}" ] && [ "${CK8S_FLAVOR}" != "${flavor}" ]; then
    log_error "ERROR: Environment flavor mismatch, '${flavor}' in config and '${CK8S_FLAVOR}' in env"
    exit 1
else
    export CK8S_FLAVOR="${flavor}"
fi

# Validate the cloud provider
if ! array_contains "${CK8S_CLOUD_PROVIDER}" "${ck8s_cloud_providers[@]}"; then
    log_error "ERROR: Unsupported cloud provider: ${CK8S_CLOUD_PROVIDER}"
    log_error "Supported providers: ${ck8s_cloud_providers[*]}"
    exit 1
fi

# Validate the flavor
if ! array_contains "${CK8S_FLAVOR}" "${ck8s_flavors[@]}"; then
    log_error "ERROR: Unsupported flavor: ${CK8S_FLAVOR}"
    log_error "Supported flavors: ${ck8s_flavors[*]}"
    exit 1
fi

generate_sops_config() {
    if [ -n "${CK8S_PGP_FP:-}" ]; then
        if ! gpg --list-keys | grep "${CK8S_PGP_FP}" > /dev/null 2>&1; then
            log_error "ERROR: Fingerprint does not exist in gpg keyring."
            log_error "CK8S_PGP_FP=${CK8S_PGP_FP}"
            exit 1
        fi
        fingerprint="${CK8S_PGP_FP}"
    elif [ -n "${CK8S_PGP_UID:-}" ]; then
        fingerprint=$(gpg --list-keys --with-colons "${CK8S_PGP_UID}" | \
                      awk -F: '$1 == "fpr" {print $10;}' | head -n 1 || \
                      echo "")
        if [ -z "${fingerprint}" ]; then
            log_error "ERROR: Unable to get fingerprint from gpg keyring using UID."
            log_error "CK8S_PGP_UID=${CK8S_PGP_UID}"
            exit 1
        fi
    else
        log_error "ERROR: CK8S_PGP_FP and CK8S_PGP_UID can't both be unset"
        exit 1
    fi

    log_info "Initializing SOPS config with PGP fingerprint: ${fingerprint}"

    sops_config_write_fingerprints "${fingerprint}"
}

# Only writes value if it is set to "set-me"
# Usage: replace_set_me <file> <field> <value>
replace_set_me(){
    if [[ $# -ne 3 ]]; then
        log_error "ERROR: number of args in replace_set_me must be 3. #=[$#]"
        exit 1
    fi
    if [[ $(yq4 "${2}" "${1}") == "set-me" ]]; then
        yq4 --inplace "${2} = ${3}" "${1}"
    fi
}

# Usage: generate_default_config <default_config>
generate_default_config() {
    if [[ $# -ne 1 ]]; then
        log_error "ERROR: number of args in generate_default_config must be 1. #=[$#]"
        exit 1
    fi

    default_config=$1
    if [ -f "${default_config}" ]; then
        backup_file "${default_config}" default
    else
        touch "${default_config}"
    fi

    config_name=$(echo "${default_config}" | sed -r 's/.*\///')

    new_config=$(mktemp)
    append_trap "rm ${new_config}; chmod 444 ${default_config}" EXIT

    # Change this to use one flavor for cloud provider and one for "size" (e.g. dev, growth, enterprise)
    envsubst < "${config_template_path}/config/${config_name}" | yq_merge -  "${config_template_path}/config/flavors/${CK8S_FLAVOR}/${config_name}" > "${new_config}"

    chmod 644 "${default_config}"
    cat "${new_config}" > "${default_config}"
}

# Usage: set_storage_class <config-file>
# baremetal support is experimental, keep as separate case until stable
set_storage_class() {
    file=$1
    if [[ ! -f "${file}" ]]; then
        log_error "ERROR: invalid file - $file"
        exit 1
    fi
    case ${CK8S_CLOUD_PROVIDER} in
        safespring | citycloud | elastx)
            storage_class=cinder-csi

            yq4 -i '.networkPolicies.kubeSystem.openstack.enabled = true' "${file}"
            yq4 -i '.networkPolicies.kubeSystem.openstack.ips = ["set-me"]' "${file}"
            yq4 -i '.networkPolicies.kubeSystem.openstack.ports = [5000,8774,8776]' "${file}" # Keystone, Nova, Cinder
            ;;

        upcloud)
            storage_class=upcloud-block-storage

            yq4 -i '.networkPolicies.kubeSystem.upcloud.enabled = true' "${file}"
            yq4 -i '.networkPolicies.kubeSystem.upcloud.ips = ["94.237.0.0/23"]' "${file}" # api.upcloud.com
            yq4 -i '.networkPolicies.kubeSystem.upcloud.ports = [443]' "${file}"
            ;;

        exoscale|baremetal)
            storage_class=rook-ceph-block

            yq4 -i '.networkPolicies.rookCeph.enabled = true' "${file}"
            ;;
        aws)
            storage_class=ebs-gp2
            ;;
    esac

    replace_set_me "${file}" ".storageClasses.default" "\"${storage_class}\""
}

# Usage: set_object_storage <config-file>
# baremetal support is experimental, keep as separate case until stable
set_object_storage() {
    file=$1
    if [[ ! -f "${file}" ]]; then
        log_error "ERROR: invalid file - $file"
        exit 1
    fi
    case ${CK8S_CLOUD_PROVIDER} in
        aws | exoscale)
            object_storage_type="s3"
            yq4 --inplace '.objectStorage.s3.region = "set-me"' "${file}"
            yq4 --inplace '.objectStorage.s3.regionEndpoint = "set-me"' "${file}"
            yq4 --inplace '.objectStorage.s3.forcePathStyle = false' "${file}"
            ;;

        citycloud | safespring | upcloud | elastx)
            object_storage_type="s3"
            yq4 --inplace '.objectStorage.s3.region = "set-me"' "${file}"
            yq4 --inplace '.objectStorage.s3.regionEndpoint = "set-me"' "${file}"
            yq4 --inplace '.objectStorage.s3.forcePathStyle = true' "${file}"
            ;;

        baremetal)
            object_storage_type="none"
            ;;
    esac

    replace_set_me "${file}" ".objectStorage.type" "\"${object_storage_type}\""
}

# Usage: set_nginx_config <config-file>
# baremetal support is experimental, keep as separate case until stable
set_nginx_config() {
    file=$1
    if [[ ! -f "${file}" ]]; then
        log_error "ERROR: invalid file - $file"
        exit 1
    fi
    case ${CK8S_CLOUD_PROVIDER} in
        exoscale | safespring | upcloud)
            use_proxy_protocol=false
            use_host_port=true
            service_enabled=false
            ;;

        citycloud | elastx)
            use_proxy_protocol=false
            use_host_port=false
            service_enabled=true
            service_type=LoadBalancer
            service_annotations=''
            ;;

        aws)
            use_proxy_protocol=false
            use_host_port=false
            service_enabled=true
            service_type=LoadBalancer
            service_annotations='service.beta.kubernetes.io/aws-load-balancer-type: nlb'
            ;;

        baremetal)
            use_proxy_protocol=false
            use_host_port=true
            service_enabled=false
            ;;
    esac

    replace_set_me "$1" '.ingressNginx.controller.config.useProxyProtocol' "${use_proxy_protocol}"
    replace_set_me "$1" '.ingressNginx.controller.useHostPort' "${use_host_port}"
    replace_set_me "$1" '.ingressNginx.controller.service.enabled' "${service_enabled}"

    if [ "${service_enabled}" = 'false' ]; then
        replace_set_me "${file}" '.ingressNginx.controller.service.type' '"set-me-if-ingressNginx.controller.service.enabled"'
        replace_set_me "${file}" '.ingressNginx.controller.service.annotations' '"set-me-if-ingressNginx.controller.service.enabled"'
    else
        replace_set_me "$1" '.ingressNginx.controller.service.type' "\"${service_type}\""
        replace_set_me "$1" '.ingressNginx.controller.service.annotations' "\"${service_annotations}\""
    fi
}

# Usage: set_fluentd_config <config-file>
# baremetal support is experimental, keep as separate case until stable
set_fluentd_config() {
    file=$1
    if [[ ! -f "${file}" ]]; then
        log_error "ERROR: invalid file - $file"
        exit 1
    fi
    case ${CK8S_CLOUD_PROVIDER} in
        safespring | citycloud | exoscale | upcloud | elastx)
            use_region_endpoint=true
            ;;

        aws)
            use_region_endpoint=false
            ;;

        baremetal)
            use_region_endpoint=true
            ;;
    esac

    replace_set_me "${file}" '.fluentd.forwarder.useRegionEndpoint' "${use_region_endpoint}"
}

# Usage: set_s3bucketalertscount_config <config-file>
set_s3bucketalertscount_config() {
    file=$1
    if [[ ! -f "${file}" ]]; then
        log_error "ERROR: invalid file - $file"
        exit 1
    fi
    case ${CK8S_CLOUD_PROVIDER} in
        citycloud)
            yq4 --inplace '.prometheus.s3BucketAlerts.objects.count = 1638400' "${file}"

            yq4 --inplace '.prometheus.s3BucketAlerts.objects.enabled = true' "${file}"
            ;;
        safespring)
            yq4 --inplace '.prometheus.s3BucketAlerts.objects.count = 1000000' "${file}"

            yq4 --inplace '.prometheus.s3BucketAlerts.objects.enabled = true' "${file}"
            ;;
    esac
}


# Usage: set_harbor_config <config-file>
# baremetal support is experimental, keep as separate case until stable
set_harbor_config() {
    file=$1
    if [[ ! -f "${file}" ]]; then
        log_error "ERROR: invalid file - ${file}"
        exit 1
    fi
    case ${CK8S_CLOUD_PROVIDER} in
        aws | exoscale)
            persistence_type=objectStorage
            disable_redirect=false
            ;;

        safespring | upcloud | elastx)
            persistence_type=objectStorage
            disable_redirect=true
            ;;

        citycloud)
            persistence_type=swift
            disable_redirect=true

            yq4 --inplace '.objectStorage.swift.authVersion = 0' "${file}"
            yq4 --inplace '.objectStorage.swift.authUrl = "set-me"' "${file}"
            yq4 --inplace '.objectStorage.swift.region = "set-me"' "${file}"
            yq4 --inplace '.objectStorage.swift.domainId = "set-me"' "${file}"
            yq4 --inplace '.objectStorage.swift.domainName = "set-me-or-domainId"' "${file}"
            yq4 --inplace '.objectStorage.swift.projectDomainId = "set-me"' "${file}"
            yq4 --inplace '.objectStorage.swift.projectDomainName = "set-me-or-projectDomainId"' "${file}"
            yq4 --inplace '.objectStorage.swift.projectId = "set-me"' "${file}"
            yq4 --inplace '.objectStorage.swift.projectName = "set-me"' "${file}"
            ;;

        baremetal)
            persistence_type=objectStorage
            disable_redirect=false
            ;;
    esac

    replace_set_me "${file}" ".harbor.persistence.type" "\"${persistence_type}\""
    replace_set_me "${file}" ".harbor.persistence.disableRedirect" "${disable_redirect}"
}

# Usage: update_config <override_config_file>
# Updates configs to only contain custom values.
update_config() {
    if [[ $# -ne 1 ]]; then
        log_error "ERROR: number of args in update_config must be 1. #=[$#]"
        exit 1
    fi

    override_config=$1
    config_name=$(echo "${override_config}" | sed -r 's/.*\///' | sed -r 's/-config.yaml//')

    if [ -f "${override_config}" ]; then
        backup_file "${override_config}"
        log_info "Updating ${config_name} config"
    else
        touch "${override_config}"
        log_info "Creating ${config_name} config"
    fi

    if [ "${config_name}" == "common" ]; then
        default_config="${config[default_common]}"
        base_config="${config[default_common]}"

        if [[ -f "${config[override_sc]}" ]] && [[ -f "${config[override_wc]}" ]]; then
            yq_copy_commons "${config[override_sc]}" "${config[override_wc]}" "${override_config}"
        fi
    else
        default_config=$(mktemp)
        append_trap "rm ${default_config}" EXIT
        yq_merge "${config[default_common]}" "${CK8S_CONFIG_PATH}/defaults/${config_name}-config.yaml" > "${default_config}"

        base_config=$(mktemp)
        append_trap "rm ${base_config}" EXIT
        yq_merge "${default_config}" "${config[override_common]}" > "${base_config}"
    fi

    new_config=$(mktemp)
    append_trap "rm ${new_config}" EXIT
    echo "{}" > "${new_config}"

    yq_copy_changes "${base_config}" "${override_config}" "${new_config}"

    if [ "${config_name}" == "common" ]; then
        diff_config="${new_config}"
    else
        diff_config=$(mktemp)
        append_trap "rm ${diff_config}" EXIT
        yq_merge "${config[override_common]}" "${new_config}" > "${diff_config}"
    fi

    yq_copy_values "${default_config}" "${diff_config}" "${new_config}" "set-me"

    if [ "${config_name}" == "common" ]; then
        preamble="# Changes made here will override the default values for both the service and workload cluster."
    else
        preamble="# Changes made here will override the default values as well as the common config for this cluster."
    fi
    preamble="${preamble}\n# See the default configuration under \"defaults/\" to see available and suggested options."
    echo -e "${preamble}" | cat - "${new_config}" > "${override_config}"
}

# Usage: update_secrets <config-file> <false|true>
update_secrets() {
    if [[ $# -ne 2 ]]; then
        log_error "ERROR: number of args in update_secrets must be 2. #=[$#]"
        exit 1
    fi
    file=$1
    generate_new_secrets=$2

    tmpfile=$(mktemp)
    append_trap "rm ${tmpfile}" EXIT

    yq4 eval-all 'select(fi == 0) * select(fi == 1)' "${config_template_path}/secrets/sc-secrets.yaml" "${config_template_path}/secrets/wc-secrets.yaml" > "${tmpfile}"

    generate_secrets "${tmpfile}"

    if [[ -f $file ]]; then
        sops_decrypt "${file}"
        yq4 --inplace '... comments=""' "${tmpfile}"
        yq4 eval-all --inplace --prettyPrint 'select(fi == 0) * select(fi == 1)' "${tmpfile}" "${file}"
    fi

    if [ "${generate_new_secrets}" = "true" ]; then
        generate_secrets "${tmpfile}"
    fi

    cat "${tmpfile}" > "${file}"
    sops_encrypt "${file}"
}

# Usage: generate_secrets <config-file>
generate_secrets() {
    if [[ $# -ne 1 ]]; then
        log_error "ERROR: number of args in generate_secrets must be 1. #=[$#]"
        exit 1
    fi
    tmpfile=$1

    # https://unix.stackexchange.com/questions/307994/compute-bcrypt-hash-from-command-line

    OS_ADMIN_PASS=$(pwgen -cns 20 1)
    OS_ADMIN_PASS_HASH=$(htpasswd -bnBC 10 "" "${OS_ADMIN_PASS}" | tr -d ':\n')

    OS_CONF_PASS=$(pwgen -cns 20 1)
    OS_CONF_PASS_HASH=$(htpasswd -bnBC 10 "" "${OS_CONF_PASS}" | tr -d ':\n')

    OSD_PASS=$(pwgen -cns 20 1)
    OSD_PASS_HASH=$(htpasswd -bnBC 10 "" "${OSD_PASS}" | tr -d ':\n')

    DEX_STATIC_PASS=$(pwgen -cns 20 1)
    # shellcheck disable=SC2016
    DEX_STATIC_PASS_HASH=$(htpasswd -bnBC 10 "" "${DEX_STATIC_PASS}" | tr -d ':\n' | sed 's/$2y/$2a/')

    THANOS_INGRESS_PASS=$(pwgen -cns 20 1)
    THANOS_INGRESS_PASS_HASH=$(htpasswd -bn "" "${THANOS_INGRESS_PASS}" | tr -d ':\n')

    HARBOR_REGISTRY_PASS=$(pwgen -cns 20 1)
    HARBOR_REGISTRY_PASS_HTPASSWD=$(htpasswd -bnB "harbor_registry_user" "${HARBOR_REGISTRY_PASS}" | tr -d '\n')

    yq4 --inplace ".grafana.password= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".grafana.clientSecret= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".grafana.opsClientSecret= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".harbor.password= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".harbor.registryPassword= \"${HARBOR_REGISTRY_PASS}\"" "${tmpfile}"
    yq4 --inplace ".harbor.registryPasswordHtpasswd= \"${HARBOR_REGISTRY_PASS_HTPASSWD}\"" "${tmpfile}"
    yq4 --inplace ".harbor.internal.databasePassword= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".harbor.clientSecret= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".harbor.xsrf= \"$(pwgen -cns 32 1)\"" "${tmpfile}"
    yq4 --inplace ".harbor.coreSecret= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".harbor.jobserviceSecret= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".harbor.registrySecret= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".opensearch.adminPassword= \"${OS_ADMIN_PASS}\"" "${tmpfile}"
    yq4 --inplace ".opensearch.adminHash= \"${OS_ADMIN_PASS_HASH}\"" "${tmpfile}"
    yq4 --inplace ".opensearch.clientSecret= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".opensearch.configurerPassword= \"${OS_CONF_PASS}\"" "${tmpfile}"
    yq4 --inplace ".opensearch.configurerHash= \"${OS_CONF_PASS_HASH}\"" "${tmpfile}"
    yq4 --inplace ".opensearch.dashboardsPassword= \"${OSD_PASS}\"" "${tmpfile}"
    yq4 --inplace ".opensearch.dashboardsHash= \"${OSD_PASS_HASH}\"" "${tmpfile}"
    yq4 --inplace ".opensearch.dashboardsCookieEncKey= \"$(pwgen -cns 32 1)\"" "${tmpfile}"
    yq4 --inplace ".opensearch.fluentdPassword= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".opensearch.curatorPassword= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".opensearch.snapshotterPassword= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".opensearch.metricsExporterPassword= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".kubeapiMetricsPassword= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".dex.staticPasswordNotHashed= \"${DEX_STATIC_PASS}\"" "${tmpfile}"
    yq4 --inplace ".dex.staticPassword= \"${DEX_STATIC_PASS_HASH}\"" "${tmpfile}"
    yq4 --inplace ".dex.kubeloginClientSecret= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".user.grafanaPassword= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".user.alertmanagerPassword= \"$(pwgen -cns 20 1)\"" "${tmpfile}"
    yq4 --inplace ".thanos.receiver.basic_auth.password= \"${THANOS_INGRESS_PASS}\"" "${tmpfile}"
    yq4 --inplace ".thanos.receiver.basic_auth.passwordHash= \"${THANOS_INGRESS_PASS_HASH}\"" "${tmpfile}"
}

# Usage: backup_file <file> [sufix]
backup_file() {
    if [ ! -f "$1" ]; then
        log_error "ERROR: args in backup_file must be a file. [$1]"
    fi

    if [ ! -d "${backup_config_path}" ]; then
        mkdir -p "${backup_config_path}"
    fi

    if [ ${#} -gt 1 ]; then
        backup_name=$(echo "$1" | sed "s/.*\///" | sed "s/-config.yaml/-$2-$(date +%y%m%d%H%M%S).yaml/")
    else
        backup_name=$(echo "$1" | sed "s/.*\///" | sed "s/.yaml/-$(date +%y%m%d%H%M%S).yaml/")
    fi

    log_info "Creating backup ${backup_config_path}/${backup_name}"

    cp "$1" "${backup_config_path}/${backup_name}"
}

log_info "Initializing CK8S configuration for $CK8S_ENVIRONMENT_NAME with $CK8S_CLOUD_PROVIDER:$CK8S_FLAVOR"

if [ -f "${sops_config}" ]; then
    log_info "SOPS config already exists: ${sops_config}"
    validate_sops_config
else
    generate_sops_config
fi

mkdir -p "${state_path}"
mkdir -p "${default_config_path}"

# TODO: Not a fan of this directory, we should probably have a separate script
#       for generating user configurations and not store it as a part of
#       the ck8s configuration.
mkdir -p "${CK8S_CONFIG_PATH}/user"
CK8S_VERSION=$(version_get)
export CK8S_VERSION

generate_default_config "${config[default_common]}"
set_storage_class       "${config[default_common]}"
set_object_storage      "${config[default_common]}"
set_nginx_config        "${config[default_common]}"
update_config           "${config[override_common]}"

generate_default_config        "${config[default_sc]}"
set_fluentd_config             "${config[default_sc]}"
set_harbor_config              "${config[default_sc]}"
set_s3bucketalertscount_config "${config[default_sc]}"
update_config                  "${config[override_sc]}"

generate_default_config "${config[default_wc]}"
update_config           "${config[override_wc]}"

gen_new_secrets=true
if [ -f "${secrets[secrets_file]}" ]; then
    backup_file "${secrets[secrets_file]}"
    if [ ${#} -gt 0 ] && [ "$1" = "--generate-new-secrets" ]; then
        log_info "Updating and generating new secrets"
    else
        log_info "Updating secrets"
        gen_new_secrets=false
    fi
else
    log_info "Generating new secrets"
fi

update_secrets "${secrets[secrets_file]}" "${gen_new_secrets}"

log_info "Config initialized"

log_info "Time to edit the following files:"
log_info "${config[override_common]}"
log_info "${config[override_sc]}"
log_info "${config[override_wc]}"
log_info "${secrets[secrets_file]}"
