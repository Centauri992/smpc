#!/bin/bash
set -e

# Update and install dependencies
apt-get update
apt-get install -y python3-pip git python3-venv

# Clone your repo
cd /root
git clone https://github.com/Centauri992/smpc.git
cd YOUR_REPO

# Set up virtualenv
python3 -m venv smpc-venv
source smpc-venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# Fetch instance attributes
PARTY_ID="$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/attributes/party_id -H 'Metadata-Flavor: Google')"
BUCKET="$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket -H 'Metadata-Flavor: Google')"
TOTAL="$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/attributes/total -H 'Metadata-Flavor: Google')"
LOCAL_IP="$(hostname -I | awk '{print $1}')"

# Register IP for coordination
echo "$LOCAL_IP" | gsutil cp - gs://$BUCKET/party-$PARTY_ID

# Wait for all 3 IPs
while [ $(gsutil ls gs://$BUCKET/party-* | wc -l) -lt $TOTAL ]; do
  sleep 2
done

# Read all party IPs
HOSTS=""
for i in $(seq 0 $(($TOTAL - 1))); do
  IP=$(gsutil cat gs://$BUCKET/party-$i)
  HOSTS="${HOSTS}${IP},"
done
HOSTS=${HOSTS::-1}

echo "PARTY $PARTY_ID running on $LOCAL_IP with hosts: $HOSTS"

BATCH=10
TOTAL_IMAGES=10000
cd /root/YOUR_REPO
source smpc-venv/bin/activate

# Loop over all protocols
for PROTO in 0 1 2; do
  OUT="results_party${PARTY_ID}_k${PROTO}.txt"
  echo "Protocol d_k_star = $PROTO" > $OUT
  for OFFSET in $(seq 0 $BATCH $((TOTAL_IMAGES-1))); do
    python3 smpc.py -M $TOTAL -P $PARTY_ID -H $HOSTS -b $BATCH -o $OFFSET -d $PROTO >> $OUT
  done
  gsutil cp $OUT gs://$BUCKET/
done

# Toft's protocol
OUT="results_party${PARTY_ID}_toft.txt"
echo "Protocol Toft (built-in MPyC)" > $OUT
for OFFSET in $(seq 0 $BATCH $((TOTAL_IMAGES-1))); do
  python3 smpc.py -M $TOTAL -P $PARTY_ID -H $HOSTS -b $BATCH -o $OFFSET --no-legendre >> $OUT
done
gsutil cp $OUT gs://$BUCKET/

# Write done marker
gsutil cp <(echo "done") gs://$BUCKET/party-${PARTY_ID}-done

# Wait for all to finish, then shutdown
while [ $(gsutil ls gs://$BUCKET/party-*-done | wc -l) -lt $TOTAL ]; do
  sleep 5
done

INSTANCE_NAME=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/name" -H "Metadata-Flavor: Google")
ZONE=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google" | awk -F/ '{print $NF}')
gcloud compute instances stop $INSTANCE_NAME --zone=$ZONE --quiet

