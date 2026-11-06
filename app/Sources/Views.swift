import SwiftUI
import AVKit

// MARK: Libreria (offline)

struct LibraryView: View {
    @EnvironmentObject var store: Store
    @State private var playing: LocalVideo?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.local) { v in
                    Button { playing = v } label: {
                        HStack(spacing: 12) {
                            Image(systemName: v.isAudio ? "music.note" : "play.rectangle")
                                .font(.title2).frame(width: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.title).lineLimit(2).foregroundStyle(.primary)
                                Text(humanSize(v.size)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in idx.map { store.local[$0] }.forEach(store.delete) }
            }
            .overlay {
                if store.local.isEmpty {
                    ContentUnavailableView("Nessun video",
                                           systemImage: "tray",
                                           description: Text("Vai su PC, metti in coda un link e scaricalo qui."))
                }
            }
            .navigationTitle("Libreria")
            .onAppear {
                store.reloadLocal()
                PlayerSession.onRestore = { playing = $0 }
            }
        }
        .fullScreenCover(item: $playing) { PlayerScreen(video: $0) }
    }
}

/// Sessione di riproduzione: sopravvive alla chiusura della schermata quando parte il PiP.
final class PlayerSession: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
    static var current: PlayerSession?          // tenuta viva mentre il PiP è attivo
    static var onRestore: ((LocalVideo) -> Void)?

    let video: LocalVideo
    let player: AVPlayer
    let vc = AVPlayerViewController()
    var onStartPiP: (() -> Void)?
    var onSwipeDown: (() -> Void)?
    var pipActive = false
    private var restoring = false
    private var boosted = false
    private let badge = UILabel()

    private var key: String { "pos:" + video.id }

    static func session(for v: LocalVideo) -> PlayerSession {
        if let s = current, s.video.id == v.id { return s }
        return PlayerSession(v)
    }

    private init(_ v: LocalVideo) {
        video = v
        player = AVPlayer(url: v.url)
        super.init()
        let pos = UserDefaults.standard.double(forKey: key)
        if pos > 5 { player.seek(to: CMTime(seconds: pos, preferredTimescale: 600)) }
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.delegate = self

        // Tieni premuto = velocità 2×, rilascia = normale.
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        lp.minimumPressDuration = 0.4
        lp.cancelsTouchesInView = false
        lp.delegate = self
        vc.view.addGestureRecognizer(lp)

        // Swipe verso il basso = chiudi il lettore.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.delegate = self
        vc.view.addGestureRecognizer(pan)

        badge.text = "  2×  ▸▸  "
        badge.font = .boldSystemFont(ofSize: 16)
        badge.textColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        badge.layer.cornerRadius = 12; badge.layer.masksToBounds = true
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        if let ov = vc.contentOverlayView {
            ov.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.topAnchor.constraint(equalTo: ov.safeAreaLayoutGuide.topAnchor, constant: 16),
                badge.centerXAnchor.constraint(equalTo: ov.centerXAnchor),
                badge.heightAnchor.constraint(equalToConstant: 28)])
        }
        player.play()
    }

    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            guard player.timeControlStatus == .playing else { return }
            boosted = true; player.rate = 2; badge.isHidden = false
        case .ended, .cancelled, .failed:
            guard boosted else { return }
            boosted = false; player.rate = 1; badge.isHidden = true
        default: break
        }
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        guard g.state == .ended else { return }
        let t = g.translation(in: g.view), v = g.velocity(in: g.view)
        if t.y > 120, abs(t.y) > abs(t.x) * 1.5, v.y > 0 { onSwipeDown?() }
    }

    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }

    func savePosition() {
        let t = player.currentTime().seconds
        let d = player.currentItem?.duration.seconds ?? 0
        // Se è finito (o quasi) riparte da capo la volta dopo.
        UserDefaults.standard.set((d.isFinite && t > d - 10) ? 0 : t, forKey: key)
    }

    func stop() {
        savePosition(); player.pause()
        if PlayerSession.current === self { PlayerSession.current = nil }
    }

    // MARK: PiP
    func playerViewControllerWillStartPictureInPicture(_ c: AVPlayerViewController) {
        pipActive = true; restoring = false
        PlayerSession.current = self
        DispatchQueue.main.async { self.onStartPiP?() }
    }

    func playerViewController(_ c: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        restoring = true
        PlayerSession.onRestore?(video)
        done(true)
    }

    func playerViewControllerDidStopPictureInPicture(_ c: AVPlayerViewController) {
        pipActive = false
        if !restoring { stop() }      // chiuso con la X del PiP
    }
}

struct PlayerRepresentable: UIViewControllerRepresentable {
    let session: PlayerSession
    func makeUIViewController(context: Context) -> AVPlayerViewController { session.vc }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}

struct PlayerScreen: View {
    let video: LocalVideo
    @Environment(\.dismiss) private var dismiss
    @State private var session: PlayerSession

    init(video: LocalVideo) {
        self.video = video
        _session = State(initialValue: PlayerSession.session(for: video))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            PlayerRepresentable(session: session).ignoresSafeArea()
        }
        .onAppear {
            session.onStartPiP = { dismiss() }
            session.onSwipeDown = { dismiss() }
        }
        .onDisappear {
            // In PiP la riproduzione continua; altrimenti salva e ferma.
            if !session.pipActive { session.stop() }
        }
    }
}

// MARK: PC (coda e download)

struct PCView: View {
    @EnvironmentObject var store: Store
    @State private var link = ""
    @State private var quality = 720
    @State private var audio = false
    @State private var playlist = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server sul PC") {
                    TextField("indirizzo:porta", text: $store.server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    Toggle("Cancella dal PC dopo il download", isOn: $store.autoDelete)
                    if !store.status.isEmpty {
                        Text(store.status).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("Nuovo video") {
                    TextField("Link YouTube", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Incolla dagli appunti") {
                        if let s = UIPasteboard.general.string { link = s }
                    }
                    Picker("Qualità", selection: $quality) {
                        Text("480p").tag(480); Text("720p").tag(720); Text("1080p").tag(1080)
                    }.pickerStyle(.segmented)
                    Toggle("Solo audio", isOn: $audio)
                    Toggle("Intera playlist", isOn: $playlist)
                    Button("Scarica sul PC") {
                        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !l.isEmpty else { return }
                        link = ""
                        Task { await store.addToQueue(url: l, quality: quality, audio: audio, playlist: playlist) }
                    }.disabled(link.isEmpty)
                }

                if !store.jobs.isEmpty {
                    Section("Coda sul PC") {
                        ForEach(store.jobs) { j in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(j.title ?? j.url).lineLimit(2).font(.subheadline)
                                if j.state == "error" {
                                    Text(j.error ?? "errore").font(.caption).foregroundStyle(.red)
                                } else {
                                    ProgressView(value: j.progress ?? 0)
                                    Text(j.state).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    ForEach(store.remote) { v in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.title).lineLimit(2).font(.subheadline)
                                Text(humanSize(v.size)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let p = store.progress[v.name] {
                                ProgressView(value: p).frame(width: 60)
                            } else if store.isLocal(v.name) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button { store.download(v) } label: {
                                    Image(systemName: "arrow.down.circle.fill").font(.title2)
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { store.remote[$0] }.forEach { store.deleteRemote($0.name) } }
                    if store.remote.contains(where: { store.isLocal($0.name) }) {
                        Button("Cancella dal PC quelli già copiati", role: .destructive) {
                            store.deleteCopiedFromPC()
                        }
                    }
                } header: {
                    HStack {
                        Text("File sul PC")
                        Spacer()
                        Button("Scarica tutti i nuovi") { store.downloadAllNew() }
                            .font(.footnote).textCase(nil)
                    }
                }
            }
            .navigationTitle("PC")
            .task {
                while !Task.isCancelled {
                    await store.refresh()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }
}
