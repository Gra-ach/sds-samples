#!/bin/bash

exec > /tmp/setup-challenge-1.log 2>&1
set -e

apt-get update
apt-get install -y curl

(cd /root/sds-samples/IDS && ./start.sh)
