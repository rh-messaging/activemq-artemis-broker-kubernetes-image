#!/usr/bin/env bash

function log() {
  logtime=$(date)
  echo "[$logtime]-[drain.sh] $1"
}

CURL_ERR="curl-error"

function jolokia_read() {
  CURL_FAILURE=""
  CURL_RESULT=$(curl -s -G -k -H "Origin: http://localhost" http://${AMQ_USER}:${AMQ_PASSWORD}@${BROKER_HOST}:8161/console/jolokia/read/org.apache.activemq.artemis:broker=%22${AMQ_NAME}%22${1})
  curl_status=$(echo $CURL_RESULT | jq -r '.status')
  if [[ ${curl_status} != "200" ]]; then
    CURL_FAILURE=${CURL_ERR}
    HAVE_JOLOKIA_PROBLEM="true"
  fi
  echo $CURL_RESULT
}

function get_address_message_count() {
  target_address=$1
  TOTAL_MESSAGES_ON_ADDRESS=0

  log "getting message count on address ${target_address}"

  # checking out address routing type
  R_RoutingTypes=$(jolokia_read ",address=%22${target_address}%22,component=addresses/RoutingTypes")
  if [[ "${CURL_FAILURE}" == "${CURL_ERR}" ]]; then
    log "failed to get message count on ${target_address}"
    log "response: ${R_RoutingTypes}"
    return
  fi

  routingType=$(echo ${R_RoutingTypes} | jq -r '.value[0]')
  routingType=$(echo "${routingType}" | tr '[:upper:]' '[:lower:]')

  log "address ${target_address} routing type is ${routingType}"

  R_AllQueueNames=$(jolokia_read ",address=%22${target_address}%22,component=addresses/AllQueueNames")
  if [[ "${CURL_FAILURE}" == "${CURL_ERR}" ]]; then
    log "failed to get message count on ${target_address}"
    log "response: ${R_AllQueueNames}"
    return
  fi
  AllQueueNames=($(echo $R_AllQueueNames | jq -r '.value[]'))

  for queue in "${AllQueueNames[@]}"
  do
    log "checking queue ${queue} on address ${target_address}"
    # queue temporary
    R_QueueTemp=$(jolokia_read ",address=%22${target_address}%22,component=addresses,queue=%22${queue}%22,routing-type=%22${routingType}%22,subcomponent=queues/Temporary")
    if [[ "${CURL_FAILURE}" == "${CURL_ERR}" ]]; then
      log "cannot get Temporary attribute of queue ${queue}"
      log "response: ${R_QueueTemp}"
      return
    fi

    Is_Temp=$(echo ${R_QueueTemp} | jq -r '.value')

    if [[ ${Is_Temp} == "false" ]]; then
      log "getting queue ${queue} message count"

      R_QueueCount=$(jolokia_read ",address=%22${target_address}%22,component=addresses,queue=%22${queue}%22,routing-type=%22${routingType}%22,subcomponent=queues/MessageCount")
      if [[ ${CURL_FAILURE} == "${CURL_ERR}" ]]; then
        log "failed to get message count on queue ${queue}"
        log "response: ${R_QueueCount}"
        return
      fi
      queueMessageCount=$(echo ${R_QueueCount} | jq -r '.value')
      log "message count on ${queue}: ${queueMessageCount}"

      TOTAL_MESSAGES_ON_ADDRESS=$((${TOTAL_MESSAGES_ON_ADDRESS} + ${queueMessageCount}))
    else
      log "${queue} is a temp queue, skip"
    fi
  done
}

function get_total_messages_on_broker() {
  log "get total messages on broker ${BROKER_HOST}"
  TOTAL_MESSAGES_ON_BROKER=0

  RET_VALUE=$(jolokia_read "/AddressNames")
  if [[ ${CURL_FAILURE} == ${CURL_ERR} ]]; then
    log "failed to get address names from broker ${AMQ_NAME}"
    log "response: ${RET_VALUE}"
    return
  fi

  all_addresses=($(echo "${RET_VALUE}" | jq -r '.value[]'))

  for address in "${all_addresses[@]}"
  do
    log "checking on address ${address}"
    get_address_message_count "${address}"

    TOTAL_MESSAGES_ON_BROKER=$(($TOTAL_MESSAGES_ON_BROKER + $TOTAL_MESSAGES_ON_ADDRESS))
  done
  log "broker has ${TOTAL_MESSAGES_ON_BROKER} messages in total"
}

function waitForJolokia() {
  while : ;
  do
    sleep 5
    curl -s -o /dev/null -G -k "http://${AMQ_USER}:${AMQ_PASSWORD}@${BROKER_HOST}:8161/console/jolokia"
    if [ $? -eq 0 ]; then
      log "jolokia is ready"
      break
    fi
  done
}

export BROKER_HOST="$(hostname -f)"

log "drainer container host is $BROKER_HOST"

instanceDir="${HOME}/${AMQ_NAME}"

ENDPOINT_NAME="${AMQ_NAME}-amq-headless"

if [ "$HEADLESS_SVC_NAME" ]; then
  ENDPOINT_NAME=$HEADLESS_SVC_NAME
fi

endpointsUrl="https://${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}:${KUBERNETES_SERVICE_PORT:-443}/api/v1/namespaces/${POD_NAMESPACE}/"
endpointsAuth="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"

endpointsCode=$(curl -s -o /dev/null -w "%{http_code}" -G -k -H "${endpointsAuth}" "${endpointsUrl}")
if [ "$endpointsCode" -ne 200 ]; then
  log "can't find endpoints with ips status <${endpointsCode}>"
  exit 1
fi

ENDPOINTS=$(curl -s -X GET -G -k -H "${endpointsAuth}" "${endpointsUrl}endpoints/${ENDPOINT_NAME}")

log "endpoints: $ENDPOINTS"

# we will find out a broker pod's fqdn name which is <pod-name>.<$HEADLESS_SVC_NAME>.<namespace>.svc.<domain-name>
# https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
n_endpoints=$(echo $ENDPOINTS | python3 -c "import sys, json; print(len(json.load(sys.stdin)['subsets'][0]['addresses']))")
log "size of endpoints $n_endpoints"

# shellcheck source=/dev/null
source "/opt/amq/bin/launch.sh" nostart

count=-1
log "starting message migration loop"

# message migration loop
# it goes through the endpoints(pod) until the scale down is successful or all tried
while true; do

  HAVE_JOLOKIA_PROBLEM="false"

  count=$(( count + 1 ))

  if [ $count -eq $n_endpoints ]; then
    log "tried all $n_endpoints endpoints, scaledown failed. Sleeping 300 seconds before exit."
    sleep 300
    exit 1
  fi

  log "attempting on endpoint: $count"

  ip=$(echo $ENDPOINTS | python3 -c "import sys, json; print(json.load(sys.stdin)['subsets'][0]['addresses'][${count}]['ip'])")

  if [ $? -ne 0 ]; then
    log "can't find ip to scale down to tried ${count} ips"
    continue
  fi

  log "got endpoint ip ${ip}"

  podName=$(echo $ENDPOINTS | python3 -c "import sys, json; print(json.load(sys.stdin)['subsets'][0]['addresses'][${count}]['targetRef']['name'])")
  if [ $? -ne 0 ]; then
    log "can't find pod name to scale down to tried ${count}"
    continue
  fi

  log "got endpoint pod name ${podName}"
  if [ "$podName" != "$BROKER_HOST" ]; then
    podNamespace=$(echo $ENDPOINTS | python3 -c "import sys, json; print(json.load(sys.stdin)['subsets'][0]['addresses'][${count}]['targetRef']['namespace'])")
    if [ $? -ne 0 ]; then
      log "can't find pod namespace to scale down to tried ${count}"
      continue
    fi

    log "found an candidate target: $podName"

    IFSP=$IFS
    IFS=
    dnsNames=$(nslookup "${ip}")

    log "looked up dns entries $dnsNames"

    hostNamePrefix="${podName}.${HEADLESS_SVC_NAME}.${podNamespace}.svc."

    log "searching hostname with prefix: $hostNamePrefix"

    while read -r line
    do
      IFS=' ' read -ra ARRAY <<< "$line"
      if [ ${#ARRAY[@]} -gt 0 ]; then
        hostName=${ARRAY[-1]}
        if [[ $hostName == ${hostNamePrefix}* ]]; then
          # remove the last dot
          case $hostName in *.) hostName=${hostName%"."};; esac
          log "found target hostname: $hostName"
          break
        fi
      fi
    done <<< "${dnsNames}"
    IFS=$IFSP

    if [ -z "$hostName" ]; then
      log "can't find target host name"
      continue
    fi

    SCALE_TO_BROKER="${hostName}"
    log "scale down target is: $SCALE_TO_BROKER"

    # Add connector to the pod to scale down to
    log "removing any existing scaledownconnector"
    sed -i '/<connector name="scaledownconnector">.*/d' "${instanceDir}/etc/broker.xml"

    log "adding new connector"
    connector="<connector name=\"scaledownconnector\">tcp:\/\/${SCALE_TO_BROKER}:61616<\/connector>"
    sed -i "/<\/connectors>/ s/.*/${connector}\n&/" "${instanceDir}/etc/broker.xml"

    # Remove the acceptors
    acceptor="<acceptor name=\"artemis\">tcp:\/\/${BROKER_HOST}:61616?protocols=CORE<\/acceptor>"
    sed -i -ne "/<acceptors>/ {p; i $acceptor" -e ":a; n; /<\/acceptors>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml

    # start the broker and issue the scaledown command to drain the messages.
    log "launch the drainer broker"

    "${instanceDir}/bin/artemis-service" start

    waitForJolokia

    # calculate total messages
    get_total_messages_on_broker
    total_before_scaledown=$TOTAL_MESSAGES_ON_BROKER

    log "initiating scaledown. There are $total_before_scaledown messages to be migrated"
    mm_start=$(date +%s)

    RET_CODE=$(curl -s -G -k http://${AMQ_USER}:${AMQ_PASSWORD}@${BROKER_HOST}:8161/console/jolokia/exec/org.apache.activemq.artemis:broker=%22${AMQ_NAME}%22/scaleDown/scaledownconnector)

    mm_end=$(date +%s)
    mm_time=$(($mm_end - $mm_start))
    log "scaledown finished. Time used: $mm_time"

    HTTP_CODE=$(echo $RET_CODE | python3 -c "import sys, json; print(json.load(sys.stdin)['status'])")

    log "scaleDown return code ${HTTP_CODE}"

    if [ "${HTTP_CODE}" != "200" ]; then
      log "scaleDown is not successful, response: $RET_CODE"
      continue
    fi

    log "restart broker to check messages"
    "${instanceDir}/bin/artemis-service" stop
    if [ $? -ne 0 ]; then
      log "force stopping the broker"
      "${instanceDir}/bin/artemis-service" force-stop
    fi

    "${instanceDir}/bin/artemis-service" start

    waitForJolokia

    log "checking messages are all drained"

    scaleDownSuccessful="true"
    get_total_messages_on_broker
    total_after_scaledown=$TOTAL_MESSAGES_ON_BROKER

    log "messages left after scaledown: $total_after_scaledown"

    if [ $total_after_scaledown -ne 0 ]; then
      scaleDownSuccessful="false"
    fi
    message_migrated=$(($total_before_scaledown - $total_after_scaledown))

    log "stopping the broker"
    "${instanceDir}/bin/artemis-service" stop
    if [ $? -ne 0 ]; then
      "${instanceDir}/bin/artemis-service" force-stop
    fi

    if [ $HAVE_JOLOKIA_PROBLEM == "true" ]; then
      # scale down is happened but there are some jolokia invocation error
      # which may cause problem in getting the real result.
      log "there appears to be some jolokia problem, should keep retry"
    elif [ $scaleDownSuccessful == "true" ]; then
      log "scaledown is successful, total messages migrated: $message_migrated"
      exit 0
    fi
    log "scaledown not successful, messages left: $total_after_scaledown"
  fi
done

#this shouldn't happen, return 1 to let operator retry
exit 1
