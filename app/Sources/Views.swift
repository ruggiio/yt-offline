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
            .onAppear { store.reloadLocal() }
        }
        .fullScreenCover(item: $playing) { PlayerScreen(video: $0) }
    }
}

struct PlayerScreen: View {
    let video: LocalVideo
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    private var key: String { "pos:" + video.id }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player { VideoPlayer(player: player).ignoresSafeArea() }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title).foregroundStyle(.white.opacity(0.85)).padding(14)
            }
        }
        .onAppear {
            let p = AVPlayer(url: video.url)
            let pos = UserDefaults.standard.double(forKey: key)
            if pos > 5 { p.seek(to: CMTime(seconds: pos, preferredTimescale: 600)) }
            p.play()
            player = p
        }
        .onDisappear {
            guard let p = player else { return }
            let t = p.currentTime().seconds
            let d = p.currentItem?.duration.seconds ?? 0
            // Se è finito (o quasi) riparte da capo la volta dopo.
            UserDefaults.standard.set((d.isFinite && t > d - 10) ? 0 : t, forKey: key)
            p.pause()
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
