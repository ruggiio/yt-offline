import Foundation
import SwiftUI

struct RemoteVideo: Codable, Identifiable, Hashable {
    let name: String
    let size: Int64
    var id: String { name }
    var title: String { (name as NSString).deletingPathExtension }
}

struct Job: Codable, Identifiable {
    let id: String
    let url: String
    var title: String?
    var state: String
    var progress: Double?
    var error: String?
}

struct ServerState: Codable {
    var videos: [RemoteVideo]
    var jobs: [Job]
}

struct LocalVideo: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let date: Date
    var id: String { url.lastPathComponent }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var isAudio: Bool { ["m4a", "mp3"].contains(url.pathExtension.lowercased()) }
}

final class Store: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let exts: Set<String> = ["mp4", "m4v", "mov", "m4a", "mp3"]

    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }
    @Published var autoDelete: Bool {
        didSet { UserDefaults.standard.set(autoDelete, forKey: "autoDelete") }
    }
    @Published var local: [LocalVideo] = []
    @Published var remote: [RemoteVideo] = []
    @Published var jobs: [Job] = []
    @Published var progress: [String: Double] = [:]   // nome file -> 0...1 (download in corso)
    @Published var status: String = ""

    private var session: URLSession!

    override init() {
        server = UserDefaults.standard.string(forKey: "server") ?? "192.168.1.7:8790"
        autoDelete = UserDefaults.standard.object(forKey: "autoDelete") as? Bool ?? true
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        reloadLocal()
    }

    var baseURL: URL? {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.hasPrefix("http") { s = "http://" + s }
        return URL(string: s)
    }

    // MARK: libreria locale

    func reloadLocal() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: Store.docs, includingPropertiesForKeys: keys)) ?? []
        local = files
            .filter { Store.exts.contains($0.pathExtension.lowercased()) }
            .map { f in
                let v = try? f.resourceValues(forKeys: Set(keys))
                return LocalVideo(url: f, size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.date > $1.date }
    }

    func delete(_ v: LocalVideo) {
        try? FileManager.default.removeItem(at: v.url)
        UserDefaults.standard.removeObject(forKey: "pos:" + v.id)
        reloadLocal()
    }

    func isLocal(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: Store.docs.appendingPathComponent(name).path)
    }

    // MARK: server sul PC

    func refresh() async {
        guard let base = baseURL else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/state"))
        req.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let s = try JSONDecoder().decode(ServerState.self, from: data)
            await MainActor.run {
                remote = s.videos
                jobs = s.jobs
                status = ""
            }
        } catch {
            await MainActor.run { status = "PC non raggiungibile (\(error.localizedDescription))" }
        }
    }

    func addToQueue(url: String, quality: Int, audio: Bool, playlist: Bool) async {
        guard let base = baseURL else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/add"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        let body: [String: Any] = ["url": url, "quality": quality, "audio": audio, "playlist": playlist]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            _ = try await URLSession.shared.data(for: req)
            await refresh()
        } catch {
            await MainActor.run { status = "Invio fallito (\(error.localizedDescription))" }
        }
    }

    func download(_ v: RemoteVideo) {
        guard progress[v.name] == nil, !isLocal(v.name), let base = baseURL else { return }
        let url = base.appendingPathComponent("files").appendingPathComponent(v.name)
        let task = session.downloadTask(with: url)
        task.taskDescription = v.name
        progress[v.name] = 0
        task.resume()
    }

    func deleteRemote(_ name: String) {
        guard let base = baseURL else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/delete"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
        Task {
            _ = try? await URLSession.shared.data(for: req)
            await refresh()
        }
    }

    func deleteCopiedFromPC() {
        for v in remote where isLocal(v.name) { deleteRemote(v.name) }
    }

    func downloadAllNew() {
        for v in remote where !isLocal(v.name) { download(v) }
    }

    // MARK: URLSessionDownloadDelegate (callback sul main thread)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let name = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        progress[name] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription else { return }
        if let r = downloadTask.response as? HTTPURLResponse, r.statusCode != 200 {
            status = "Errore \(r.statusCode) scaricando \(name)"
            return
        }
        let dest = Store.docs.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            if autoDelete { deleteRemote(name) }
        } catch {
            status = "Salvataggio fallito: \(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let name = task.taskDescription { progress[name] = nil }
        if let error { status = "Download interrotto (\(error.localizedDescription))" }
        reloadLocal()
    }
}

func humanSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
