import Foundation

/// Persists connection metadata (host/user/db/port/name) as JSON under
/// Application Support. Passwords never live here — see `KeychainService`.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [ConnectionProfile] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Kullanıcı verisinin klasör adı — görünen ada ("MySQL Client")
            // BAĞLI DEĞİL, kasıtlı olarak eski hedef adında kalıyor. Yeniden
            // adlandırma sırasında burası da değiştirilince mevcut kurulumlar
            // kayıtlı bağlantılarını/geçmişini/ayarlarını "kaybetti"; container
            // klasörü zaten Bundle ID'den (com.sedattokay.MySQLMacClient)
            // geliyor, dolayısıyla bu ad kullanıcıya hiçbir yerde görünmüyor.
            let directory = appSupport.appendingPathComponent("MySQLMacClient", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("connections.json")
        }
        load()
    }

    func add(_ profile: ConnectionProfile) {
        connections.append(profile)
        save()
    }

    func update(_ profile: ConnectionProfile) {
        guard let index = connections.firstIndex(where: { $0.id == profile.id }) else { return }
        connections[index] = profile
        save()
    }

    func remove(_ profile: ConnectionProfile) {
        connections.removeAll { $0.id == profile.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        connections = (try? JSONDecoder().decode([ConnectionProfile].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
