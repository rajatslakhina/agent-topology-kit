# AgentTopology

**One iOS agent feature, two deployment topologies.** A Swift package for B2B apps whose customers run an agent service either on Anthropic's hosted platform or *self-hosted inside their own perimeter*, each on its own release schedule. The app talks to a fleet of servers it does not operate, all on different versions, and has to behave correctly against every one of them.

**Demo app:** [agent-topology-demo-app](https://github.com/rajatslakhina/agent-topology-demo-app). A SwiftUI app with five tenants that consumes this package as a remote dependency (`from: "1.0.0"`), with screenshots from a Simulator run.

---

## Why this matters

In November 2026 Anthropic announced a private beta of self-hosted Claude Managed Agents ([announcement](https://claude.com/resources/articles/self-hosted-claude-managed-agents), [docs](https://platform.claude.com/docs/en/managed-agents/self-hosted)). Per those pages, the customer operates the service and its storage inside its own perimeter, the API matches the hosted one, some hosted features are not available, and each customer installs releases on its own schedule.

This package does not call that product. The server versions (1.8 to 2.4), feature names, which features are "hosted-only", and the wire format are **illustrative**. They model the *shape* of the problem so the client architecture can be built and tested against it.

For a mobile team that turns three easy assumptions into bugs:

| Easy assumption | What goes wrong in the field |
|---|---|
| "Check the server version to enable a feature" | A self-hosted 2.3 build can lack a hosted-only feature. Version-gating turns it on and the screen fails. |
| "Resume the event stream from the last sequence number" | A customer restores its database from last night's backup. Sequence numbers restart from the restore point; the client resumes "from #9" in a history that has a different #5–#9, and shows events that never happened in this lineage. |
| "The endpoint comes from config, so traffic goes where the customer wants" | One wrong allowlist entry or redirect and a self-hosted tenant's session content goes to an origin the customer never approved. |

AgentTopology is the client-side architecture that removes those assumptions, as runnable, tested code.

## Design at a glance

```
 MDM payload ──► ManagedConfigParser ──► TenantConfiguration (validated, residency rules applied)
                                              │
                                              ▼
                         TransportFactory  (the only place that looks at topology)
                         ├─ HostedTransport ─┐
                         └─ SelfHostedTransport ─┤── ResidencyEnforcingClient ──► HTTPClient (URLSession / simulated)
                                              │
            ManagedAgentsTransport (port) ◄───┘   ← both adapters must pass TransportContract
                 │                    │
     TenantConnector.connect     SessionEventSync (actor: retry, backoff, reentrancy rules)
                 │                    │
     CapabilityNegotiator        EventSequencer (pure value: exactly-once, no holes, lineage-safe)
                 │                    │
           CapabilityPlan ─────► AgentTopologyUI: CapabilityGate, FleetDashboardView
```

Two modules: `AgentTopology` (Foundation only, builds and tests on Linux) and `AgentTopologyUI` (SwiftUI, compiles to nothing where SwiftUI is absent).

## Design decisions and trade-offs

### 1. A transport port with two adapters, verified by an executable contract
`ManagedAgentsTransport` is the only thing screens and sync code depend on. `HostedTransport` and `SelfHostedTransport` differ in origin, gateway path prefix and routing headers. They share the status-code mapping on purpose, because if the two topologies classified a 429 differently the retry loop would behave differently per customer.

`TransportContract.verify` is a suite of five clauses (descriptor fidelity, cursor semantics, lineage passthrough, error classification, unsafe input refused before any I/O). It **returns** violations instead of asserting, so the suite is itself tested: the package runs it against both real adapters (no violations) and against deliberately broken adapters and servers (off-by-one cursor, ignored page limit, retry-everything error mapping, no input validation, misreported topology, a server that omits lineage), and each broken one must trip the right clause.

*Rejected:* `if tenant.isSelfHosted` branches in feature code (they multiply with every new topology and are untestable as a whole); one adapter with a mode flag (every change risks the other topology, and there is no seam to test them against a common contract).

*Honest scope:* the wire format (routes, JSON field names) is an **illustrative stand-in**, not the real Managed Agents API. It lives in one file (`Transport.swift`, `enum Wire`). The contract runs against an in-process `SimulatedAgentServer`. Pointing the same entry point at a real local deployment is the intended next step, and it is not shipped here.

### 2. Capabilities need the advertisement *and* the version
`CapabilityNegotiator` turns a `ServerDescriptor` into a `CapabilityPlan` of `available` / `degraded(reason)` / `unavailable(reason)` per feature. A feature is available only if the server is at or above the client's minimum version for it **and** the server advertises it. Either alone is wrong: version-only gating breaks on self-hosted builds without hosted-only features, and advertisement-only gating breaks when a server advertises a flag before the wire shape the client was written for existed.

A `SupportWindow` bounds the server lines this build was tested against. Below the minimum, the tenant is `unsupported` and everything is off. On a newer `major.minor` line (including prereleases from a preview ring), only features marked *skew-sensitive* are held back. Everything else stays on, so one customer upgrading early does not blank the app. Patch releases inside the tested line count as compatible.

Missing features **degrade** where a fallback exists: no event cursor means full-history polling with client-side de-duplication, and no tool confirmation means approvals go through the tenant's console. `CapabilityGate` renders the plan (content, banner or explanation), so screens never ask which topology they are on.

*Rejected:* version-only gating (wrong for self-hosted builds without hosted-only features); a server-issued capability token that the client trusts blindly. A token would work for one server, but the client still needs its own floor per feature, because the token says what the server can do, not what this client build can speak.

*Trade-off:* a stale descriptor can over-promise until the next connect. The demo re-negotiates after an upgrade; a production app should also re-negotiate on foreground and after any `fatal` it cannot classify.

### 3. Resumption is keyed by lineage, not by sequence number
Every page carries an `epoch`: the identity of the server's history. A process restart keeps it, because history lives in the database. A restore from backup starts a new one and reports `previousEpoch` and `forkPoint`, the last sequence inherited unchanged. `EventSequencer` is a pure value type with three guarantees for everything it reports as applied:

1. **Exactly once** within an epoch: sequences at or below the cursor are dropped as duplicates.
2. **In order, no holes**: a page that does not continue at `cursor + 1` is rejected whole, and the cursor does not move.
3. **Lineage-safe**: a page from another epoch never applies on top of the old cursor. If the new epoch names ours as its predecessor, events up to `min(cursor, forkPoint)` survive and everything after is retracted. If it does not (two restores while the device was offline, or a server that omits lineage), **nothing** survives and the client refetches from zero.

History that shrinks *without* a new epoch is reported as `malformed`, never silently accepted.

*Rejected:*
- **Content-hash resume** (the client sends hashes of what it holds). It costs O(history) per resume and needs a hash scheme both sides agree on.
- **Opaque server snapshot tokens.** They hide the fork point, so the client cannot retract precisely and cannot tell a restart from a restore.

Epoch plus fork point is two small fields and makes both cases explicit. The fork point is also clamped to the new history's high-water mark, so an inconsistent server cannot park the cursor above its own history.

*Trade-off:* the conservative path refetches more than strictly necessary after an unknown-lineage change. That is deliberate. Re-downloading a session is cheap; showing an agent's tool call that never happened in the customer's system of record is not.

### 4. Retries that do not stampede a customer's server
`SessionEventSync` (an actor) retries transient failures (408, 429, 5xx, a server mid-restart) with **capped exponential backoff and full jitter**. When a self-hosted server restarts, every device of that tenant disconnects at the same instant, and full jitter spreads their reconnects. A hole in a page counts as transient, a `410` means the cursor expired and forces a full resync, and anything else is fatal and not retried.

Actor reentrancy is handled explicitly. Every `await` lets other calls in, so:
- one pump per *generation*: a concurrent `pump()` returns `.busy` instead of fetching twice;
- `reset()` bumps the generation, and a pump suspended across a reset re-checks after every `await` and **discards** its page (`.discardedStale`), so a page fetched before a reset never lands after it.

*Rejected:*
- **Equal jitter** (half fixed, half random). It keeps a floor that re-synchronises clients after a fleet-wide disconnect.
- **Decorrelated jitter.** It is good for long-lived single clients, but harder to bound and to test deterministically.
- **Server `Retry-After` alone.** A server mid-restart may not be up to send it.

*Trade-off:* full jitter can retry almost immediately, so a few devices hit a still-restarting server early. With a 5-attempt budget that is acceptable. A production client should also honour `Retry-After` when present (not implemented here). If the `HTTPClient` throws `CancellationError`, the pump reports `exhausted("cancelled")` rather than a server fault. A `URLSession`-backed client must map `URLError(.cancelled)` to `CancellationError` for that to hold; this path is not unit-tested here.

### 5. Residency is enforced at the network seam, not in configuration review
`ManagedConfigParser` parses the MDM payload once ("parse, don't validate"). It requires `https` (plain HTTP only for loopback with explicit opt-in), rejects credentials, queries and paths in the base URL, and requires the base host to be in the allowlist. It also rejects a **self-hosted tenant whose allowlist names the hosted API host**, because the whole point of self-hosting is that the device never sends that tenant's session content anywhere else.

`ResidencyEnforcingClient` decorates the network: an **exact**, lower-cased host match on every request (no suffix or wildcard matching, so a look-alike such as `evil-agents.acme.example` fails even though it ends in the allowed name), with refusals recorded in a bounded `ResidencyAudit`. A refused request never reaches the inner client. A **hosted** tenant may list only the hosted origin, so a payload cannot quietly widen it either. *Limitations:*
- The match is on host, not host and port.
- The guard sees the request it is given, so a production `URLSession` client must also refuse cross-host redirects.

*Rejected:* validating hosts only at configuration time. It would not stop a later feature (an analytics or crash upload) from sending session content somewhere else; the demo's "Off-tenant upload attempt" scenario shows the guard refusing exactly that.

The device never holds an organization API key. `CredentialProvider` supplies a short-lived bearer token minted by the customer's backend or identity provider.

### Crash-safety
The library has exactly one force-unwrap, on a compile-time URL literal (`TenantConfiguration.hostedBaseURL`), with a comment. In the core module, all arithmetic that can see server or config input goes through `Saturating`: sequence `+1` at `UInt64.max`, backoff doubling at `Int.max`, and counters. Retry attempts are clamped to `1...20` and page limits to `1...500`. A hostile `RandomSource` cannot push jitter outside `0...ceiling`. The audit log, simulated history and UI transcript are all bounded.

## Testing

`Tests/AgentTopologyTests` has **63 XCTest cases** for the core module. They cover:
- version parsing (SemVer prerelease and build metadata, overflow, non-ASCII digits) and config parsing;
- the negotiation rules;
- sequencer edge cases: gaps, duplicates, sequence 0, history shrinking, chained restores, `UInt64.max`;
- retry and backoff;
- the reentrancy cases: reset while a fetch is suspended, a concurrent pump, and a new generation pumping while a stale one is still suspended;
- residency, including a request the network *could* route that the guard refuses, with a no-guard control;
- the contract suite and its meta-tests;
- an end-to-end run through the composition root across a restart and a restore, plus a legacy-server run in degraded polling mode.

`AgentTopologyUI` has no unit tests. It is exercised only by the demo app's Simulator runs.

Tests that guard against *vacuous* coverage:
- **Property check with a broken twin.** 50 seeded runs of random overlapping, re-delivered pages must yield exactly `1…40` once and in order. The same check run against a sequencer that does not drop duplicates must fail.
- **Contract meta-tests.** Six deliberately broken adapters or servers, each of which must trip its clause.
- **Mutation check** (`scripts/mutation-check.sh`, run in CI). 28 mutants each re-introduce one bug this README claims is prevented: version-only gating, no dedup, `>=` instead of `==` for gaps, ignoring lineage, suffix host matching, a 410 classified as fatal, removing the post-`await` generation re-check, and more. Every mutant must make a test fail; a mutant that survives fails the job.

## How to run it

```bash
git clone https://github.com/rajatslakhina/agent-topology-kit.git
cd agent-topology-kit
swift test                      # macOS or Linux
bash scripts/mutation-check.sh  # optional: every mutant must be caught
```

Add it to an app:

```swift
.package(url: "https://github.com/rajatslakhina/agent-topology-kit.git", from: "1.0.0")
// products: "AgentTopology" (core), "AgentTopologyUI" (SwiftUI)
```

```swift
let config = try ManagedConfigParser.parse(mdmPayload).get()
let transport = TransportFactory.make(for: config, network: myURLSessionClient,
                                      credentials: myTokenProvider, audit: ResidencyAudit())
let report = try await TenantConnector.connect(transport)          // descriptor + CapabilityPlan
let sync = SessionEventSync(transport: transport, session: sessionID,
                            usesCursor: report.plan.state(of: .eventCursor) == .available)
switch await sync.pump() { /* applied / rebased(retractAfter:) / resyncRequired / exhausted / … */ }
```

## Verification

What was actually run, and what it showed:

- **CI** ([Actions](https://github.com/rajatslakhina/agent-topology-kit/actions)), on every push and tag:
  - *Linux:* `swift:6.0` container, clean `swift build --build-tests -Xswiftc -warnings-as-errors`, then `swift test`.
  - *macOS (`macos-15`, Xcode 16.4 on the first run):* `swift test -Xswiftc -warnings-as-errors`, then `xcodebuild build` of both products for `generic/platform=iOS Simulator`, with warnings treated as errors.
  - *Mutation:* `scripts/mutation-check.sh` in `swift:6.0`. The first run on `main` passed all three jobs: 63 tests, and 28/28 mutants caught.
- **Locally:**
  - *macOS (Xcode 27.2, Swift 6.4.2):* clean `swift build --build-tests -Xswiftc -warnings-as-errors` with 0 warnings, then 63/63 tests.
  - *Linux (Docker `swift:6.0`, Swift 6.0.3):* the same build, 63/63 tests, and 28/28 mutants caught.
- **Simulator:** the companion demo app was built against this package resolved from GitHub at `1.0.0`, with 0 Swift warnings. It was installed on an iOS 27.2 Simulator (iPhone 18 Pro) and launched six times with launch arguments through `xcrun simctl launch`, with no taps. Each process was confirmed running about 12 s after launch. Its screenshots come from that run.
- **Not verified:**
  - `AgentTopologyUI` has no unit tests.
  - No interactive taps were made.
  - The adapters have never talked to a real hosted or self-hosted deployment, since the wire format is illustrative.

## License

MIT
