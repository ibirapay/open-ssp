# sourced INSIDE spark-lab: regtest-only helpers for the watchtower proof
N=/home/lab/open-ssp/.regtest/open-ssp-breez-e2e/native
BTC="/home/lab/open-ssp/.regtest/native-tools/bitcoin-31.1/bin/bitcoin-cli -datadir=$N/bitcoin -conf=$N/bitcoin.conf"
sql() { psql -h 127.0.0.1 -U postgres -p 54329 -At -F' ' -d sparkoperator_${2:-0} -c "$1"; }
