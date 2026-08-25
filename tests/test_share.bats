#!/usr/bin/env bats
#
# `netdiag --share` — one run as pasteable plain text.
#
# The reason this exists rather than reusing --redact: lib/output.sh
# deliberately stores every run unredacted (it saves REDACT, forces 0,
# restores), and helpers/history.py drops --redact runs from the store
# entirely. So there is no redacted stored copy to read, and redaction of
# a stored run has to happen at read time.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  RUN="$BATS_TEST_TMPDIR/run.json"
  cat > "$RUN" <<'JSON'
{
  "timestamp": "2026-08-25T12:00:00Z",
  "run_id": "2026-08-25-120000",
  "version": "0.10.0",
  "network": {"id": "wifi:ssid=MyHouse,mac=aa:bb:cc:dd:ee:ff", "label": "MyHouse"},
  "interface": {"name": "en0", "type": "Wi-Fi", "ip": "192.168.15.42",
                "gateway": "192.168.15.1", "gateway_mac": "aa:bb:cc:dd:ee:ff"},
  "public": {"ip": "203.0.113.77", "isp": "Example Telecom SA",
             "asn": "AS64496", "city": "Recife", "country": "Brazil",
             "country_iso": "BR"},
  "wifi": {"ssid": "MyHouse", "bssid": "aa:bb:cc:dd:ee:f0", "channel": 52,
           "rssi": -55},
  "ipv6": {"available": true, "global_addr": "2001:db8:1234:5678::1",
           "gateway": "fe80::a8bb:ccff:fedd:eeff"},
  "gateway": {"ip": "192.168.15.1", "loss_pct": 0.0, "rtt_avg_ms": 7.6},
  "internet_latency": {"rtt_avg_ms": 55.0, "loss_pct": 0.0},
  "mtu": {"effective": 1500},
  "ntp": {"drift_seconds": 0.12},
  "dns": [{"resolver": "192.168.15.1", "ok": true},
          {"resolver": "1.1.1.1", "ok": true}],
  "diagnosis": [
    {"severity": "warn", "rule": "WS-1",
     "summary": "Your WiFi channel is crowded on MyHouse at 203.0.113.77."}
  ]
}
JSON
}

share() { python3 "$REPO/helpers/share.py" < "$RUN"; }

@test "no identifying value survives into the shared text" {
  run share
  [ "$status" -eq 0 ]
  for secret in "203.0.113.77" "MyHouse" "aa:bb:cc:dd:ee:ff" \
                "aa:bb:cc:dd:ee:f0" "2001:db8:1234:5678::1" \
                "fe80::a8bb:ccff:fedd:eeff" "192.168.15.42" "Recife"; do
    [[ "$output" != *"$secret"* ]] || {
      echo "leaked: $secret"; echo "$output"; return 1
    }
  done
}

@test "identifying values are masked inside prose, not just in their own fields" {
  # Diagnosis summaries interpolate these values into sentences, so
  # nulling the field alone would leave the same string in the text
  # beside it. This is why the scrub is a substring pass over the whole
  # tree rather than a field-by-field blank.
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"[redacted]"* ]] || { echo "$output"; return 1; }
}

@test "the ISP and the RFC1918 gateway are deliberately kept" {
  # ISP and ASN name a provider, which is what makes the report worth
  # reading. A 192.168.x.y identifies nobody and blanking it would gut
  # the router rows.
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"Example Telecom SA"* ]] || { echo "ISP was masked"; echo "$output"; return 1; }
  [[ "$output" == *"192.168.15.1"* ]] || { echo "gateway was masked"; echo "$output"; return 1; }
}

@test "the country is kept — two letters are too short to scrub safely" {
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"Brazil"* ]] || { echo "$output"; return 1; }
}

@test "the shared report is plain text with no ANSI escapes" {
  run share
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q $'\033' && {
    echo "ANSI escape in shared output"; return 1
  }
  [[ "$output" != "{"* ]] || { echo "still emitting JSON"; return 1; }
}

@test "the shared report carries the report card and the diagnoses" {
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"Report"* ]] || { echo "no report card"; echo "$output"; return 1; }
  [[ "$output" == *"What we found"* ]] || { echo "no diagnoses"; echo "$output"; return 1; }
  [[ "$output" == *"crowded"* ]] || { echo "diagnosis prose missing"; echo "$output"; return 1; }
}

@test "the shared report states the measurements a reader needs" {
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"7.6"* ]]  || { echo "gateway RTT missing"; return 1; }
  [[ "$output" == *"55"* ]]   || { echo "internet RTT missing"; return 1; }
  [[ "$output" == *"1500"* ]] || { echo "MTU missing"; return 1; }
}

@test "an unmeasured value says so rather than reporting zero" {
  # The CLI's schema draws this line deliberately: treating an unmeasured
  # value as zero is what produced false diagnoses in earlier versions.
  printf '{"timestamp":"2026-08-25T12:00:00Z","gateway":{},"diagnosis":[]}\n' > "$RUN"
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"not measured"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"0.0 ms"* ]] || { echo "reported an unmeasured value as zero"; return 1; }
}

@test "a run with no diagnoses says the network looked healthy" {
  printf '{"timestamp":"2026-08-25T12:00:00Z","gateway":{"rtt_avg_ms":5.0},"diagnosis":[]}\n' > "$RUN"
  run share
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing obviously wrong"* ]] || { echo "$output"; return 1; }
}

@test "malformed input fails with a usage error, never a traceback" {
  run bash -c "printf 'not json' | python3 '$REPO/helpers/share.py'"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Traceback"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"not valid JSON"* ]] || { echo "$output"; return 1; }
}

@test "the expert sections are deliberately absent" {
  # bin/netdiag:483-488 already forces EXPERT=0 under --redact, because
  # the expert panel is where the identifying values live and a
  # partially redacted transcript is worse than none — it looks safe.
  run share
  [ "$status" -eq 0 ]
  [[ "$output" != *"traceroute"* ]] || { echo "expert content leaked"; echo "$output"; return 1; }
}
