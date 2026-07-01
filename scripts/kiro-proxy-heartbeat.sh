#!/bin/bash
# kiro-proxy-heartbeat.sh — emit CloudWatch liveness metrics for the OpenClaw
# stack on this box (Tier 3 of the 2026-06-30 build-stall outage fix).
#
# Emits every 60s (via kiro-proxy-heartbeat.timer):
#   OpenClawProxy/ProxyHealthy    1 iff kiro-proxy answers HTTP 200 on :18801
#   OpenClawProxy/GatewayHealthy  1 iff openclaw-gateway answers HTTP 200 on :18800
# dimension Host=<instance-id>.
#
# HTTP-based on purpose (not just "unit active / port listening"): the
# 2026-06-30 22:58 incident was the GATEWAY dead ~6h while a port-only proxy
# check reported healthy=1. An HTTP probe with a timeout reads a hung- or
# dead-but-listening process as DOWN, and covers the gateway too.
#
# Paired alarms (treat-missing-data=breaching, so a dead box also pages):
#   openclaw-kiro-proxy-down  on ProxyHealthy
#   openclaw-gateway-down     on GatewayHealthy
set -uo pipefail
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_BIN="$(command -v aws || echo "$HOME/.local/bin/aws")"
PROXY_PORT=18801
GATEWAY_PORT=18800

TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
IID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
IID="${IID:-unknown}"

# 1 iff an HTTP GET to the port returns 200 within 5s (catches down AND hung).
http_healthy() {
  local port="$1" code
  code=$(curl -sS -m 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${port}/" 2>/dev/null)
  [ "$code" = "200" ] && echo 1 || echo 0
}

proxy=$(http_healthy "$PROXY_PORT")
gateway=$(http_healthy "$GATEWAY_PORT")

"$AWS_BIN" cloudwatch put-metric-data --namespace OpenClawProxy --metric-data \
"[{\"MetricName\":\"ProxyHealthy\",\"Value\":${proxy},\"Unit\":\"Count\",\"Dimensions\":[{\"Name\":\"Host\",\"Value\":\"${IID}\"}],\"StorageResolution\":60},{\"MetricName\":\"GatewayHealthy\",\"Value\":${gateway},\"Unit\":\"Count\",\"Dimensions\":[{\"Name\":\"Host\",\"Value\":\"${IID}\"}],\"StorageResolution\":60}]" \
  >/dev/null 2>&1
rc=$?

echo "[openclaw-heartbeat] proxy=${proxy} gateway=${gateway} iid=${IID} put_metric_rc=${rc}"
exit 0
