#!/usr/bin/env bash
  
set -euo pipefail
IFS=$'\n\t'

readonly LOG_FILE="/tmp/$(basename "$0").log"
debug()   { echo "[$(date)][DEBUG]   $@" | tee -a "$LOG_FILE" >&2 ; }
info()    { echo "[$(date)][INFO]    $@" | tee -a "$LOG_FILE" >&2 ; }
warning() { echo "[$(date)][WARNING] $@" | tee -a "$LOG_FILE" >&2 ; }
error()   { echo "[$(date)][ERROR]   $@" | tee -a "$LOG_FILE" >&2 ; }
fatal()   { echo "[$(date)][FATAL]   $@" | tee -a "$LOG_FILE" >&2 ; exit 1 ; }

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ -f "$DIR/env" ]; then
    source "$DIR/env"
fi

ensure_dir(){
    local dir_name=$1
    if [ ! -d "$dir_name" ]; then
        debug "$dir_name is not present. Creating"
        mkdir -p ${dir_name}
    else
        debug "$dir_name is already present. Skipping"
    fi
}

test_presence(){
    local file=$1
    if [[ -f $file ]] ; then
        return 0  # Non zero means true
    else
        return 1
    fi
}

setup_env() {

    ensure_dir $BIN_DIR
    ensure_dir $PKI_DIR
    ensure_dir $PKI_PROFILE_DIR
}

install_cfssl() {
  command -v cfssljson >/dev/null 2>&1 && { echo "[$(date)][INFO] cfssl found."; return 0; }
  echo "[$(date)][WARNING] cfssl and cfssljson not found in path."
  if echo "$OSTYPE" | grep -q "linux"; then
    debug "Downloading cfssl version R$CFSSL_RELEASE" 
    curl -kSL "https://pkg.cfssl.org/R$CFSSL_RELEASE/cfssl_linux-amd64" -o "$BIN_DIR/cfssl"
    debug "Downloading cfssljson version R$CFSSL_RELEASE"
    curl -kSL "https://pkg.cfssl.org/R$CFSSL_RELEASE/cfssljson_linux-amd64" -o "$BIN_DIR/cfssljson"
    chmod +x "$BIN_DIR/"{cfssl,cfssljson}
  else
    echo "[$(date)][ERROR] Unsupported OS for dependency resolution. Please install cfssl manually."
    return 1
  fi
}

gen_ca_csr_json(){
    
    cat << EOF > $PKI_PROFILE_DIR/ca-csr.json
{
    "CN": "${CA_NAME}CA",
    "key": {
        "algo": "rsa",
        "size": 2048
    }
}
EOF

}

gen_ca_config(){

    cat << EOF > $PKI_PROFILE_DIR/ca-config.json
{
  "signing": {
    "default": {
      "expiry": "43800h"
    },
    "profiles": {
      "server": {
        "expiry": "43800h",
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ]
      },
      "client": {
         "expiry": "43800h",
         "usages": [
            "signing",
            "digital signature",
            "key encipherment", 
            "client auth"
          ]
      }
    }
  }
}
EOF

}

gen_server_profile(){

    local SERVER=$1

    cat << EOF > $PKI_PROFILE_DIR/$SERVER-csr.json
{
    "CN": "$SERVER",
    "hosts": ["$SERVER.$DOMAIN"],
    "key": {
        "algo": "ecdsa",
        "size": 256
    }
}
EOF
}

gen_client_profile(){

    local client=$1
cat << EOF > $PKI_PROFILE_DIR/$client-csr.json
{
    "CN": "$client",
    "key": {
        "algo": "rsa",
        "size": 4096
    },
    "names": [{
        "O": "$client",
        "email": "$client@$EMAIL_DOMIAN"
    }],
    "hosts": [""]
}
EOF
}


gen_server_cert() {
    local server_name=$1
    if test_presence "$PKI_DIR/$server_name.pem" ; then
        debug "Certs for server $server_name already present. Skipping"
        return 0
    fi

    gen_server_profile $server_name
    cfssl gencert \
        -ca="$PKI_DIR/$CA_NAME-ca.pem" \
        -ca-key="$PKI_DIR/$CA_NAME-ca-key.pem" \
        -config="$PKI_PROFILE_DIR/ca-config.json" \
        -profile=server \
        "$PKI_PROFILE_DIR/$server_name"-csr.json | cfssljson -bare "$PKI_DIR/$server_name"
}

gen_client_cert(){
    local client=$1

    if test_presence "$PKI_DIR/$client.pem" ; then
        debug "Certs for client $client already present. Skipping"
        return 0
    fi

    gen_client_profile $client
    cfssl gencert \
        -ca="$PKI_DIR/$CA_NAME-ca.pem" \
        -ca-key="$PKI_DIR/$CA_NAME-ca-key.pem" \
        -config="$PKI_PROFILE_DIR/ca-config.json" \
        -profile=client \
        "$PKI_PROFILE_DIR/$client"-csr.json | cfssljson -bare "$PKI_DIR/$client"

    # Generate p12
    info "Generating PKCS#12 files for $client"
    openssl pkcs12 -export -in "$PKI_DIR/$client".pem \
                           -inkey "$PKI_DIR/$client"-key.pem \
                           -out "$PKI_DIR/$client".p12 \
                           -passout pass: \
                           -name "Client Cert"
    
}

init_pki() {
  info "Generating Certificates."

  # Generate CA-CSR & Config
  gen_ca_csr_json
  gen_ca_config

  # Init CA
  if test_presence "$PKI_DIR/${CA_NAME}-ca.pem" && test_presence "$PKI_DIR/${CA_NAME}-ca-key.pem"  ; then
    info "CA ${CA_NAME} already present. Skipping"
  else
    debug "Generating CA: $CA_NAME"
    cfssl gencert -initca "$PKI_PROFILE_DIR/ca-csr.json" | cfssljson -bare "$PKI_DIR/${CA_NAME}-ca" -
  fi
 
 
  # Init servers
  for SERVER in "${SERVERS[@]}"; do
        echo "[$(date)][INFO]  Generating certs for server: $SERVER"
        gen_server_cert $SERVER
  done

  # Init clients
  for CLIENT in "${USERS[@]}"; do
        echo "[$(date)][INFO]  Generating certs for user: $CLIENT"
        gen_client_cert $CLIENT
  done
}


## Main ##

setup_env
install_cfssl
init_pki 


