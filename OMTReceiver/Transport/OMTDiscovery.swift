import Combine
import Foundation
@preconcurrency import Network

struct OMTSource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let endpoint: NWEndpoint

    /// Accepts omt://host:port, including bracketed IPv6, or host:port.
    /// There is no assumed default port: each sender advertises its own port.
    static func manual(address: String) throws -> OMTSource {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = value.contains("://") ? value : "omt://\(value)"
        guard !value.isEmpty, !value.contains(where: \.isWhitespace),
              let components = URLComponents(string: url), components.scheme?.lowercased() == "omt",
              var host = components.host, !host.isEmpty,
              let portNumber = components.port, (1...65_535).contains(portNumber),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber)) else {
            throw OMTAddressError.invalidAddress
        }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let displayHost = host.contains(":") ? "[\(host)]" : host
        return OMTSource(id: "manual:\(host.lowercased()):\(portNumber)", name: "\(displayHost):\(portNumber)",
                         endpoint: .hostPort(host: .init(host), port: port))
    }
}

enum OMTAddressError: LocalizedError {
    case invalidAddress
    var errorDescription: String? { "Enter an OMT address such as omt://192.168.1.20:6400." }
}

/// Stores source identities only. Discovery and favourites never open a media
/// connection, and a selected manual/temporarily undiscovered source stays visible.
@MainActor
final class ReceiverSourcePreferences: ObservableObject {
    private let defaults: UserDefaults
    private let key = "favouriteSourceIDs"
    @Published private(set) var favourites: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favourites = Set((defaults.stringArray(forKey: key) ?? []).prefix(128))
    }

    func toggleFavourite(_ source: OMTSource) {
        if favourites.contains(source.id) { favourites.remove(source.id) }
        else if favourites.count < 128 { favourites.insert(source.id) }
        defaults.set(favourites.sorted(), forKey: key)
    }

    func orderedSources(_ discovered: [OMTSource], selected: OMTSource?) -> [OMTSource] {
        var unique = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let selected, unique[selected.id] == nil { unique[selected.id] = selected }
        return unique.values.sorted { lhs, rhs in
            let leftFavourite = favourites.contains(lhs.id), rightFavourite = favourites.contains(rhs.id)
            if leftFavourite != rightFavourite { return leftFavourite }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}

/// Discovery is local to its browser/session owner. It never connects to or
/// selects a source merely because an advertisement arrives.
@MainActor
final class OMTDiscovery: ObservableObject {
    @Published private(set) var sources: [OMTSource] = []
    @Published private(set) var stateMessage: String?
    private var browser: NWBrowser?
    private var generation = UUID()

    func start() {
        guard browser == nil else { return }
        generation = UUID()
        let token = generation
        stateMessage = "Looking for OMT sources on the local network…"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_omt._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.browser != nil else { return }
                switch state {
                case .ready:
                    self.stateMessage = self.sources.isEmpty ? "No OMT sources found yet. A manual address is also available." : nil
                case .failed(let error), .waiting(let error):
                    self.stateMessage = "OMT discovery unavailable: \(error.localizedDescription)"
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // A service may appear on several interfaces. An unpinned service
            // endpoint lets Network.framework select a reachable interface.
            var found: [String: OMTSource] = [:]
            for result in results {
                guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
                let id = "bonjour:\(name).\(type).\(domain)".lowercased()
                found[id] = .init(id: id, name: name, endpoint: .service(name: name, type: type, domain: domain, interface: nil))
            }
            let sources = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.browser != nil else { return }
                self.sources = sources
                self.stateMessage = sources.isEmpty ? "No OMT sources found yet. A manual address is also available." : nil
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        generation = UUID()
        browser?.cancel()
        browser = nil
        sources = []
        stateMessage = nil
    }

    deinit { browser?.cancel() }
}
