#!/bin/bash
# wt-cpfp.sh PARENT_HEX_FILE ANCHOR_VOUT: submitpackage [parent, v3 child spending the P2A anchor + a wallet coin]
set -euo pipefail
. ~/wt-env.sh
W="$BTC -rpcwallet=default"
P=$(cat $1); V=$2
PTXID=$($BTC decoderawtransaction $P | jq -r .txid)
U=$($W listunspent 101 | jq -c '[.[] | select(.amount >= 0.001)] | sort_by(.amount) | .[0]')
UT=$(jq -r .txid <<<"$U"); UV=$(jq -r .vout <<<"$U"); UA=$(jq -r .amount <<<"$U")
CHG=$(jq -n "($UA * 1e8 - 2000) | floor | . / 1e8")
ADDR=$($W getnewaddress wt bech32m)
RAW=$($BTC createrawtransaction "[{\"txid\":\"$PTXID\",\"vout\":$V},{\"txid\":\"$UT\",\"vout\":$UV}]" "[{\"$ADDR\":$CHG}]" 0 true 3)
SIG=$($W signrawtransactionwithwallet $RAW "[{\"txid\":\"$PTXID\",\"vout\":$V,\"scriptPubKey\":\"51024e73\",\"amount\":0}]")
jq -c '{complete, errors}' <<<"$SIG"
C=$(jq -r .hex <<<"$SIG")
$BTC submitpackage "[\"$P\",\"$C\"]" | jq -c '{package_msg, tx: [.["tx-results"][] | {txid, error}]}'
