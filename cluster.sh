#!/usr/bin/env bash
# Usage: ./cluster.sh start | stop | status
#
# Targets any EC2 instance tagged Name=kubing-* in the current AWS CLI
# profile/region. No instance IDs hardcoded, so this keeps working even if
# instances get replaced later.

set -euo pipefail

ACTION="${1:-}"
FILTER="Name=tag:Name,Values=kubing-*"

if [[ -z "$ACTION" ]]; then
  echo "Usage: $0 start|stop|status"
  exit 1
fi

status() {
  aws ec2 describe-instances \
    --filters "$FILTER" \
    --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,InstanceId,State.Name,PrivateIpAddress]" \
    --output table
}

case "$ACTION" in
start)
  IDS=$(aws ec2 describe-instances \
    --filters "$FILTER" "Name=instance-state-name,Values=stopped" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)
  if [[ -z "$IDS" ]]; then
    echo "Nothing to start, no stopped kubing-* instances found."
    exit 0
  fi
  echo "Starting: $IDS"
  aws ec2 start-instances --instance-ids $IDS
  echo "Waiting for instances to reach 'running'..."
  aws ec2 wait instance-running --instance-ids $IDS
  echo "Up. Give Tailscale/kubelet a few seconds to reconnect, then:"
  echo "  kubectl get nodes"
  status
  ;;

stop)
  IDS=$(aws ec2 describe-instances \
    --filters "$FILTER" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)
  if [[ -z "$IDS" ]]; then
    echo "Nothing to stop, no running kubing-* instances found."
    exit 0
  fi
  echo "Stopping: $IDS"
  aws ec2 stop-instances --instance-ids $IDS
  aws ec2 wait instance-stopped --instance-ids $IDS
  echo "Stopped. Compute billing paused, EBS volumes still incur their small storage cost."
  status
  ;;

status)
  status
  ;;

*)
  echo "Usage: $0 start|stop|status"
  exit 1
  ;;
esac
