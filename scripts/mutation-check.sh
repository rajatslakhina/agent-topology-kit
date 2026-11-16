#!/usr/bin/env bash
# Each mutant re-introduces a specific bug the README claims the design prevents.
# A mutant "survives" if the test suite still passes with it applied: that means the
# claim is untested. The script fails if any mutant survives, if a mutant does not
# compile, if a pattern is not found exactly once, or if the unmutated suite fails.
set -u
cd "$(dirname "$0")/.."
S=Sources/AgentTopology
# file | exact text to replace (must occur exactly once) | replacement | the claim it breaks
MUTANTS=(
  "$S/Capabilities.swift|if !server.advertised.contains(req.feature) {|if false {|a feature needs the server's advertisement, not just its version"
  "$S/Capabilities.swift|if server.version < req.minimumVersion {|if false {|a feature needs the minimum server version, not just the advertisement"
  "$S/Capabilities.swift|if newer && req.skewSensitive {|if false {|skew-sensitive features are held back on servers newer than tested"
  "$S/Capabilities.swift|if server.version < window.minimumSupported {|if false {|servers below the support window are refused"
  "$S/EventSequencer.swift|let fresh = page.events.filter { \$0.sequence > position }|let fresh = page.events|duplicates are dropped (exactly once)"
  "$S/EventSequencer.swift|guard event.sequence == expected else {|guard event.sequence >= expected else {|a page with a hole is rejected (no gaps)"
  "$S/EventSequencer.swift|if current.epoch != page.epoch {|if false {|a page from another epoch never applies on the old cursor"
  "$S/EventSequencer.swift|if page.previousEpoch == current.epoch, let fork = page.forkPoint {|if let fork = page.forkPoint {|a fork point only counts when the lineage names our epoch"
  "$S/EventSequencer.swift|inherited = min(current.sequence, fork, page.highWater)|inherited = min(fork, page.highWater)|the cursor never moves past what the client saw"
  "$S/EventSequencer.swift|if page.highWater < current.sequence {|if false {|history shrinking inside one epoch is a contract violation"
  "$S/EventSequencer.swift|guard event.sequence > previous else {|guard event.sequence != previous else {|non-monotonic pages are malformed"
  "$S/SessionEventSync.swift|            // Suspension point above: a reset may have happened while the request was in flight.
            guard generation == myGeneration else { return .discardedStale }|            // (re-check removed)|a page fetched before reset() never lands after it"
  "$S/SessionEventSync.swift|if inFlightGeneration == myGeneration { return .busy }|_ = inFlightGeneration|concurrent pumps do not double-fetch"
  "$S/SessionEventSync.swift|        return min(value, capMilliseconds)|        return value|backoff is capped"
  "$S/SessionEventSync.swift|return Saturating.clamp(random.next(upTo: ceiling), to: 0...ceiling)|return random.next(upTo: ceiling)|jitter stays inside 0...ceiling whatever the random source returns"
  "$S/SessionEventSync.swift|                sequencer.reset()
                return .resyncRequired|                return .resyncRequired|an expired cursor forces a full resync"
  "$S/Residency.swift|guard allowedHosts.contains(host) else|guard allowedHosts.contains(where: { host.hasSuffix(\$0) }) else|hosts match exactly, never by suffix"
  "$S/Residency.swift|case \"http\" where allowsLoopbackHTTP && ManagedConfigParser.isLoopback(host): break|case \"http\": break|plain HTTP only for opted-in loopback"
  "$S/TenantConfiguration.swift|if topology == .selfHosted, hosts.contains(TenantConfiguration.hostedHost) {|if false {|a self-hosted tenant may not allow the hosted API host"
  "$S/TenantConfiguration.swift|if topology == .hosted, let extra = hosts.subtracting([baseHost]).sorted().first {|if false, let extra = hosts.subtracting([baseHost]).sorted().first {|a hosted tenant has exactly one allowed origin"
  "$S/ServerVersion.swift|            text = text[..<plus]|            return nil|valid SemVer build metadata does not take a tenant offline"
  "$S/TenantConfiguration.swift|guard hosts.contains(baseHost) else|guard !hosts.isEmpty else|the base URL's host must be allowlisted"
  "$S/Transport.swift|case 410: throw TransportError.cursorExpired|case 410: throw TransportError.fatal(\"HTTP 410\")|HTTP 410 means cursor expired, not fatal"
  "$S/Transport.swift|case 408, 429, 500...599: throw|case 500...599: throw|429 is retryable"
  "$S/TransportContract.swift|if mid.events.map(\\.sequence) != [3, 4] {|if false {|the contract checks cursor semantics (meta: the suite itself is tested)"
  "$S/Saturating.swift|return overflow ? .max : result|return result|sequence arithmetic saturates instead of trapping"
  "$S/EventSequencer.swift|inherited = min(current.sequence, fork, page.highWater)|inherited = min(current.sequence, fork)|a fork point above the new high-water mark cannot wedge the cursor"
  "$S/Transport.swift|let guarded = ResidencyEnforcingClient(inner: network, configuration: config, audit: audit)|let guarded = network|every adapter the factory builds sits behind the residency guard"
)
# A mutant that makes a test hang counts as caught, not as a stuck job.
# macOS has no `timeout`; perl's alarm is a portable fallback.
if command -v timeout >/dev/null; then LIMIT="timeout 600"; else LIMIT="perl -e alarm(600);exec(@ARGV)"; fi
if ! swift build --build-tests -q >/dev/null 2>&1 || ! $LIMIT swift test --skip-build >/dev/null 2>&1; then
  echo "BASELINE FAILED: the unmutated suite must pass before mutants mean anything"; exit 2
fi
echo "baseline: unmutated suite passes"
survived=0; caught=0
# Originals are kept outside Sources/ (SwiftPM would warn about stray files) and restored on any exit.
BACKUP=$(mktemp -d); CURRENT=""
trap '[ -n "$CURRENT" ] && cp "$BACKUP/orig" "$CURRENT"; rm -rf "$BACKUP"' EXIT
for entry in "${MUTANTS[@]}"; do
  IFS='|' read -r file from to claim <<< "$(printf '%s' "$entry" | sed 's/\\|/\x02/g' | tr '\n' '\001')"
  file=${file//$'\001'/$'\n'}; from=${from//$'\001'/$'\n'}; to=${to//$'\001'/$'\n'}; claim=${claim//$'\001'/$'\n'}
  from=${from//$'\002'/|}; to=${to//$'\002'/|}
  cp "$file" "$BACKUP/orig"; CURRENT="$file"
  count=$(FROM="$from" perl -0777 -ne '$f=$ENV{FROM}; $c = () = /\Q$f\E/g; print $c' "$file")
  if [ "$count" != "1" ]; then echo "SETUP ERROR: pattern occurs $count times in $file: $claim"; CURRENT=""; exit 2; fi
  FROM="$from" TO="$to" perl -0777 -pi -e 'BEGIN { $f = $ENV{FROM}; $t = $ENV{TO} } s/\Q$f\E/$t/' "$file"
  if ! swift build --build-tests -q >/dev/null 2>&1; then
    # A mutant that doesn't compile proves nothing about the tests.
    echo "SETUP ERROR: mutant does not compile: $claim"; cp "$BACKUP/orig" "$file"; CURRENT=""; exit 2
  fi
  if $LIMIT swift test --skip-build >/dev/null 2>&1; then
    echo "SURVIVED: $claim"; survived=$((survived+1))
  else
    echo "caught:   $claim"; caught=$((caught+1))
  fi
  cp "$BACKUP/orig" "$file"; CURRENT=""
done
echo "mutants caught: $caught/$((caught+survived))"
[ "$survived" -eq 0 ]
