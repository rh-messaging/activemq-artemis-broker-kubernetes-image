#!/bin/sh

export BROKER_HOST=`hostname -f`

echo "[drain.sh] drainer container ip(from hostname) is $BROKER_HOST"

instanceDir="${HOME}/${AMQ_NAME}"

ENDPOINT_NAME="${AMQ_NAME}-amq-headless"

if [ "$HEADLESS_SVC_NAME" ]; then
  ENDPOINT_NAME=$HEADLESS_SVC_NAME
fi

endpointsUrl="https://${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}:${KUBERNETES_SERVICE_PORT:-443}/api/v1/namespaces/${POD_NAMESPACE}/"
endpointsAuth="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"

function waitForJolokia() {
  while : ;
  do
    sleep 5
    curl -s -o /dev/null -G -k http://${AMQ_USER}:${AMQ_PASSWORD}@${BROKER_HOST}:8161/console/jolokia
    if [ $? -eq 0 ]; then
      break
    fi
  done
}


endpointsCode=$(curl -s -o /dev/null -w "%{http_code}" -G -k -H "${endpointsAuth}" ${endpointsUrl})
if [ $endpointsCode -ne 200 ]; then
  echo "[drain.sh] Can't find endpoints with ips status <${endpointsCode}>"
  exit 1
fi

ENDPOINTS=$(curl -s -X GET -G -k -H "${endpointsAuth}" ${endpointsUrl}"endpoints/${ENDPOINT_NAME}")
echo "[drain.sh] $ENDPOINTS"
# we will find out a broker pod's fqdn name which is <pod-name>.<$HEADLESS_SVC_NAME>.<namespace>.svc.<domain-name>
# https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
count=0
foundTarget="false"
while [ 1 ]; do
  ip=$(echo $ENDPOINTS | python2 -c "import sys, json; print json.load(sys.stdin)['subsets'][0]['addresses'][${count}]['ip']")
  if [ $? -ne 0 ]; then
    echo "[drain.sh] Can't find ip to scale down to tried ${count} ips"
    exit 1
  fi
  echo "[drain.sh] got ip ${ip} broker ip is ${BROKER_HOST}"
  podName=$(echo $ENDPOINTS | python2 -c "import sys, json; print json.load(sys.stdin)['subsets'][0]['addresses'][${count}]['targetRef']['name']")
  if [ $? -ne 0 ]; then
    echo "[drain.sh] Can't find pod name to scale down to tried ${count}"
    exit 1
  fi
  echo "[drain.sh] got podName ${podName} broker ip is ${BROKER_HOST}"
  if [ "$podName" != "$BROKER_HOST" ]; then
    # found an endpoint pod as a candidate for scaledown target
    podNamespace=$(echo $ENDPOINTS | python2 -c "import sys, json; print json.load(sys.stdin)['subsets'][0]['addresses'][${count}]['targetRef']['namespace']")
    if [ $? -ne 0 ]; then
      echo "[drain.sh] Can't find pod namespace to scale down to tried ${count}"
      exit 1
    fi
    foundTarget="true"
    break
  fi

  count=$(( count + 1 ))
done

if [ "$foundTarget" == "false" ]; then
  echo "[drain.sh] Can't find a target to scale down to"
  exit 1
fi

# get host name of target pod
IFSP=$IFS
IFS=
dnsNames=$(nslookup ${ip})
echo "[drain.sh] $dnsNames"

hostNamePrefix="${podName}.${HEADLESS_SVC_NAME}.${podNamespace}.svc."
echo "[drain.sh] searching hostname with prefix: $hostNamePrefix"

while read -r line
do
  IFS=' ' read -ra ARRAY <<< "$line"
  if [ ${#ARRAY[@]} -gt 0 ]; then
    hostName=${ARRAY[-1]}
    if [[ $hostName == ${hostNamePrefix}* ]]; then
      # remove the last dot
      case $hostName in *.) hostName=${hostName%"."};; esac
      echo "[drain.sh] found hostname: $hostName"
      break
    fi
  fi
done <<< ${dnsNames}
IFS=$IFSP

if [ -z "$hostName" ]; then
  echo "[drain.sh] Can't find target host name"
  exit 1
fi

source /opt/amq/bin/launch.sh nostart

SCALE_TO_BROKER="${hostName}"
echo "[drain.sh] scale down target is: $SCALE_TO_BROKER"

# Add connector to the pod to scale down to
connector="<connector name=\"scaledownconnector\">tcp:\/\/${SCALE_TO_BROKER}:61616<\/connector>"
sed -i "/<\/connectors>/ s/.*/${connector}\n&/" ${instanceDir}/etc/broker.xml

# Remove the acceptors
#sed -i -ne "/<acceptors>/ {p;   " -e ":a; n; /<\/acceptors>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml
acceptor="<acceptor name=\"artemis\">tcp:\/\/${BROKER_HOST}:61616?protocols=CORE<\/acceptor>"
sed -i -ne "/<acceptors>/ {p; i $acceptor" -e ":a; n; /<\/acceptors>/ {p; b}; ba}; p" ${instanceDir}/etc/broker.xml

#start the broker and issue the scaledown command to drain the messages.
${instanceDir}/bin/artemis-service start

tail -n 100 -f ${AMQ_NAME}/log/artemis.log &

waitForJolokia

RET_CODE=`curl -G -k http://${AMQ_USER}:${AMQ_PASSWORD}@${BROKER_HOST}:8161/console/jolokia/exec/org.apache.activemq.artemis:broker=%22${AMQ_NAME}%22/scaleDown/scaledownconnector`

HTTP_CODE=`echo $RET_CODE | python2 -c "import sys, json; print json.load(sys.stdin)['status']"`

echo "[drain.sh] curl return code ${HTTP_CODE}"

if [ "${HTTP_CODE}" != "200" ]; then
  echo "[drain.sh] scaleDown is not successful, response: $RET_CODE"
  echo "[drain.sh] sleeping for 30 seconds to allow inspection before it restarts"
  sleep 30
  exit 1
fi

echo "[drain.sh] scaledown is successful"
exit 0
