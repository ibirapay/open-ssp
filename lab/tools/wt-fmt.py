import json,sys
for line in sys.stdin:
    j=json.loads(line)
    if j["col"]=="row": print("row:", j["row"]); continue
    d=j["tx"]; print(j["col"], d["txid"], "v%d"%d["version"], "vsize", d["vsize"])
    for i in d["vin"]:
        s=i["sequence"]; print("   in ", i["txid"], i["vout"], "seq", hex(s), "csv", s&0xffff if not s&(1<<31) else "-", "wit", len(i.get("txinwitness",[])))
    for o in d["vout"]: print("   out", o["n"], round(o["value"]*1e8), o["scriptPubKey"]["type"])
