#if canImport(SwiftUI)
import SwiftUI
import AgentTopology

/// Renders `content` only when the negotiated plan allows `feature`, a banner when it is degraded, and a
/// one-line explanation when it is unavailable. Screens use this instead of `if tenant.isSelfHosted`,
/// so a new deployment shape needs no UI change, only a different plan.
public struct CapabilityGate<Content: View>: View {
    let feature: Feature
    let plan: CapabilityPlan?
    let content: (FeatureState) -> Content

    public init(_ feature: Feature, plan: CapabilityPlan?, @ViewBuilder content: @escaping (FeatureState) -> Content) {
        self.feature = feature
        self.plan = plan
        self.content = content
    }

    public var body: some View {
        let state = plan?.state(of: feature) ?? .unavailable("not connected")
        switch state {
        case .available:
            content(state)
        case .degraded(let why):
            VStack(alignment: .leading, spacing: 6) {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
                content(state)
            }
        case .unavailable(let why):
            Label("\(feature.title) is off for this tenant: \(why)", systemImage: "nosign")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

public struct FleetDashboardView: View {
    @Bindable var model: FleetModel

    public init(model: FleetModel) { self.model = model }

    public var body: some View {
        NavigationStack(path: $model.path) {
            List {
                Section {
                    ForEach(model.tenants) { tenant in
                        NavigationLink(value: tenant.id) { TenantRow(tenant: tenant) }
                    }
                } header: {
                    Text("Tenants")
                } footer: {
                    Text("Each tenant is provisioned by managed app configuration. Hosted and self-hosted deployments go through one transport port; screens read only the negotiated capability plan.")
                }
                Section("Residency guard") {
                    LabeledContent("Requests refused", value: "\(model.refusedRequests)")
                    Text("Every request is checked against its tenant's exact host allowlist before it leaves the device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Agent Fleet")
            .navigationDestination(for: String.self) { id in
                if let tenant = model.tenant(id: id) {
                    TenantDetailView(tenant: tenant, focus: model.launchFocus, onChange: { Task { await model.refreshAudit() } })
                }
            }
            .overlay { if !model.isReady { ProgressView("Discovering servers…") } }
        }
        .task { await model.bootstrap() }
    }
}

struct TenantRow: View {
    let tenant: TenantModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tenant.name).font(.headline)
                Spacer()
                TopologyBadge(configuration: tenant.configuration)
            }
            switch tenant.configuration {
            case .failure(let error):
                Label("Rejected: \(error.description)", systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            case .success:
                if let report = tenant.report {
                    let c = report.plan.counts
                    HStack(spacing: 10) {
                        Text(verbatim: "v\(report.descriptor.version)").font(.caption.monospaced())
                        CompatibilityLabel(compatibility: report.plan.compatibility)
                        Spacer()
                        Text("\(c.available)✓ \(c.degraded)◐ \(c.unavailable)✕").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } else if let error = tenant.connectionError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    Text("connecting…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct TopologyBadge: View {
    let configuration: Result<TenantConfiguration, ConfigurationError>

    var body: some View {
        let text: String, color: Color
        switch configuration {
        case .success(let c) where c.topology == .hosted: (text, color) = ("HOSTED", .blue)
        case .success: (text, color) = ("SELF-HOSTED", .purple)
        case .failure: (text, color) = ("INVALID", .red)
        }
        return Text(text).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

struct CompatibilityLabel: View {
    let compatibility: Compatibility

    var body: some View {
        switch compatibility {
        case .compatible: Label("compatible", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
        case .newerThanTested: Label("newer than tested", systemImage: "questionmark.diamond").font(.caption).foregroundStyle(.orange)
        case .unsupported: Label("unsupported", systemImage: "xmark.seal").font(.caption).foregroundStyle(.red)
        }
    }
}

struct FeatureRow: View {
    let feature: Feature
    let state: FeatureState

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            switch state {
            case .available: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .degraded: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange)
            case .unavailable: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                switch state {
                case .available: EmptyView()
                case .degraded(let why), .unavailable(let why):
                    Text(why).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct TenantDetailView: View {
    let tenant: TenantModel
    let focus: String?
    let onChange: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            content
                .task(id: tenant.revision) {
                    guard let focus else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation { proxy.scrollTo(focus, anchor: .top) }
                }
        }
    }

    private var content: some View {
        List {
            deployment
            if let plan = tenant.plan {
                Section("Negotiated capabilities") {
                    ForEach(Feature.allCases, id: \.self) { FeatureRow(feature: $0, state: plan.state(of: $0)) }
                }
                .id("capabilities")
                Section("Pending tool call") {
                    Text("tickets.create(title: \"Linker error after package bump\")").font(.callout.monospaced())
                    CapabilityGate(.toolConfirmation, plan: plan) { state in
                        if let decision = tenant.approvalDecision {
                            Text("Decision sent: \(decision)").foregroundStyle(.secondary)
                        } else if state == .available {
                            HStack {
                                Button("Approve") { tenant.approve("approved") }.buttonStyle(.borderedProminent)
                                Button("Deny", role: .destructive) { tenant.approve("denied") }.buttonStyle(.bordered)
                            }
                        } else {
                            Button("Open tenant console") {}.disabled(true)
                        }
                    }
                }
                CapabilityGate(.memoryStores, plan: plan) { _ in
                    Label("Agent memory: 3 stores attached", systemImage: "brain")
                }
                session
            }
            Section("Event log") {
                if tenant.log.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
                ForEach(Array(tenant.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
            .id("log")
        }
        .navigationTitle(tenant.name)
        .toolbar {
            if tenant.plan != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Simulate") {
                        ForEach(Scenario.allCases.filter { $0 != .upgrade || (tenant.report?.descriptor.version ?? ServerVersion(9, 0, 0)) < ServerVersion(2, 2, 0) }, id: \.self) { s in
                            Button(s.title) { Task { await tenant.run(s); onChange() } }
                        }
                    }
                    .disabled(tenant.isBusy)
                }
            }
        }
    }

    @ViewBuilder private var deployment: some View {
        Section("Deployment") {
            switch tenant.configuration {
            case .failure(let error):
                Label("Configuration rejected — not connecting", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(error.description).font(.callout)
            case .success(let c):
                LabeledContent("Topology", value: c.topology == .hosted ? "Hosted" : "Self-hosted")
                LabeledContent("Endpoint", value: (c.baseURL.host ?? "?") + c.pathPrefix)
                LabeledContent("Allowed hosts", value: c.allowedHosts.sorted().joined(separator: ", "))
                if let region = c.region { LabeledContent("Region", value: region) }
                if let r = tenant.report {
                    LabeledContent("Server", value: "v\(r.descriptor.version)")
                    HStack {
                        Text("Compatibility")
                        Spacer()
                        CompatibilityLabel(compatibility: r.plan.compatibility)
                    }
                }
                if let e = tenant.connectionError {
                    Text(e).foregroundStyle(.red)
                    Button("Reconnect") { Task { await tenant.reconnect(); onChange() } }
                        .disabled(tenant.isBusy)
                }
            }
        }
    }

    @ViewBuilder private var session: some View {
        Section {
            ForEach(tenant.transcript.suffix(12)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("#\(line.event.sequence)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(line.event.text).font(.callout)
                        .foregroundStyle(line.event.kind == .toolUse || line.event.kind == .toolResult ? .purple : .primary)
                }
            }
            Button {
                Task { await tenant.syncNow(); onChange() }
            } label: {
                Label(tenant.isBusy ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(tenant.isBusy)
        } header: {
            Text("Session s-1")
        } footer: {
            let cursor = tenant.cursor.map { "cursor \($0.epoch)#\($0.sequence)" } ?? "no cursor"
            Text("\(cursor) · \(tenant.transcript.count) shown · \(tenant.retractedTotal) retracted")
        }
        .id("session")
    }
}
#endif
