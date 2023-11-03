#!/usr/bin/env bash

if [ true = "${DEBUG}" ] ; then
  # short circuit readiness check in dev mode
  exit 0
fi

OUTPUT=/tmp/readiness-output
ERROR=/tmp/readiness-error
LOG=/tmp/readiness-log

INSTANCE_DIR="${HOME}/${AMQ_NAME}"
CONFIG_FILE=$INSTANCE_DIR/etc/broker.xml

COUNT=30
SLEEP=1
DEBUG_SCRIPT=true

EVALUATE_SCRIPT=$(cat <<EOF
import xml.etree.ElementTree
from urllib.parse import urlsplit
import socket
import sys

# calculate the open ports
tcp_lines = []
for tcp_file_path in ["/proc/net/tcp", "/proc/net/tcp6"]:
  try:
    tcp_file = open(tcp_file_path, "r")
    lines = tcp_file.readlines()
    if len(lines) > 0:
      header = lines.pop(0)
      tcp_lines.extend(lines)
    tcp_file.close()
  except IOError:
    print("Could not open {}".format(tcp_file_path))

listening_ports = []
for tcp_line in tcp_lines:
  stripped = tcp_line.strip()
  contents = stripped.split()
  # Is the status listening?
  if contents[3] == '0A':
    netaddr = contents[1].split(":")
    port = int(netaddr[1], 16)
    listening_ports.append(port)

#parse the config file to retrieve the transport connectors
xmldoc = xml.etree.ElementTree.parse("${CONFIG_FILE}")

ns = {"config" : "urn:activemq:core"}
acceptors = xmldoc.findall("config:core/config:acceptors/config:acceptor", ns)

result=0

for acceptor in acceptors:
  name = acceptor.get("name")
  value = acceptor.text.strip()
  print("{} value {}".format(name, value))
  spliturl = urlsplit(value)
  port = spliturl.port

  print("{} port {}".format(name, port))

  if port == None:
    print("    {} does not define a port, cannot check acceptor".format(name))
    result=1

  try:
    listening_ports.index(port)
    print("    Transport is listening on port {}".format(port))
  except ValueError as e:
    print("    Nothing listening on port {}, transport not yet running".format(port))
    result=1
sys.exit(result)
EOF
)

if [ $# -gt 0 ] ; then
    COUNT=$1
fi

if [ $# -gt 1 ] ; then
    SLEEP=$2
fi

if [ $# -gt 2 ] ; then
    DEBUG_SCRIPT=$3
fi

if [ true = "${DEBUG_SCRIPT}" ] ; then
    echo "Count: ${COUNT}, sleep: ${SLEEP}" > "${LOG}"
fi

while : ; do
    CONNECT_RESULT=1
    PROBE_MESSAGE="No configuration file located: ${CONFIG_FILE}"

    if [ -f "${CONFIG_FILE}" ] ; then
        python3 -c "$EVALUATE_SCRIPT" >"${OUTPUT}" 2>"${ERROR}"

        CONNECT_RESULT=$?
        if [ true = "${DEBUG_SCRIPT}" ] ; then
            (
                echo "$(date) Connect: ${CONNECT_RESULT}"
                echo "========================= OUTPUT =========================="
                cat "${OUTPUT}"
                echo "========================= ERROR =========================="
                cat "${ERROR}"
                echo "=========================================================="
            ) >> "${LOG}"
        fi

        PROBE_MESSAGE="No transport listening on ports $(grep "Nothing listening" "${OUTPUT}" | sed -e 's+^.*on port ++' -e 's+,.*$++')"
        rm -f  "${OUTPUT}" "${ERROR}"
    fi

    if [ "${CONNECT_RESULT}" -eq 0 ] ; then
        exit 0;
    fi

    COUNT=$((COUNT - 1))
    if [ "$COUNT" -eq 0 ] ; then
        echo "${PROBE_MESSAGE}"
        exit 1;
    fi
    sleep "${SLEEP}"
done
