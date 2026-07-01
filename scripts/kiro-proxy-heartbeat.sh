#!/bin/bash
# kiro-proxy-heartbeat.sh — emit a CloudWatch liveness metric for the kiro-proxy
# systemd --user service (Tier 3 of the 2026-06-30 build-stall outage fix).
#
# WHY: the proxy runs on this box behind Discord/Slack/etc. When it died on
# 2026-06-30 it crash-looped past systemd's StartLimitBurst and stayed dead ~4h
# until a human noticed via Discord. A metric + alarm pages the operator in
# minutes instead.
#
# Metric: namespace OpenClawProxy, name ProxyHealthy (1=healthy, 0=down),
#         dimension Host=<instance-id>. Driven every 60s by
#         kiro-proxy-heartbeat.timer. The paired alarm 'openclaw-kiro-proxy-down'
#         treats MISSING data as breaching, so a dead box (no heartbeat at all)
#         alarms too.
#
# Healthy := kiro-proxy --user unit is active AND something is listening on 18801.
# Always exits 0 so the oneshot service never enters a failed state.
set -uo pipefail
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_BIN="$(command -v aws || echo "$HOME/.local/bin/aws")"
PORT=18801

TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
IID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
IID="${IID:-unknown}"

healthy=0
if systemctl --user is-active --quiet kiro-proxy; then
  if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
    healthy=1
  fi
fi

"$AWS_BIN" cloudwatch put-metric-data \
  --namespace OpenClawProxy \
  --metric-name ProxyHealthy \
  --unit Count \
  --value "$healthy" \
  --dimensions Host="$IID" \
  --storage-resolution 60 >/dev/null 2>&1
rc=$?

echo "[kiro-proxy-heartbeat] healthy=${healthy} iid=${IID} put_metric_rc=${rc}"
exit 0
