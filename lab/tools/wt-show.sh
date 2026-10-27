#!/bin/bash
# wt-show.sh NODE_ID [SO]: print the node's stored txs as JSON lines (regtest proof helper)
. ~/wt-env.sh
L=$1; SO=${2:-0}
for c in raw_tx raw_refund_tx direct_tx direct_refund_tx direct_from_cpfp_refund_tx; do
  h=$(sql "select encode($c,'hex') from tree_nodes where id='$L'" $SO)
  [ -z "$h" ] && continue
  echo "$h" > /tmp/wt-$c.hex
  printf '{"col":"%s","tx":%s}\n' "$c" "$($BTC decoderawtransaction "$h" | tr -d '\n')"
done
printf '{"col":"row","row":"%s"}\n' "$(sql "select status, node_confirmation_height, refund_confirmation_height, vout from tree_nodes where id='$L'" $SO)"
