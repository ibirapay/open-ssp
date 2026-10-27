#!/bin/bash
# wt-ops.sh on|off: restart the 3 regtest operators with the watchtower on (stock config) or off.
# Regtest proof helper only; stops by PID from the runner's pid files (never pkill -f).
set -euo pipefail
N=/home/lab/open-ssp/.regtest/open-ssp-breez-e2e/native
case ${1:-} in
  on) CFG=$N/operator.yaml ;;
  off) CFG=$N/operator-wt-off.yaml
       sed '/zmqpubrawblock: tcp:\/\/127.0.0.1:28332/a\    process_nodes_for_watchtowers: false' $N/operator.yaml > $CFG
       grep -q 'process_nodes_for_watchtowers: false' $CFG ;;
  *) echo "usage: $0 on|off" >&2; exit 2 ;;
esac
alive() { [[ -e /proc/$1 ]] && [[ $(awk "{print \$3}" /proc/$1/stat) != Z ]]; }
for i in 0 1 2; do
  name=spark-operator-$i
  pid=$(jq -r .pid $N/$name.pid)
  if [[ $(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null) == *spark-operator* ]]; then
    kill $pid; for _ in $(seq 300); do alive $pid || break; sleep 0.1; done
    alive $pid && { echo "FAIL: $name pid $pid did not stop" >&2; exit 1; }
  fi
  mapfile -t args < <(jq -r '.args[]' $N/$name.json)
  for k in "${!args[@]}"; do [[ ${args[$k]} == */operator*.yaml ]] && args[$k]=$CFG; done
  exe=$(jq -r .executable $N/$name.json)
  env $(jq -r '.env | to_entries[] | "\(.key)=\(.value)"' $N/$name.json) setsid "$exe" "${args[@]}" </dev/null >>$N/$name.log 2>&1 &
  npid=$!
  printf '{"pid":%d,"start_time":"%s"}' $npid "$(awk '{print $22}' /proc/$npid/stat)" > $N/$name.pid
  echo "$name pid $npid config $(basename $CFG)"
done
