#!/usr/bin/env bash
cat << 'HERE' >>/usr/local/bin/ibm-host-attach.sh
#!/usr/bin/env bash
set -ex
mkdir -p /etc/satelliteflags
HOST_ASSIGN_FLAG="/etc/satelliteflags/hostattachflag"
if [[ -f "$HOST_ASSIGN_FLAG" ]]; then
	echo "host has already been assigned. need to reload before you try the attach again"
	exit 0
fi
set +x
HOST_QUEUE_TOKEN="3f6dac41805431032763b0c04095bfdd498d8750fa5c05486050dc742936b71c1c7d6d620e8d970691678ddd5a236f59d5521ac11b27362836cdc9ec994aa4a68f6da7338f73726db6868dbea9a421a71e5340adcb66354caef08e6690d20607fde335bac15edb937ff98b9b174a9833771fab79c431758ac8bfa6d40b0631f739c061ee9b6f432195b1dc6f2c55723032cfb5b8b0f404d20e1605257f53c9ddde261b61a4f2772b7471d671fe4ed11b4952938c3cdbb6e43e4f095d861530b1d8ec2d70cad9e7f8637e5d539e72a819f99b7a1d6190f5aa35a8ac2634d1f2dd720ca10bc505593f5481998433d0d1a87237e5f74c6bda9aaa8157a4075410da"
set -x
ACCOUNT_ID="7866fa2b572544b5b20a4b2bad85ff7d"
CONTROLLER_ID="c50del9w0qb97g1j7d30"
SELECTOR_LABELS='{}'
API_URL="https://origin.us-east.containers.cloud.ibm.com/"
REGION="us-east"

export HOST_QUEUE_TOKEN
export ACCOUNT_ID
export CONTROLLER_ID
export REGION

#shutdown known blacklisted services for Satellite (these will break kube)
set +e
systemctl stop -f iptables.service
systemctl disable iptables.service
systemctl mask iptables.service
systemctl stop -f firewalld.service
systemctl disable firewalld.service
systemctl mask firewalld.service
set -e

# ensure you can successfully communicate with redhat mirrors (this is a prereq to the rest of the automation working)
yum install rh-python36 -y
mkdir -p /etc/satellitemachineidgeneration
if [[ ! -f /etc/satellitemachineidgeneration/machineidgenerated ]]; then
	rm -f /etc/machine-id
	systemd-machine-id-setup
	touch /etc/satellitemachineidgeneration/machineidgenerated
fi
#STEP 1: GATHER INFORMATION THAT WILL BE USED TO REGISTER THE HOST
HOSTNAME=$(hostname -s)
HOSTNAME=${HOSTNAME,,}
MACHINE_ID=$(cat /etc/machine-id)
CPUS=$(nproc)
MEMORY=$(grep MemTotal /proc/meminfo | awk '{print $2}')
export CPUS
export MEMORY
SELECTOR_LABELS=$(echo "${SELECTOR_LABELS}" | python -c "import sys, json, os; z = json.load(sys.stdin); y = {\"cpu\": os.getenv('CPUS'), \"memory\": os.getenv('MEMORY')}; z.update(y); print(json.dumps(z))")

set +e
export ZONE=""
echo "Probing for AWS metadata"
gather_zone_info() {
	HTTP_RESPONSE=$(curl --write-out "HTTPSTATUS:%{http_code}" --max-time 10 http://169.254.169.254/latest/meta-data/placement/availability-zone)
	HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
	HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS\:[0-9]{3}$//')
	if [[ "$HTTP_STATUS" -ne 200 ]]; then
		echo "bad return code"
		return 1
	fi
	if [[ "$HTTP_BODY" =~ [^a-zA-Z0-9-] ]]; then
		echo "invalid zone format"
		return 1
	fi
	ZONE="$HTTP_BODY"
}
if gather_zone_info; then
	echo "aws metadata detected"
fi
if [[ -z "$ZONE" ]]; then
	echo "echo Probing for Azure Metadata"
	export LOCATION_INFO=""
	export AZURE_ZONE_NUMBER_INFO=""
	gather_location_info() {
		HTTP_RESPONSE=$(curl -H Metadata:true --noproxy "*" --write-out "HTTPSTATUS:%{http_code}" --max-time 10 "http://169.254.169.254/metadata/instance/compute/location?api-version=2021-01-01&format=text")
		HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
		HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS\:[0-9]{3}$//')
		if [[ "$HTTP_STATUS" -ne 200 ]]; then
			echo "bad return code"
			return 1
		fi
		if [[ "$HTTP_BODY" =~ [^a-zA-Z0-9-] ]]; then
			echo "invalid format"
			return 1
		fi
		LOCATION_INFO="$HTTP_BODY"
	}
	gather_azure_zone_number_info() {
		HTTP_RESPONSE=$(curl -H Metadata:true --noproxy "*" --write-out "HTTPSTATUS:%{http_code}" --max-time 10 "http://169.254.169.254/metadata/instance/compute/zone?api-version=2021-01-01&format=text")
		HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
		HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS\:[0-9]{3}$//')
		if [[ "$HTTP_STATUS" -ne 200 ]]; then
			echo "bad return code"
			return 1
		fi
		if [[ "$HTTP_BODY" =~ [^a-zA-Z0-9-] ]]; then
			echo "invalid format"
			return 1
		fi
		AZURE_ZONE_NUMBER_INFO="$HTTP_BODY"
	}
	gather_zone_info() {
		if ! gather_location_info; then
			return 1
		fi
		if ! gather_azure_zone_number_info; then
			return 1
		fi
		if [[ -n "$AZURE_ZONE_NUMBER_INFO" ]]; then
		  ZONE="${LOCATION_INFO}-${AZURE_ZONE_NUMBER_INFO}"
		else
		  ZONE="${LOCATION_INFO}"
		fi
	}
	if gather_zone_info; then
		echo "azure metadata detected"
	fi
fi
if [[ -z "$ZONE" ]]; then
	echo "echo Probing for GCE Metadata"
	gather_zone_info() {
		HTTP_RESPONSE=$(curl --write-out "HTTPSTATUS:%{http_code}" --max-time 10 "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google")
		HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
		HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS\:[0-9]{3}$//')
		if [[ "$HTTP_STATUS" -ne 200 ]]; then
			echo "bad return code"
			return 1
		fi
		POTENTIAL_ZONE_RESPONSE=$(echo "$HTTP_BODY" | awk -F '/' '{print $NF}')
		if [[ "$POTENTIAL_ZONE_RESPONSE" =~ [^a-zA-Z0-9-] ]]; then
			echo "invalid zone format"
			return 1
		fi
		ZONE="$POTENTIAL_ZONE_RESPONSE"
	}
	if gather_zone_info; then
		echo "gce metadata detected"
	fi
fi
set -e
if [[ -n "$ZONE" ]]; then
	SELECTOR_LABELS=$(echo "${SELECTOR_LABELS}" | python -c "import sys, json, os; z = json.load(sys.stdin); y = {\"zone\": os.getenv('ZONE')}; z.update(y); print(json.dumps(z))")
fi
#Step 2: SETUP METADATA
cat <<EOF >register.json
{
"controller": "$CONTROLLER_ID",
"name": "$HOSTNAME",
"identifier": "$MACHINE_ID",
"labels": $SELECTOR_LABELS
}
EOF

set +e
#try to download and run host health check script
set +x
#first try to the satellite-health service is enabled
HTTP_RESPONSE=$(curl --write-out "HTTPSTATUS:%{http_code}" --retry 5 --retry-delay 10 --retry-max-time 60 \
        "${API_URL}satellite-health/api/v1/hello")
set -x
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS\:[0-9]{3}$//')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
echo "$HTTP_STATUS"
if [[ "$HTTP_STATUS" -eq 200 ]]; then
        set +x
        HTTP_RESPONSE=$(curl --write-out "HTTPSTATUS:%{http_code}" --retry 20 --retry-delay 10 --retry-max-time 360 \
                "${API_URL}satellite-health/sat-host-check" -o /usr/local/bin/sat-host-check)
        set -x
        HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS\:[0-9]{3}$//')
        HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')

        echo "$HTTP_BODY"
        echo "$HTTP_STATUS"
        if [[ "$HTTP_STATUS" -eq 200 ]]; then
                chmod +x /usr/local/bin/sat-host-check
                set +x
                timeout 5m /usr/local/bin/sat-host-check --region $REGION --endpoint $API_URL
                set -x
        else
                echo "Error downloading host health check script [HTTP status: $HTTP_STATUS]"
        fi
else
        echo "Skipping downloading host health check script [HTTP status: $HTTP_STATUS]"
fi
set -e

set +x
#STEP 3: REGISTER HOST TO THE HOSTQUEUE. NEED TO EVALUATE HTTP STATUS 409 EXISTS, 201 created. ALL OTHERS FAIL.
HTTP_RESPONSE=$(curl --write-out "HTTPSTATUS:%{http_code}" --retry 100 --retry-delay 10 --retry-max-time 1800 -X POST \
	-H "X-Auth-Hostqueue-APIKey: $HOST_QUEUE_TOKEN" \
	-H "X-Auth-Hostqueue-Account: $ACCOUNT_ID" \
	-H "Content-Type: application/json" \
	-d @register.json \
	"${API_URL}v2/multishift/hostqueue/host/register")
set -x
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS\:[0-9]{3}$//')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')

echo "$HTTP_BODY"
echo "$HTTP_STATUS"
if [[ "$HTTP_STATUS" -ne 201 ]]; then
	echo "Error [HTTP status: $HTTP_STATUS]"
	exit 1
fi

HOST_ID=$(echo "$HTTP_BODY" | python -c "import sys, json; print(json.load(sys.stdin)['id'])")

#STEP 4: WAIT FOR MEMBERSHIP TO BE ASSIGNED
while true; do
	set +ex
	ASSIGNMENT=$(curl --retry 100 --retry-delay 10 --retry-max-time 1800 -G -X GET \
		-H "X-Auth-Hostqueue-APIKey: $HOST_QUEUE_TOKEN" \
		-H "X-Auth-Hostqueue-Account: $ACCOUNT_ID" \
		-d controllerID="$CONTROLLER_ID" \
		-d hostID="$HOST_ID" \
		"${API_URL}v2/multishift/hostqueue/host/getAssignment")
	set -ex
	isAssigned=$(echo "$ASSIGNMENT" | python -c "import sys, json; print(json.load(sys.stdin)['isAssigned'])" | awk '{print tolower($0)}')
	if [[ "$isAssigned" == "true" ]]; then
		break
	fi
	if [[ "$isAssigned" != "false" ]]; then
		echo "unexpected value for assign retrying"
	fi
	sleep 10
done

#STEP 5: ASSIGNMENT HAS BEEN MADE. SAVE SCRIPT AND RUN
echo "$ASSIGNMENT" | python -c "import sys, json; print(json.load(sys.stdin)['script'])" >/usr/local/bin/ibm-host-agent.sh
export HOST_ID
ASSIGNMENT_ID=$(echo "$ASSIGNMENT" | python -c "import sys, json; print(json.load(sys.stdin)['id'])")
cat <<EOF >/etc/satelliteflags/ibm-host-agent-vars
export HOST_ID=${HOST_ID}
export ASSIGNMENT_ID=${ASSIGNMENT_ID}
EOF
chmod 0600 /etc/satelliteflags/ibm-host-agent-vars
chmod 0700 /usr/local/bin/ibm-host-agent.sh
cat <<EOF >/etc/systemd/system/ibm-host-agent.service
[Unit]
Description=IBM Host Agent Service
After=network.target

[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/usr/local/bin/ibm-host-agent.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/ibm-host-agent.service
systemctl daemon-reload
systemctl start ibm-host-agent.service
touch "$HOST_ASSIGN_FLAG"
HERE

chmod 0700 /usr/local/bin/ibm-host-attach.sh
cat << 'EOF' >/etc/systemd/system/ibm-host-attach.service
[Unit]
Description=IBM Host Attach Service
After=network.target

[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/usr/local/bin/ibm-host-attach.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/ibm-host-attach.service
systemctl daemon-reload
systemctl enable ibm-host-attach.service
systemctl start ibm-host-attach.service
