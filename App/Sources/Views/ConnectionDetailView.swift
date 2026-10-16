import SwiftUI

/// A connection's detail page, opened from Connections: where the flow went,
/// which rule sent it there, and what this device knows about the far end
/// (`ConnectionDetailModel`). Closing the connection lives in the toolbar
/// menu.
struct ConnectionDetailView: View {
    static let placeholder = "—"

    @Environment(\.locale) private var locale
    @State private var model: ConnectionDetailModel

    init(model: ConnectionDetailModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Ticks the duration while the connection is open.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    section(overview(now: context.date))
                }
                section(routing)
                if !addresses.isEmpty {
                    section(addresses)
                }
                section(flow)
            }
            .padding(16)
        }
        .background(AppTheme.screenBackground)
        .navigationTitle("connectionDetail.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.active {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            Task { await model.close() }
                        } label: {
                            Label("connectionDetail.close", systemImage: "xmark.circle")
                        }
                        .accessibilityIdentifier("connectionDetail.close")
                    } label: {
                        Label("connectionDetail.more", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("connectionDetail.menu")
                }
            }
        }
        .task { await model.run() }
    }

    private var connection: Connection {
        model.connection
    }

    private func overview(now: Date) -> [Field] {
        let meta = connection.metadata
        let host = meta.flatMap { $0.host.isEmpty ? $0.destinationIP : $0.host } ?? ""
        let port = meta?.destinationPort ?? ""
        var fields = [
            Field(
                id: "host",
                label: "connectionDetail.host",
                value: host.isEmpty || port.isEmpty ? host : "\(host):\(port)",
            ),
            Field(
                id: "date",
                label: "connectionDetail.date",
                value: model.started?.formatted(date: .abbreviated, time: .standard),
            ),
        ]
        if let lastSeen = model.lastSeen {
            let time = lastSeen.formatted(date: .omitted, time: .standard)
            fields.append(Field(
                id: "status",
                label: "connectionDetail.status",
                value: String(localized: "connectionDetail.closed"),
                detail: String(localized: "connectionDetail.lastSeen \(time)"),
            ))
        } else {
            fields.append(Field(
                id: "status",
                label: "connectionDetail.status",
                value: String(localized: "connectionDetail.active"),
                tint: AppTheme.connected,
            ))
        }
        fields.append(Field(
            id: "duration",
            label: "connectionDetail.duration",
            value: model.started.map { duration(from: $0, to: model.lastSeen ?? now) },
        ))
        return fields
    }

    private var routing: [Field] {
        let chain = connection.chains.reversed().joined(separator: " › ")
        return [
            Field(id: "policy", label: "connectionDetail.policy", value: chain),
            Field(
                id: "rule",
                label: "connectionDetail.rule",
                value: ruleText,
                detail: model.ruleIndex.map { String(localized: "connectionDetail.ruleNumber \($0 + 1)") },
                ruleIndex: model.ruleIndex,
            ),
        ]
    }

    private var ruleText: String {
        if let route = UnlistedRoute(connection) {
            return String(localized: route.label)
        }
        return [connection.rule, connection.rulePayload].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var addresses: [Field] {
        var fields: [Field] = []
        // On iOS every flow reaches the engine through its local listener,
        // so a loopback source says nothing about the device.
        if let local = connection.metadata?.sourceIP, !local.isEmpty, !Self.isLoopback(local) {
            fields.append(Field(id: "localIP", label: "connectionDetail.localIP", value: local))
        }
        switch model.remote {
        case let .known(ip, fromDNSCache, geo):
            fields.append(Field(
                id: "remoteIP",
                label: "connectionDetail.remoteIP",
                value: ip,
                detail: fromDNSCache ? String(localized: "connectionDetail.remoteIP.dnsCache") : nil,
            ))
            if let geo {
                fields += geoFields(geo)
            }
        case .resolvedByProxy:
            fields.append(Field(
                id: "remoteIP",
                label: "connectionDetail.remoteIP",
                value: String(localized: "connectionDetail.remoteIP.byProxy"),
            ))
        case nil:
            break
        }
        return fields
    }

    private func geoFields(_ geo: IPGeo) -> [Field] {
        var fields: [Field] = []
        let region: String? = geo.isPrivate
            ? String(localized: "connectionDetail.region.private")
            : geo.regionLabel(locale: locale)
        if let region {
            fields.append(Field(id: "remoteRegion", label: "connectionDetail.remoteRegion", value: region))
        }
        if let asn = geo.asn {
            fields.append(Field(id: "remoteASN", label: "connectionDetail.remoteASN", value: "AS\(asn)"))
        }
        if let org = geo.org {
            fields.append(Field(id: "remoteOrg", label: "connectionDetail.remoteOrg", value: org))
        }
        return fields
    }

    private var flow: [Field] {
        let meta = connection.metadata
        var fields = [
            Field(id: "network", label: "connectionDetail.network", value: meta?.network.uppercased()),
        ]
        if let sniffed = meta?.sniffHost, !sniffed.isEmpty, sniffed != meta?.host {
            fields.append(Field(id: "sniffHost", label: "connectionDetail.sniffHost", value: sniffed))
        }
        if let mode = meta?.dnsMode, !mode.isEmpty {
            // `mapping` is what configs call redir-host.
            let value = mode == "mapping" ? "redir-host" : mode
            fields.append(Field(id: "dnsMode", label: "connectionDetail.dnsMode", value: value))
        }
        fields += [
            Field(
                id: "upload",
                label: "home.traffic.upload",
                value: ByteCountFormatter.string(fromByteCount: connection.upload, countStyle: .binary),
            ),
            Field(
                id: "download",
                label: "home.traffic.download",
                value: ByteCountFormatter.string(fromByteCount: connection.download, countStyle: .binary),
            ),
        ]
        return fields
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start).rounded(.down))
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow).locale(locale),
        )
    }

    private static func isLoopback(_ ip: String) -> Bool {
        ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("::ffff:127.")
    }

    private func section(_ fields: [Field]) -> some View {
        GlassCard {
            VStack(spacing: 0) {
                ForEach(fields) { field in
                    if field.id != fields.first?.id {
                        Divider()
                    }
                    if let index = field.ruleIndex {
                        // The rule's place in the list: Rules opens on it.
                        NavigationLink {
                            RulesView(focusIndex: index)
                        } label: {
                            HStack(spacing: 8) {
                                FieldRow(field: field)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("connectionDetail.\(field.id)")
                    } else {
                        FieldRow(field: field)
                            .accessibilityIdentifier("connectionDetail.\(field.id)")
                    }
                }
            }
        }
    }
}

/// One labelled value on the page.
private struct Field: Identifiable {
    let id: String
    let label: LocalizedStringKey
    /// Nil or empty shows the placeholder.
    let value: String?
    var detail: String?
    var tint: Color = AppTheme.mutedText
    /// The matched rule's index, which makes the row open Rules on it.
    var ruleIndex: Int?
}

private struct FieldRow: View {
    let field: Field

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(field.label)
                .font(.subheadline)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(field.value.flatMap { $0.isEmpty ? nil : $0 } ?? ConnectionDetailView.placeholder)
                    .font(.subheadline)
                    .foregroundStyle(field.tint)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                if let detail = field.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

extension UnlistedRoute {
    var label: LocalizedStringResource {
        switch self {
        case .final: "connectionDetail.rule.final"
        case .global: "connectionDetail.rule.global"
        case .direct: "connectionDetail.rule.direct"
        }
    }
}
