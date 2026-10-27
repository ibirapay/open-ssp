#!/bin/bash
# wt-empty.sh TARGET_TIP: mine EMPTY blocks to TARGET_TIP, waiting for every SO to process each one
. ~/wt-env.sh
A=$($BTC -rpcwallet=default getnewaddress mine bech32m)
while [ $($BTC getblockcount) -lt $1 ]; do
  $BTC generateblock $A '[]' >/dev/null; h=$($BTC getblockcount)
  for t in $(seq 60); do ok=1; for i in 0 1 2; do [ "$(sql "select chain_action_height from block_heights" $i)" -ge $h ] || ok=0; done; [ $ok = 1 ] && break; sleep 0.5; done
done
echo "tip $($BTC getblockcount) mempool $($BTC getrawmempool | jq -c .)"
for i in 0 1 2; do echo "SO$i: $(grep "Submitted refund" $N/spark-operator-$i.log | tail -1 | cut -f3 | grep -o 'rung [0-9]* of [0-9]*')"; done
