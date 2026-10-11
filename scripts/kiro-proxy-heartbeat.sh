#!/usr/bin/env bash
# Publish OpenClaw health metrics, capture incidents, and optionally perform one
# guarded gateway-only recovery. The kiro-proxy service is never restarted.
set -euo pipefail
umask 077

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

readonly GATEWAY_BASE_URL="${OPENCLAW_HEALTH_GATEWAY_BASE_URL:-http://127.0.0.1:18800}"
readonly PROXY_BASE_URL="${OPENCLAW_HEALTH_PROXY_BASE_URL:-http://127.0.0.1:18801}"
readonly RECOVERY_MODE="${OPENCLAW_HEALTH_RECOVERY_MODE:-diagnostic}"
readonly FAILURE_THRESHOLD="${OPENCLAW_HEALTH_FAILURE_THRESHOLD:-3}"
readonly RECOVERY_COOLDOWN_SECS="${OPENCLAW_HEALTH_RECOVERY_COOLDOWN_SECS:-1800}"
readonly PROBE_TIMEOUT_SECS="${OPENCLAW_HEALTH_PROBE_TIMEOUT_SECS:-5}"
readonly RECOVERY_HEALTH_ATTEMPTS="${OPENCLAW_HEALTH_RECOVERY_HEALTH_ATTEMPTS:-30}"
readonly RECOVERY_READY_ATTEMPTS="${OPENCLAW_HEALTH_RECOVERY_READY_ATTEMPTS:-30}"
readonly MAX_PROBE_TIMEOUT_SECS=10
readonly MAX_RECOVERY_ATTEMPTS=30
readonly CAPTURE_COMMAND_TIMEOUT_SECS=15
readonly AWS_CALL_TIMEOUT_SECS=15
readonly PROXY_SESSION_TIMEOUT_SECS=5
readonly RESTART_TIMEOUT_SECS=45
readonly STATE_DIR="${OPENCLAW_HEALTH_STATE_DIR:-${HOME}/.openclaw/state/health-monitor}"
readonly INCIDENT_DIR="${OPENCLAW_HEALTH_INCIDENT_DIR:-${HOME}/.openclaw/incidents/gateway-health}"
readonly PUBLISH_METRICS="${OPENCLAW_HEALTH_PUBLISH_METRICS:-1}"
readonly INSTANCE_ID_OVERRIDE="${OPENCLAW_HEALTH_INSTANCE_ID:-}"
readonly CURL_BIN="${OPENCLAW_HEALTH_CURL_BIN:-curl}"
readonly AWS_BIN="${OPENCLAW_HEALTH_AWS_BIN:-$(command -v aws || printf '%s' "${HOME}/.local/bin/aws")}"
readonly SYSTEMCTL_BIN="${OPENCLAW_HEALTH_SYSTEMCTL_BIN:-systemctl}"
readonly JOURNALCTL_BIN="${OPENCLAW_HEALTH_JOURNALCTL_BIN:-journalctl}"
readonly REPO_DIR="/home/ubuntu/openclaw"
readonly GATEWAY_SERVICE="openclaw-gateway.service"
readonly PROXY_SERVICE="kiro-proxy.service"

case "$RECOVERY_MODE" in
  diagnostic|restart) ;;
  *)
    echo "[openclaw-health] invalid OPENCLAW_HEALTH_RECOVERY_MODE=$RECOVERY_MODE" >&2
    exit 2
    ;;
esac
for value_name in FAILURE_THRESHOLD RECOVERY_COOLDOWN_SECS PROBE_TIMEOUT_SECS RECOVERY_HEALTH_ATTEMPTS RECOVERY_READY_ATTEMPTS; do
  value="${!value_name}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "[openclaw-health] $value_name must be a non-negative integer" >&2
    exit 2
  fi
done
if (( FAILURE_THRESHOLD < 1 || PROBE_TIMEOUT_SECS < 1 || RECOVERY_HEALTH_ATTEMPTS < 1 || RECOVERY_READY_ATTEMPTS < 1 )); then
  echo "[openclaw-health] thresholds, probe timeout, and recovery attempts must be at least 1" >&2
  exit 2
fi
if (( PROBE_TIMEOUT_SECS > MAX_PROBE_TIMEOUT_SECS \
   || RECOVERY_HEALTH_ATTEMPTS > MAX_RECOVERY_ATTEMPTS \
   || RECOVERY_READY_ATTEMPTS > MAX_RECOVERY_ATTEMPTS )); then
  echo "[openclaw-health] probe timeout/recovery attempts exceed the service-timeout budget" >&2
  exit 2
fi
if [[ "$PUBLISH_METRICS" != "0" && "$PUBLISH_METRICS" != "1" ]]; then
  echo "[openclaw-health] OPENCLAW_HEALTH_PUBLISH_METRICS must be 0 or 1" >&2
  exit 2
fi

mkdir -p "$STATE_DIR" "$INCIDENT_DIR"
chmod 700 "$STATE_DIR" "$INCIDENT_DIR"
exec 9>"$STATE_DIR/monitor.lock"
if ! flock -n 9; then
  echo "[openclaw-health] another monitor run is active; skipping"
  exit 0
fi

RUN_DIR=$(mktemp -d "$STATE_DIR/run.XXXXXX")
trap 'rm -rf "$RUN_DIR"' EXIT

declare -A PROBE_URL PROBE_CODE PROBE_RC PROBE_LATENCY_MS PROBE_ERROR PROBE_BODY PROBE_STDERR

probe() {
  local name="$1"
  local url="$2"
  local output rc code seconds latency body_file stderr_file
  body_file="$RUN_DIR/${name}.body"
  stderr_file="$RUN_DIR/${name}.stderr"

  set +e
  output=$("$CURL_BIN" -sS --connect-timeout 2 --max-time "$PROBE_TIMEOUT_SECS" \
    -o "$body_file" -w '%{http_code}|%{time_total}' "$url" 2>"$stderr_file")
  rc=$?
  set -e

  IFS='|' read -r code seconds <<<"$output"
  code="${code:-000}"
  seconds="${seconds:-0}"
  latency=$(awk -v seconds="$seconds" 'BEGIN { printf "%.0f", seconds * 1000 }')

  PROBE_URL[$name]="$url"
  PROBE_CODE[$name]="$code"
  PROBE_RC[$name]="$rc"
  PROBE_LATENCY_MS[$name]="$latency"
  PROBE_ERROR[$name]="$(tr '\n' ' ' <"$stderr_file" | cut -c1-500)"
  PROBE_BODY[$name]="$body_file"
  PROBE_STDERR[$name]="$stderr_file"
}

probe_ok() {
  local name="$1"
  [[ "${PROBE_RC[$name]}" -eq 0 && "${PROBE_CODE[$name]}" == "200" ]]
}

probe proxy "$PROXY_BASE_URL/"
probe gateway_health "$GATEWAY_BASE_URL/healthz"
probe gateway_ready "$GATEWAY_BASE_URL/readyz"
probe control_ui "$GATEWAY_BASE_URL/"

proxy_healthy=0
gateway_healthy=0
gateway_ready=0
control_ui_healthy=0
probe_ok proxy && proxy_healthy=1
probe_ok gateway_health && gateway_healthy=1
probe_ok gateway_ready && gateway_ready=1
probe_ok control_ui && control_ui_healthy=1

instance_id() {
  if [[ -n "$INSTANCE_ID_OVERRIDE" ]]; then
    printf '%s\n' "$INSTANCE_ID_OVERRIDE"
    return
  fi

  local token iid
  token=$("$CURL_BIN" -sf --connect-timeout 1 --max-time 2 -X PUT \
    http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)
  iid=$("$CURL_BIN" -sf --connect-timeout 1 --max-time 2 \
    -H "X-aws-ec2-metadata-token: $token" \
    http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)
  printf '%s\n' "${iid:-unknown}"
}

IID=$(instance_id)
metric_rc=0
publish_metrics() {
  local metric_file="$RUN_DIR/metrics.json"
  python3 - "$metric_file" \
    "$proxy_healthy" "${PROBE_CODE[proxy]}" "${PROBE_LATENCY_MS[proxy]}" \
    "$gateway_healthy" "${PROBE_CODE[gateway_health]}" "${PROBE_LATENCY_MS[gateway_health]}" \
    "$gateway_ready" "${PROBE_CODE[gateway_ready]}" "${PROBE_LATENCY_MS[gateway_ready]}" \
    "$control_ui_healthy" "${PROBE_CODE[control_ui]}" "${PROBE_LATENCY_MS[control_ui]}" <<'PY'
import json
import sys

path = sys.argv[1]
values = [int(float(value or 0)) for value in sys.argv[2:]]
names = [
    ("ProxyHealthy", "Count"),
    ("ProxyHttpStatus", "Count"),
    ("ProxyLatencyMs", "Milliseconds"),
    ("GatewayHealthy", "Count"),
    ("GatewayHealthHttpStatus", "Count"),
    ("GatewayHealthLatencyMs", "Milliseconds"),
    ("GatewayReady", "Count"),
    ("GatewayReadyHttpStatus", "Count"),
    ("GatewayReadyLatencyMs", "Milliseconds"),
    ("ControlUiHealthy", "Count"),
    ("ControlUiHttpStatus", "Count"),
    ("ControlUiLatencyMs", "Milliseconds"),
]
metrics = [
    {
        "MetricName": name,
        "Value": value,
        "Unit": unit,
        "Dimensions": [{"Name": "Host", "Value": "INSTANCE_ID"}],
        "StorageResolution": 60,
    }
    for (name, unit), value in zip(names, values, strict=True)
]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(metrics, handle, separators=(",", ":"))
PY
  python3 - "$metric_file" "$IID" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text(encoding="utf-8").replace("INSTANCE_ID", sys.argv[2]), encoding="utf-8")
PY

  set +e
  timeout "$AWS_CALL_TIMEOUT_SECS" "$AWS_BIN" cloudwatch put-metric-data --namespace OpenClawProxy \
    --metric-data "file://$metric_file" >/dev/null 2>"$RUN_DIR/aws.stderr"
  metric_rc=$?
  set -e
  if [[ "$metric_rc" -ne 0 ]]; then
    echo "[openclaw-health] CloudWatch publish failed rc=$metric_rc: $(tr '\n' ' ' <"$RUN_DIR/aws.stderr" | cut -c1-500)" >&2
  fi
}

publish_event_metric() {
  local name="$1"
  local value="$2"
  local event_file="$RUN_DIR/event-metric.json"
  [[ "$PUBLISH_METRICS" == "1" ]] || return 0
  python3 - "$event_file" "$name" "$value" "$IID" <<'PY'
import json
import sys

path, name, value, instance_id = sys.argv[1:]
metric = [{
    "MetricName": name,
    "Value": int(value),
    "Unit": "Count",
    "Dimensions": [{"Name": "Host", "Value": instance_id}],
    "StorageResolution": 60,
}]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(metric, handle, separators=(",", ":"))
PY
  timeout "$AWS_CALL_TIMEOUT_SECS" "$AWS_BIN" cloudwatch put-metric-data \
    --namespace OpenClawProxy --metric-data "file://$event_file" >/dev/null 2>&1 || true
}

if [[ "$PUBLISH_METRICS" == "1" ]]; then
  publish_metrics
fi

read_int_file() {
  local path="$1"
  local fallback="$2"
  local value=""
  if [[ -f "$path" ]]; then
    read -r value <"$path" || true
  fi
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

read_text_file() {
  local path="$1"
  local value=""
  if [[ -f "$path" ]]; then
    read -r value <"$path" || true
  fi
  printf '%s\n' "$value"
}

atomic_write() {
  local path="$1"
  local value="$2"
  local temp="${path}.tmp.$$"
  printf '%s\n' "$value" >"$temp"
  mv "$temp" "$path"
}

copy_probe_artifacts() {
  local incident="$1"
  local name
  for name in proxy gateway_health gateway_ready control_ui; do
    head -c 8192 "${PROBE_BODY[$name]}" >"$incident/${name}.body" 2>/dev/null || true
    head -c 4096 "${PROBE_STDERR[$name]}" >"$incident/${name}.stderr" 2>/dev/null || true
  done
}

capture_incident() {
  local incident_id="$1"
  local failures="$2"
  local incident="$INCIDENT_DIR/$incident_id"
  mkdir -p "$incident"
  [[ -f "$incident/capture-complete" ]] && return 0

  {
    printf 'captured_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'instance_id=%s\n' "$IID"
    printf 'recovery_mode=%s\n' "$RECOVERY_MODE"
    printf 'consecutive_liveness_failures=%s\n' "$failures"
    for name in proxy gateway_health gateway_ready control_ui; do
      printf '%s_url=%s\n' "$name" "${PROBE_URL[$name]}"
      printf '%s_http_status=%s\n' "$name" "${PROBE_CODE[$name]}"
      printf '%s_curl_rc=%s\n' "$name" "${PROBE_RC[$name]}"
      printf '%s_latency_ms=%s\n' "$name" "${PROBE_LATENCY_MS[$name]}"
      printf '%s_error=%s\n' "$name" "${PROBE_ERROR[$name]}"
    done
  } >"$incident/probes.env"
  copy_probe_artifacts "$incident"

  timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" bash -c 'date --iso-8601=seconds; uptime; free -h; df -h /' \
    >"$incident/host.txt" 2>&1 || true
  timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" "$SYSTEMCTL_BIN" --user show "$GATEWAY_SERVICE" "$PROXY_SERVICE" \
    --property=Id,LoadState,ActiveState,SubState,MainPID,NRestarts,ExecMainStartTimestamp,MemoryCurrent,MemoryPeak \
    >"$incident/systemd-show.txt" 2>&1 || true
  timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" "$SYSTEMCTL_BIN" --user status "$GATEWAY_SERVICE" "$PROXY_SERVICE" --no-pager \
    2>&1 | head -c 262144 >"$incident/systemd-status.txt" || true
  timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" "$JOURNALCTL_BIN" --user -u "$GATEWAY_SERVICE" --since '-15 minutes' -n 400 \
    --no-pager --output=short-iso 2>&1 | head -c 524288 >"$incident/gateway-journal.txt" || true
  timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" "$JOURNALCTL_BIN" --user -u "$PROXY_SERVICE" --since '-15 minutes' -n 200 \
    --no-pager --output=short-iso 2>&1 | head -c 524288 >"$incident/proxy-journal.txt" || true
  timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" ss -ltnp >"$incident/listeners.txt" 2>&1 || true
  timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" ps -eo pid,ppid,etimes,rss,stat,comm \
    >"$incident/processes.txt" 2>&1 || true
  "$CURL_BIN" -sS --connect-timeout 2 --max-time "$PROXY_SESSION_TIMEOUT_SECS" \
    "$PROXY_BASE_URL/sessions" >"$incident/proxy-sessions.json" \
    2>"$incident/proxy-sessions.stderr" || true
  timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" git -C "$REPO_DIR" rev-parse HEAD \
    >"$incident/repo-head.txt" 2>&1 || true
  timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" git -C "$REPO_DIR" status --short \
    >"$incident/repo-status.txt" 2>&1 || true
  timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" stat "$REPO_DIR/openclaw.mjs" "$REPO_DIR/dist/index.js" \
    "$REPO_DIR/dist/plugin-sdk/state-paths.js" >"$incident/runtime-artifacts.txt" 2>&1 || true
  timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" sha256sum "$REPO_DIR/openclaw.mjs" "$REPO_DIR/dist/index.js" \
    "$REPO_DIR/dist/plugin-sdk/state-paths.js" >>"$incident/runtime-artifacts.txt" 2>&1 || true
  printf '%s\n' "$(date --iso-8601=seconds)" >"$incident/capture-complete"
  echo "[openclaw-health] incident captured: $incident"
}

PROMPTING_COUNT="unknown"
proxy_prompting_count() {
  local sessions_file="$RUN_DIR/recovery-sessions.json"
  if ! "$CURL_BIN" -sS --connect-timeout 2 --max-time "$PROXY_SESSION_TIMEOUT_SECS" "$PROXY_BASE_URL/sessions" \
    -o "$sessions_file" 2>"$RUN_DIR/recovery-sessions.stderr"; then
    return 1
  fi
  if ! PROMPTING_COUNT=$(python3 - "$sessions_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
print(sum(1 for session in payload.get("sessions", []) if session.get("isPrompting") is True))
PY
  ); then
    PROMPTING_COUNT="unknown"
    return 1
  fi
  [[ "$PROMPTING_COUNT" =~ ^[0-9]+$ ]]
}

wait_for_probe() {
  local name="$1"
  local url="$2"
  local attempts="$3"
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    probe "$name" "$url"
    if probe_ok "$name"; then
      return 0
    fi
    if (( attempt < attempts )); then
      sleep 1
    fi
  done
  return 1
}

attempt_gateway_recovery() {
  local incident_id="$1"
  local incident="$INCIDENT_DIR/$incident_id"
  local now last_recovery attempted_incident
  now=$(date +%s)
  last_recovery=$(read_int_file "$STATE_DIR/last-recovery-epoch" 0)
  attempted_incident=$(read_text_file "$STATE_DIR/recovery-attempted-incident")

  if [[ "$attempted_incident" == "$incident_id" ]]; then
    echo "[openclaw-health] recovery already attempted for incident=$incident_id; escalating only"
    return 0
  fi
  if (( now - last_recovery < RECOVERY_COOLDOWN_SECS )); then
    echo "[openclaw-health] recovery deferred by ${RECOVERY_COOLDOWN_SECS}s cooldown"
    return 0
  fi
  if [[ "$proxy_healthy" -ne 1 ]]; then
    echo "[openclaw-health] recovery deferred: proxy liveness is unhealthy"
    publish_event_metric GatewayRecoveryDeferred 1
    return 0
  fi
  if ! proxy_prompting_count; then
    echo "[openclaw-health] recovery deferred: proxy session activity is unknown"
    publish_event_metric GatewayRecoveryDeferred 1
    return 0
  fi
  if (( PROMPTING_COUNT > 0 )); then
    echo "[openclaw-health] recovery deferred: $PROMPTING_COUNT proxy session(s) are prompting"
    publish_event_metric GatewayRecoveryDeferred 1
    return 0
  fi

  atomic_write "$STATE_DIR/recovery-attempted-incident" "$incident_id"
  atomic_write "$STATE_DIR/last-recovery-epoch" "$now"
  printf '%s gateway-only restart requested\n' "$(date --iso-8601=seconds)" >>"$incident/recovery.log"
  publish_event_metric GatewayRecoveryAttempted 1

  if ! timeout "$RESTART_TIMEOUT_SECS" "$SYSTEMCTL_BIN" --user restart "$GATEWAY_SERVICE" \
    >>"$incident/recovery.log" 2>&1; then
    printf '%s gateway restart command failed\n' "$(date --iso-8601=seconds)" >>"$incident/recovery.log"
    publish_event_metric GatewayRecoverySucceeded 0
    echo "[openclaw-health] gateway-only recovery command failed; no retry until a new incident"
    return 0
  fi

  if wait_for_probe recovery_health "$GATEWAY_BASE_URL/healthz" "$RECOVERY_HEALTH_ATTEMPTS"; then
    printf '%s healthz recovered status=%s latency_ms=%s\n' \
      "$(date --iso-8601=seconds)" "${PROBE_CODE[recovery_health]}" \
      "${PROBE_LATENCY_MS[recovery_health]}" >>"$incident/recovery.log"
    if wait_for_probe recovery_ready "$GATEWAY_BASE_URL/readyz" "$RECOVERY_READY_ATTEMPTS"; then
      printf '%s readyz recovered status=%s latency_ms=%s\n' \
        "$(date --iso-8601=seconds)" "${PROBE_CODE[recovery_ready]}" \
        "${PROBE_LATENCY_MS[recovery_ready]}" >>"$incident/recovery.log"
    else
      printf '%s healthz live but readyz still unhealthy status=%s error=%s\n' \
        "$(date --iso-8601=seconds)" "${PROBE_CODE[recovery_ready]}" \
        "${PROBE_ERROR[recovery_ready]}" >>"$incident/recovery.log"
    fi
    timeout "$CAPTURE_COMMAND_TIMEOUT_SECS" "$SYSTEMCTL_BIN" --user status "$GATEWAY_SERVICE" --no-pager \
      >"$incident/post-recovery-systemd.txt" 2>&1 || true
    publish_event_metric GatewayRecoverySucceeded 1
    echo "[openclaw-health] gateway-only recovery succeeded for incident=$incident_id"
  else
    printf '%s healthz did not recover status=%s error=%s\n' \
      "$(date --iso-8601=seconds)" "${PROBE_CODE[recovery_health]}" \
      "${PROBE_ERROR[recovery_health]}" >>"$incident/recovery.log"
    publish_event_metric GatewayRecoverySucceeded 0
    echo "[openclaw-health] gateway-only recovery did not restore health; no automatic retry"
  fi
}

failure_file="$STATE_DIR/consecutive-gateway-health-failures"
incident_file="$STATE_DIR/current-incident-id"
previous_failures=$(read_int_file "$failure_file" 0)

if [[ "$gateway_healthy" -eq 1 ]]; then
  if (( previous_failures > 0 )); then
    echo "[openclaw-health] gateway liveness recovered after $previous_failures failed probe(s)"
  fi
  atomic_write "$failure_file" 0
  rm -f "$incident_file" "$STATE_DIR/recovery-attempted-incident"
else
  failures=$((previous_failures + 1))
  atomic_write "$failure_file" "$failures"
  echo "[openclaw-health] gateway liveness failure $failures/$FAILURE_THRESHOLD status=${PROBE_CODE[gateway_health]} curl_rc=${PROBE_RC[gateway_health]} error=${PROBE_ERROR[gateway_health]}"

  if (( failures >= FAILURE_THRESHOLD )); then
    incident_id=$(read_text_file "$incident_file")
    if [[ -z "$incident_id" ]]; then
      incident_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
      atomic_write "$incident_file" "$incident_id"
    fi
    capture_incident "$incident_id" "$failures"
    if [[ "$RECOVERY_MODE" == "restart" ]]; then
      attempt_gateway_recovery "$incident_id"
    else
      echo "[openclaw-health] diagnostic-only mode: incident captured; no restart attempted"
    fi
  fi
fi

echo "[openclaw-health] proxy=${proxy_healthy}(http=${PROBE_CODE[proxy]},rc=${PROBE_RC[proxy]},ms=${PROBE_LATENCY_MS[proxy]}) gateway=${gateway_healthy}(http=${PROBE_CODE[gateway_health]},rc=${PROBE_RC[gateway_health]},ms=${PROBE_LATENCY_MS[gateway_health]}) ready=${gateway_ready}(http=${PROBE_CODE[gateway_ready]},rc=${PROBE_RC[gateway_ready]},ms=${PROBE_LATENCY_MS[gateway_ready]}) ui=${control_ui_healthy}(http=${PROBE_CODE[control_ui]},rc=${PROBE_RC[control_ui]},ms=${PROBE_LATENCY_MS[control_ui]}) mode=${RECOVERY_MODE} iid=${IID} put_metric_rc=${metric_rc}"

exit "$metric_rc"
