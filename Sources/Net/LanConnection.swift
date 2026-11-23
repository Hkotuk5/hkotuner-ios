import CryptoKit
import Foundation
import Network

/// A length-prefixed, authenticated exchange over Bonjour. The desktop sends a fresh challenge
/// and both messages authenticate that challenge and their direction.
final class LanConnection: @unchecked Sendable {
    private static let limit = 24 * 1024 * 1024
    private let queue = DispatchQueue(label: "uk.hkot.hkotuner.lan")
    private let secret: SymmetricKey
    private let label: String
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeout: DispatchWorkItem?
    private var cancelled = false

    init(key: Data) {
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
                    else { browse(payload) }
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func browse(_ payload: Data) {
        let timeLimit = DispatchWorkItem { [weak self] in
            self?.finish(.failure(HKError("ПК не ответил. Проверь Wi-Fi и запусти hkotuner на компьютере.")))
        }
        timeout = timeLimit
        queue.asyncAfter(deadline: .now() + 16, execute: timeLimit)
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let browser = NWBrowser(for: .bonjour(type: "_hkotuner-sync._tcp", domain: "local."), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.finish(.failure(error)) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, connection == nil,
                  let service = results.first(where: {
                      if case .service(let name, _, _, _) = $0.endpoint { return name == label }
                      return false
                  }) else { return }
            connect(service.endpoint, payload: payload)
        }
        browser.start(queue: queue)
    }

    private func connect(_ endpoint: NWEndpoint, payload: Data) {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.finish(.failure(error)) }
        }
        connection.start(queue: queue)
        receive(32) { [weak self] challenge in self?.exchange(payload, challenge: challenge) }
    }

    private func exchange(_ payload: Data, challenge: Data) {
        do {
            let packet = try ChaChaPoly.seal(payload, using: secret, authenticating: aad(0, challenge)).combined
            var count = UInt32(packet.count).bigEndian
            var data = withUnsafeBytes(of: &count) { Data($0) }
            data.append(packet)
            connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { finish(.failure(error)); return }
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
                return try ChaChaPoly.open(box, using: secret, authenticating: aad(1, challenge))
            })
        }
    }

    private func receive(_ count: Int, next: @escaping (Data) -> Void) {
        connection?.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count == count {
                next(data)
            } else {
                finish(.failure(error ?? HKError("ПК закрыл соединение до окончания синхронизации")))
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
        browser?.cancel()
        connection?.cancel()
        browser = nil
        connection = nil
        continuation.resume(with: result)
    }
}
