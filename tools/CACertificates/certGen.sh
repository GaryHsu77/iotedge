## Copyright (c) Microsoft. All rights reserved.
## Licensed under the MIT license. See LICENSE file in the project root for full license information.

###############################################################################
# This script demonstrates creating X.509 certificates for an Azure IoT Hub
# CA Cert deployment.
#
# These certs MUST NOT be used in production.  It is expected that production
# certificates will be created using a company's proper secure signing process.
# These certs are intended only to help demonstrate and prototype CA certs.
###############################################################################
set -e

###############################################################################
# Define Variables
###############################################################################
ALGORITHM="genrsa"
RSA_CA_KEY_BITS_LENGTH="4096"
RSA_NON_CA_KEY_BITS_LENGTH="2048"
# Get directory of running script
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CERTIFICATE_DIR="${SCRIPT_DIR}"
OPENSSL_CONFIG_FILE="${CERTIFICATE_DIR}/openssl_root_ca.cnf"
# if you would like to override the default 30 day validity period, use
# env variable DEFAULT_VALIDITY_DAYS and set the duration in units of days
DEFAULT_VALIDITY_DAYS=${DEFAULT_VALIDITY_DAYS:=30}
ROOT_CA_PREFIX="azure-iot-test-only.root.ca"
ROOT_CA_PASSWORD=${ROOT_CA_PASSWORD:="1234"}
INTERMEDIATE_CA_PREFIX="azure-iot-test-only.intermediate"
INTERMEDIATE_CA_PASSWORD="1234"
FORCE_NO_PROD_WARNING=${FORCE_NO_PROD_WARNING:="false"}
export CERTIFICATE_OUTPUT_DIR=${CERTIFICATE_DIR}

###############################################################################
# Disclaimer print
###############################################################################
function warn_certs_not_for_production()
{
    if [ "$FORCE_NO_PROD_WARNING" != "true" ]; then
        tput smso
        tput setaf 3
        echo "Certs generated by this script are not for production (e.g. they have hard-coded passwords of '${ROOT_CA_PASSWORD}'."
        echo "This script is only to help you understand Azure IoT Hub CA Certificates."
        echo "Use your official, secure mechanisms for this cert generation."
        echo "Also note that these certs will expire in ${DEFAULT_VALIDITY_DAYS} days."
        tput sgr0
    fi
    exit 0
}

###############################################################################
#  Checks for all pre reqs before executing this script
###############################################################################
function check_prerequisites()
{
    local exists=$(command -v -- openssl)
    if [ -z "$exists" ]; then
        echo "openssl is required to run this script, please install this before proceeding"
        exit 1
    fi

    if [ ! -f ${OPENSSL_CONFIG_FILE} ]; then
        echo "Missing configuration file ${OPENSSL_CONFIG_FILE}"
        exit 1
    fi
}

###############################################################################
#  Creates required directories and removes left over cert files.
#  Run prior to creating Root CA; after that these files need to persist.
###############################################################################
function prepare_filesystem()
{
    rm -rf ${CERTIFICATE_DIR}/csr
    rm -rf ${CERTIFICATE_DIR}/private
    rm -rf ${CERTIFICATE_DIR}/certs
    rm -rf ${CERTIFICATE_DIR}/newcerts

    mkdir -p ${CERTIFICATE_DIR}/csr
    mkdir -p ${CERTIFICATE_DIR}/private
    mkdir -p ${CERTIFICATE_DIR}/certs
    mkdir -p ${CERTIFICATE_DIR}/newcerts

    rm -f ${CERTIFICATE_DIR}/index.txt
    touch ${CERTIFICATE_DIR}/index.txt

    rm -f ${CERTIFICATE_DIR}/serial
    echo 1000 > ${CERTIFICATE_DIR}/serial
}

###############################################################################
# Generate root CA Cert
###############################################################################
function generate_root_ca()
{
    local common_name="Azure_IoT_Hub_CA_Cert_Test_Only"
    local password_cmd=" -aes256 -passout pass:${ROOT_CA_PASSWORD} "

    local key_file=${CERTIFICATE_DIR}/private/${ROOT_CA_PREFIX}.key.pem
    local cert_file=${CERTIFICATE_DIR}/certs/${ROOT_CA_PREFIX}.cert.pem

    echo "Creating the root CA private key"
    openssl ${ALGORITHM} \
            ${password_cmd} \
            -out ${key_file} \
            ${RSA_CA_KEY_BITS_LENGTH}
    [ $? -eq 0 ] || exit $?
    chmod 400 ${key_file}
    [ $? -eq 0 ] || exit $?

    echo "CA root key generated at:"
    echo "---------------------------------"
    echo "    ${key_file}"
    echo ""

    echo "Creating the root CA certificate"
    password_cmd=" -passin pass:${ROOT_CA_PASSWORD} "
    openssl req \
            -new \
            -x509 \
            -config ${OPENSSL_CONFIG_FILE} \
            ${password_cmd} \
            -key ${key_file} \
            -subj "/CN=${common_name}" \
            -days ${DEFAULT_VALIDITY_DAYS} \
            -sha256 \
            -extensions "v3_ca" \
            -out ${cert_file}
    [ $? -eq 0 ] || exit $?
    chmod 444 ${cert_file}
    [ $? -eq 0 ] || exit $?

    echo "CA Root certificate generated at:"
    echo "---------------------------------"
    echo "    ${cert_file}"
    echo ""
    openssl x509 -noout -text -in ${cert_file}
    [ $? -eq 0 ] || exit $?
}

###############################################################################
# Generate a Certificate for a IoT or Edge device using a specific openssl
# extension and signed with either the root or intermediate cert.
###############################################################################
function generate_certificate_common()
{
    local extension="${1}"
    local expiration_days="${2}"
    local common_name="${3}"
    local prefix="${4}"
    local issuer_prefix="${5}"
    local key_pass="${6}"
    local issuer_key_pass="${7}"

    # setup all the necessary paths and variables
    local subject="/CN=${common_name}"
    local key_file="${CERTIFICATE_DIR}/private/${prefix}.key.pem"
    local cert_file="${CERTIFICATE_DIR}/certs/${prefix}.cert.pem"
    local cert_pfx_file="${CERTIFICATE_DIR}/certs/${prefix}.cert.pfx"
    local cert_full_chain_file="${CERTIFICATE_DIR}/certs/${prefix}-full-chain.cert.pem"
    local csr_file="${CERTIFICATE_DIR}/csr/${prefix}.csr.pem"
    local issuer_key_file="${CERTIFICATE_DIR}/private/${issuer_prefix}.key.pem"
    local issuer_cert_file="${CERTIFICATE_DIR}/certs/${issuer_prefix}.cert.pem"
    local issuer_cert_full_chain_file="${CERTIFICATE_DIR}/certs/${issuer_prefix}-full-chain.cert.pem"
    local root_ca_cert_file="${CERTIFICATE_DIR}/certs/${ROOT_CA_PREFIX}.cert.pem"
    local issuer_chain=""
    if [ "${issuer_prefix}" == "${ROOT_CA_PREFIX}" ]; then
        issuer_chain=${root_ca_cert_file}
    else
        issuer_chain=${issuer_cert_full_chain_file}
    fi

    # delete any older files that may exist from prior runs
    rm -f ${key_file}
    rm -f ${cert_file}
    rm -f ${cert_pfx_file}
    rm -f ${cert_full_chain_file}
    rm -f ${csr_file}

    if [ ${extension} == "v3_ca" ]; then
        key_bits_length=${RSA_CA_KEY_BITS_LENGTH}
    elif [ ${extension} == "v3_intermediate_ca" ]; then
        key_bits_length=${RSA_CA_KEY_BITS_LENGTH}
    else
        key_bits_length=${RSA_NON_CA_KEY_BITS_LENGTH}
    fi

    echo "Creating key for ${prefix}"
    echo "----------------------------------------"
    local password_cmd=""
    if [ ! -z ${key_pass} ]; then
        password_cmd=" -aes256 -passout pass:${key_pass} "
    fi
    openssl ${ALGORITHM} \
            ${password_cmd} \
            -out ${key_file} \
            ${key_bits_length}
    [ $? -eq 0 ] || exit $?
    chmod 444 ${key_file}
    [ $? -eq 0 ] || exit $?

    password_cmd=""
    if [ ! -z ${key_pass} ]; then
        password_cmd=" -passin pass:${key_pass} "
    fi
    echo "Create CSR for ${prefix}"
    echo "----------------------------------------"
    openssl req -new -sha256 ${password_cmd} \
        -config ${OPENSSL_CONFIG_FILE} \
        -key ${key_file} \
        -subj "${subject}" \
        -out ${csr_file}
    [ $? -eq 0 ] || exit $?

    local issuer_key_passwd_command=""
    if [ ! -z ${issuer_key_pass} ]; then
        issuer_key_passwd_command="-passin pass:${issuer_key_pass}"
    fi
    echo "Create certificate for ${prefix} using ${issuer_key_file}"
    echo "----------------------------------------"
    openssl ca -batch -config ${OPENSSL_CONFIG_FILE} \
            -extensions ${extension} \
            -days ${expiration_days} -notext -md sha256 \
            -cert ${issuer_cert_file} \
            -keyfile ${issuer_key_file} -keyform PEM \
            ${issuer_key_passwd_command} \
            -in ${csr_file} \
            -out ${cert_file} \
            -outdir ${CERTIFICATE_DIR}/newcerts
    [ $? -eq 0 ] || exit $?
    chmod 444 ${cert_file}
    [ $? -eq 0 ] || exit $?

    echo "Verify signature of the ${prefix}" \
         " certificate with the signer"
    echo "-----------------------------------"
    verify_untrusted=""
    if [ ${issuer_prefix} != ${ROOT_CA_PREFIX} ]; then
        verify_untrusted="-untrusted ${issuer_cert_full_chain_file}"
    fi
    openssl verify -CAfile ${root_ca_cert_file} ${verify_untrusted} ${cert_file}
    [ $? -eq 0 ] || exit $?

    echo "Certificate for ${prefix} generated at:"
    echo "----------------------------------------"
    echo "    ${cert_file}"
    echo ""
    openssl x509 -noout -text -in ${cert_file}
    [ $? -eq 0 ] || exit $?

    cat ${cert_file} \
        ${issuer_chain} > \
        ${cert_full_chain_file}
    [ $? -eq 0 ] || exit $?
    echo "Full chain certificate for ${prefix} generated at:"
    echo "----------------------------------------"
    echo "    ${cert_full_chain_file}"
    echo ""

    local key_passwd_command=" -passin pass:${key_pass} -passout pass:${key_pass} "
    # if [ ! -z ${key_pass} ]; then
    #     key_passwd_command="-passin pass:${key_pass} -passout pass:${key_pass}"
    # fi
    echo "Create the ${prefix} PFX certificate"
    echo "----------------------------------------"
    openssl pkcs12 -export \
            -in ${cert_file} \
            -certfile ${issuer_chain} \
            -inkey ${key_file} \
            ${key_passwd_command} \
            -name ${prefix} \
            -out ${cert_pfx_file}
    [ $? -eq 0 ] || exit $?

    echo "PFX certificate for ${prefix} generated at:"
    echo "--------------------------------------------"
    echo "    ${cert_pfx_file}"
}

###############################################################################
# Generate Intermediate CA Cert
###############################################################################
function generate_intermediate_ca()
{
    local root_ca_password="${1}"
    local common_name="Azure_IoT_Hub_Intermediate_Cert_Test_Only"

    generate_certificate_common "v3_intermediate_ca" \
                                ${DEFAULT_VALIDITY_DAYS} \
                                ${common_name} \
                                ${INTERMEDIATE_CA_PREFIX} \
                                ${ROOT_CA_PREFIX} \
                                ${INTERMEDIATE_CA_PASSWORD} \
                                ${root_ca_password}
}

###############################################################################
# Generates a root and intermediate certificate for CA certs.
###############################################################################
function initial_cert_generation()
{
    check_prerequisites
    prepare_filesystem
    generate_root_ca
    generate_intermediate_ca ${ROOT_CA_PASSWORD}
}

###############################################################################
# Installs a root CA and private key for all certificate generation
###############################################################################
function install_root_ca_from_files()
{
    local src_root_ca_path="${1}"
    local src_root_ca_key_path="${2}"
    local root_ca_password="${3}"
    local prefix=${ROOT_CA_PREFIX}
    local dest_cert_file="${CERTIFICATE_DIR}/certs/${prefix}.cert.pem"
    local dest_key_file="${CERTIFICATE_DIR}/private/${prefix}.key.pem"

    check_prerequisites
    prepare_filesystem
    cp ${src_root_ca_path} ${dest_cert_file}
    cp ${src_root_ca_key_path} ${dest_key_file}
    generate_intermediate_ca ${root_ca_password}
}

###############################################################################
# Installs a root CA and private key for all certificate generation
###############################################################################
function install_root_ca_from_cli()
{
    local ca_cert="${1}"
    local ca_pk="${2}"
    local root_ca_password="${3}"
    local uuid=$(uuidgen)
    local ip_cert_file="/tmp/$uuid_ca_cert.pem"
    local ip_key_file="/tmp/$uuid_ca_pk.pem"

    printf %s "$ca_cert" > $ip_cert_file
    printf %s "$ca_pk" > $ip_key_file
    install_root_ca_from_files $ip_cert_file $ip_key_file $root_ca_password
    rm -f $ip_cert_file
    [ $? -eq 0 ] || exit $?
    rm -f $ip_key_file
    [ $? -eq 0 ] || exit $?
}

###############################################################################
# Generates a certificate for verification, chained directly to the root.
###############################################################################
function generate_verification_certificate()
{
    if [[ $# -ne 1 ]] || [[ -z ${1} ]]; then
        echo "Usage error: Please provide a <subjectName>"
        exit 1
    fi
    local common_name="${1}"
    generate_certificate_common "usr_cert" \
                                ${DEFAULT_VALIDITY_DAYS} \
                                ${common_name} \
                                "iot-device-verification-code" \
                                ${ROOT_CA_PREFIX} \
                                "" \
                                ${ROOT_CA_PASSWORD}
}

###############################################################################
# Generates a certificate for a device, chained to the intermediate.
###############################################################################
function generate_device_identity_certificate()
{
    if [[ $# -ne 1 ]] || [[ -z ${1} ]]; then
        echo "Usage error: Please provide a <subjectName>"
        exit 1
    fi
    local common_name="${1}"
    generate_certificate_common "usr_cert" \
                                ${DEFAULT_VALIDITY_DAYS} \
                                ${common_name} \
                                "iot-device-${common_name}" \
                                ${INTERMEDIATE_CA_PREFIX} \
                                "" \
                                ${INTERMEDIATE_CA_PASSWORD}
}

###############################################################################
# Generates a certificate for an Edge device, chained to the intermediate.
###############################################################################
function generate_edge_device_identity_certificate()
{
    if [[ $# -ne 1 ]] || [[ -z ${1} ]]; then
        echo "Usage error: Please provide a <subjectName>"
        exit 1
    fi
    local common_name="${1}"
    generate_certificate_common "usr_cert" \
                                ${DEFAULT_VALIDITY_DAYS} \
                                ${common_name} \
                                "iot-edge-device-identity-${common_name}" \
                                ${INTERMEDIATE_CA_PREFIX} \
                                "" \
                                ${INTERMEDIATE_CA_PASSWORD}
}


###############################################################################
# Generates a certificate for a server, chained to the device CA.
###############################################################################
function generate_edge_server_certificate()
{
    if [[ $# -ne 1 ]] || [[ -z ${1} ]]; then
        echo "Usage error: Please provide a <subjectName>"
        exit 1
    fi
    local common_name="${1}"
    generate_certificate_common "server_cert" \
                                ${DEFAULT_VALIDITY_DAYS} \
                                ${common_name} \
                                "iot-edge-server-${common_name}" \
                                ${INTERMEDIATE_CA_PREFIX} \
                                "" \
                                ${INTERMEDIATE_CA_PASSWORD}
}

###############################################################################
# Generates a CA certificate for a Edge device, chained to the intermediate.
###############################################################################
function generate_edge_device_ca_certificate()
{
    if [[ $# -ne 1 ]] || [[ -z ${1} ]]; then
        echo "Usage error: Please provide a <subjectName>"
        exit 1
    fi
    # Note: Appending a '.ca' to the common name is useful in situations
    # where a user names their hostname as the edge device name.
    # By doing so we avoid TLS validation errors where we have a server or
    # client certificate where the hostname is used as the common name
    # which essentially results in "loop" for validation purposes.
    local common_name="${1}.ca"
    generate_certificate_common "v3_intermediate_ca" \
                                ${DEFAULT_VALIDITY_DAYS} \
                                ${common_name} \
                                "iot-edge-device-ca-${1}" \
                                ${INTERMEDIATE_CA_PREFIX} \
                                "" \
                                ${INTERMEDIATE_CA_PASSWORD}
}

###############################################################################
# Generates a CA certificate for a Edge device, chained to the intermediate.
###############################################################################
function generate_edge_device_certificate()
{
    if [[ $# -ne 1 ]] || [[ -z ${1} ]]; then
        echo "Usage error: Please provide a <subjectName>"
        exit 1
    fi
    # Note: Appending a '.ca' to the common name is useful in situations
    # where a user names their hostname as the edge device name.
    # By doing so we avoid TLS validation errors where we have a server or
    # client certificate where the hostname is used as the common name
    # which essentially results in "loop" for validation purposes.
    local common_name="${1}.ca"
    generate_certificate_common "v3_intermediate_ca" \
                                ${DEFAULT_VALIDITY_DAYS} \
                                ${common_name} \
                                "iot-edge-device-${1}" \
                                ${INTERMEDIATE_CA_PREFIX} \
                                "" \
                                ${INTERMEDIATE_CA_PASSWORD}
}

if [ "${1}" == "create_root_and_intermediate" ]; then
    initial_cert_generation
elif [ "${1}" == "install_root_ca_from_files" ]; then
    install_root_ca_from_files "${2}" "${3}" "${4}"
elif [ "${1}" == "install_root_ca_from_cli" ]; then
    install_root_ca_from_cli "${2}" "${3}" "${4}"
elif [ "${1}" == "create_verification_certificate" ]; then
    generate_verification_certificate "${2}"
elif [ "${1}" == "create_device_certificate" ]; then
    generate_device_identity_certificate "${2}"
elif [ "${1}" == "create_edge_device_certificate" ]; then
    generate_edge_device_certificate "${2}"
elif [ "${1}" == "create_edge_device_ca_certificate" ]; then
    generate_edge_device_ca_certificate "${2}"
elif [ "${1}" == "create_edge_device_identity_certificate" ]; then
    generate_edge_device_identity_certificate "${2}"
elif [ "${1}" == "create_edge_server_certificate" ]; then
    generate_edge_server_certificate "${2}"
else
    echo "Usage: create_root_and_intermediate                   # Creates a new root and intermediate certificates"
    echo "       install_root_ca_from_files <path to certificate> <path to private key> <private key password>  # Sets up a CA file and creates an intermediate signing certificate. Both key and certificate are expected to be in PEM format"
    echo "       install_root_ca_from_cli <certificate payload> <private key payload> <private key password>  # Sets up a CA file and creates an intermediate signing certificate. Both key and certificate are expected to be in PEM format"
    echo "       create_verification_certificate <subjectName>  # Creates a verification certificate, signed with <subjectName>"
    echo "       create_device_certificate <subjectName>        # Creates a device certificate, signed with <subjectName>"
    echo "       create_edge_device_certificate <subjectName>   # Creates an edge device CA certificate, signed with <subjectName>"
    echo "       create_edge_device_ca_certificate <subjectName>   # Creates an edge device CA certificate, signed with <subjectName>"
    echo "       create_edge_device_identity_certificate <subjectName>   # Creates an edge device identity certificate, signed with <subjectName>"
    echo "       create_edge_server_certificate <subjectName>   # Creates an edge device certificate, signed with <subjectName>"
    exit 1
fi

warn_certs_not_for_production
