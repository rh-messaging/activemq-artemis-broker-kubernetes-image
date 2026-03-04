#!/bin/sh
set -e

SCRIPT_DIR=$(dirname $0)

cp ${SCRIPT_DIR}/openssl.cnf /usr/local/etc/openssl.cnf
