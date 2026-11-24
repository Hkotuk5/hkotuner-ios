import CryptoKit
import Foundation
import Network

/// An explicit route hint from the PC. Accept only private or IPv4 link-local addresses.
struct DesktopAddress: Equatable {
    let host: String
    let port: UInt16

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let numbers = octets.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return UInt8(part)
        }
        guard numbers.count == 4, octets.count == 4 else { return nil }
        let first = numbers[0], second = numbers[1]
        guard first == 10 || (first == 172 && (16...31).contains(second)) ||
                (first == 192 && second == 168) || (first == 169 && second == 254) else { return nil }
        if parts.count == 2 {
            guard let number = UInt16(parts[1]), number > 0 else { return nil }
            port = number
        } else {
            port = 48627
        }
        host = numbers.map(String.init).joined(separator: ".")
    }

    var text: String { "\(host):\(port)" }

    var endpoint: NWEndpoint? {
        guard let address = IPv4Address(host), let port = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: .ipv4(address), port: port)
    }
}

/// A length-prefixed, authenticated exchange over Bonjour. The desktop sends a fresh challenge
/// and both messages authenticate that challenge and their direction.
final class LanConnection: @unchecked Sendable {
    private static let limit = 24 * 1024 * 1024
    private let queue = DispatchQueue(label: "uk.hkot.hkotuner.lan")
    private let secret: SymmetricKey
    private let label: String
    private let address: DesktopAddress?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeout: DispatchWorkItem?
    private var directTimeout: DispatchWorkItem?
    private var cancelled = false

    init(key: Data, address: DesktopAddress? = nil) {
        self.address = address
        secret = SymmetricKey(data: key)
        label = Self.serviceLabel(key)
    }

    static func serviceLabel(_ key: Data) -> String {
        "hkotuner-" + SHA256.hash(data: key).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    func send(_ payload: Data) async throws -> Data {
        guard payload.count <= Self.limit - 28 else { throw HKError("Библиотека слишком велика для одной синхронизации") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    self.continuation = continuation
                    if cancelled { finish(.failure(CancellationError())) }
                    else { begin(payload) }
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func begin(_ payload: Data) {
        let timeLimit = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
                self.finish(.failure(Self.permissionError))
            } else {
                self.finish(.failure(HKError("ПК не ответил. Проверь, что iPhone и ПК в одной сети, а hkotuner на ПК открыт.")))
            }
        }
        timeout = timeLimit
        queue.asyncAfter(deadline: .now() + 18, execute: timeLimit)
        if let endpoint = address?.endpoint {
            let tryDiscovery = DispatchWorkItem { [weak self] in self?.fallBackToBonjour(payload) }
            directTimeout = tryDiscovery
            queue.asyncAfter(deadline: .now() + 4, execute: tryDiscovery)
            connect(endpoint, payload: payload, direct: true)
        } else {
            browse(payload)
        }
    }

    private static var permissionError: HKError {
        HKError("Разреши hkotuner доступ в Настройки iPhone → Конфиденциальность и безопасность → Локальная сеть.")
    }

    private func fallBackToBonjour(_ payload: Data) {
        guard continuation != nil else { return }
        directTimeout?.cancel()
        directTimeout = nil
        connection?.cancel()
        connection = nil
        browse(payload)
    }

    private func browse(_ payload: Data) {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let browser = NWBrowser(for: .bonjour(type: "_hkotuner-sync._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(.dns(-65570)), .failed(.dns(-65570)): // kDNSServiceErr_PolicyDenied
                self?.finish(.failure(Self.permissionError))
            case .failed(let error):
                self?.finish(.failure(Self.connectionError(error)))
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, connection == nil,
                  let service = results.first(where: {
                      if case .service(let name, _, _, _) = $0.endpoint { return name == self.label }
                      return false
                  }) else { return }
            connect(service.endpoint, payload: payload, direct: false)
        }
        browser.start(queue: queue)
    }

    private func connect(_ endpoint: NWEndpoint, payload: Data, direct: Bool) {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let candidate = NWConnection(to: endpoint, using: parameters)
        connection = candidate
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self, let candidate, self.connection === candidate else { return }
            switch state {
            case .ready:
                candidate.stateUpdateHandler = nil
                self.directTimeout?.cancel()
                self.directTimeout = nil
                self.browser?.cancel()
                self.browser = nil
                self.receive(32) { [weak self] challenge in self?.exchange(payload, challenge: challenge) }
            case .waiting where candidate.currentPath?.unsatisfiedReason == .localNetworkDenied:
                self.finish(.failure(Self.permissionError))
            case .failed(let error):
                if candidate.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    self.finish(.failure(Self.permissionError))
                } else if direct {
                    self.fallBackToBonjour(payload)
                } else {
                    self.finish(.failure(Self.connectionError(error)))
                }
            default:
                break
            }
        }
        candidate.start(queue: queue)
    }

    private static func connectionError(_ error: NWError) -> HKError {
        switch error {
        case .dns(-65570):
            return permissionError
        case .dns, .posix(.ENODATA):
            return HKError("iPhone не смог определить адрес ПК. Отсканируй новый QR-код или введи адрес из настроек hkotuner на ПК.")
        default:
            return HKError("Не удалось подключиться к ПК. Проверь общую сеть и что hkotuner на ПК открыт. \(error.localizedDescription)")
        }
    }

    private func exchange(_ payload: Data, challenge: Data) {
        do {
            let packet = try ChaChaPoly.seal(payload, using: secret, authenticating: aad(0, challenge)).combined
            var count = UInt32(packet.count).bigEndian
            var data = withUnsafeBytes(of: &count) { Data($0) }
            data.append(packet)
            connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { finish(.failure(Self.connectionError(error))); return }
                receive(4) { [weak self] header in self?.receiveResponse(header, challenge: challenge) }
            })
        } catch { finish(.failure(error)) }
    }

    private func receiveResponse(_ header: Data, challenge: Data) {
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (28...Self.limit).contains(count) else {
            finish(.failure(HKError("ПК прислал неверный ответ")))
            return
        }
        receive(count) { [weak self] data in
            guard let self else { return }
            finish(Result {
                let box = try ChaChaPoly.SealedBox(combined: data)
                return try ChaChaPoly.open(box, using: self.secret, authenticating: self.aad(1, challenge))
            })
        }
    }

    private func receive(_ count: Int, next: @escaping (Data) -> Void) {
        connection?.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count == count {
                next(data)
            } else {
                finish(.failure(error.map(Self.connectionError) ?? HKError("ПК закрыл соединение до окончания синхронизации. Проверь ключ и адрес ПК.")))
            }
        }
    }

    private func aad(_ direction: UInt8, _ challenge: Data) -> Data {
        Data("hkotuner-lan-sync-v1".utf8) + Data([direction]) + challenge
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        directTimeout?.cancel()
        browser?.cancel()
        connection?.cancel()
        browser = nil
        connection = nil
        continuation.resume(with: result)
    }
}
