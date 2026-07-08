#!/usr/bin/env bash

failures=0

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

echo "Validating node: $(hostname)"
echo

#check1: swap should be off

if swapon --show | grep -q .; then
  fail "swap is active"
else
  pass "swap is off"
fi

#check2: ipv4 forwarding should be enabled
if [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]; then
  pass "ipv4 forwarding is enabled"
else
  fail "ipv4 forwarding is not enabled"
fi

# Check 3: containerd should be running
if systemctl is-active --quiet containerd; then
  pass "containerd is running"
else
  fail "containerd is not running"
fi

# Check 4: Kubernetes tools should be installed
if command -v kubeadm >/dev/null 2>&1 &&
  command -v kubelet >/dev/null 2>&1 &&
  command -v kubectl >/dev/null 2>&1; then
  pass "kubeadm, kubelet, and kubectl are installed"
else
  fail "one or more Kubernetes tools are missing"
fi

#check 5: does the containerd socket exist?
if [ -S /run/containerd/containerd.sock ]; then
  pass "containerd socket exists"
else
  fail "containerd socket is missing"
fi

#is CRI disabled still?
if grep -q 'disabled_plugins.*cri' /etc/containerd/config.toml; then
  fail "containerd CRI appears to be disabled"
else
  pass "containerd CRI is not disabled"
fi
#is systemd = true?
if grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
  pass "containerd uses systemd cgroups"
else
  fail "containerd SystemdCgroup is not true"
fi

echo

if [ "$failures" -eq 0 ]; then
  echo "Node validation passed"
  exit 0
else
  echo "Node validation failed: $failures issue(s)"
  exit 1
fi
