#!/usr/bin/env bash
set -euo pipefail

: "${VNC_TEST_HOST:?Set VNC_TEST_HOST to the test server address}"
: "${VNC_TEST_PASSWORD:?Set VNC_TEST_PASSWORD without placing it in this script}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/../.." && pwd)"
package_dir="${repo_dir}"
timestamp="$(date +%Y%m%d-%H%M%S)"
output_dir="${VNC_NETWORK_MATRIX_OUT:-${package_dir}/.build/network-benchmarks/${timestamp}}"
mkdir -p "${output_dir}"
results_file="${output_dir}/results.txt"
: > "${results_file}"

# name|RTT ms|jitter ms|loss %|downstream kbps|loss recovery ms
scenarios=(
  "baseline|0|0|0|0|200"
  "good-wan|40|5|0.2|12000|200"
  "typical-wan|100|15|1.0|6000|220"
  "adverse-wan|180|30|2.0|3000|250"
)

selected=",${VNC_NETWORK_SCENARIOS:-all},"
for row in "${scenarios[@]}"; do
  IFS='|' read -r name rtt jitter loss bandwidth recovery <<< "${row}"
  if [[ "${selected}" != ",all," && "${selected}" != *",${name},"* ]]; then
    continue
  fi

  log_file="${output_dir}/${name}.log"
  echo "Running ${name}: RTT=${rtt}ms jitter=${jitter}ms loss=${loss}% downstream=${bandwidth}kbps"
  set +e
  (
    cd "${package_dir}"
    export VNC_PROBE_SCENARIO="${name}"
    export VNC_PROBE_RTT_MS="${rtt}"
    export VNC_PROBE_JITTER_MS="${jitter}"
    export VNC_PROBE_LOSS_PERCENT="${loss}"
    export VNC_PROBE_LOSS_RECOVERY_MS="${recovery}"
    export VNC_PROBE_BANDWIDTH_KBPS="${bandwidth}"
    export VNC_PROBE_ENCODING=dct
    export VNC_PROBE_RENDER_DCT=1
    export VNC_PROBE_SECONDS="${VNC_PROBE_SECONDS:-8}"
    if [[ "${VNC_PROBE_INCLUDE_TRANSPORT:-1}" == "1" ]]; then
      swift test -c release \
        --filter 'LiveStandardModeProbeTests/testStandardModeUpdateCadenceAndDecodeHealth'
    fi
    if [[ "${VNC_PROBE_INCLUDE_PRESENTATION:-1}" == "1" ]]; then
      IFS=',' read -ra holds <<< "${VNC_PROBE_PRESENTATION_HOLDS:-default}"
      for hold in "${holds[@]}"; do
        if [[ "${hold}" == "default" ]]; then
          VNC_PROBE_PRESENTATION=1 swift test -c release \
            --filter 'LiveStandardModeProbeTests/testConditionedStandardPresentationCadence'
        else
          ROOTSHELL_VNC_DCT_REFINEMENT_HOLD_MS="${hold}" \
          VNC_PROBE_PRESENTATION=1 swift test -c release \
            --filter 'LiveStandardModeProbeTests/testConditionedStandardPresentationCadence'
        fi
      done
    fi
  ) 2>&1 | tee "${log_file}"
  status=${PIPESTATUS[0]}
  set -e

  probe_lines="$(rg '^PROBE (RESULT|TRADEOFF|PRESENTATION) ' \
    "${log_file}" || true)"
  if [[ -n "${probe_lines}" ]]; then
    printf '%s\n' "${probe_lines}" | tee -a "${results_file}"
  else
    printf 'PROBE RESULT scenario=%s status=failed exit=%d\n' \
      "${name}" "${status}" | tee -a "${results_file}"
  fi
done

echo "Results: ${results_file}"
