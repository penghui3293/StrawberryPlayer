//
//  PlaylistView.swift
//  StrawberryPlayer
//
//  Created by penghui zhang on 2026/2/24.
//

import SwiftUI

struct PlaylistView: View {
    @EnvironmentObject var playbackService: PlaybackService
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List($playbackService.songs, id: \.id) { $song in
                HStack {
                    if let coverURL = song.coverURL {
                        CachedAsyncImage(
                            url: coverURL,
                            placeholder: {
                                Image(systemName: "music.note")
                                    .frame(width: 40, height: 40)
                                    .foregroundColor(.gray)
                            },
                            error: { _ in
                                Image(systemName: "music.note")
                                    .frame(width: 40, height: 40)
                                    .foregroundColor(.gray)
                            }
                        )
                        .id(coverURL)   // ✅ 添加此行
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .cornerRadius(4)
                    } else {
                        // 无封面 URL 时显示占位图
                        Image(systemName: "music.note")
                            .frame(width: 40, height: 40)
                            .foregroundColor(.gray)
                    }

                    VStack(alignment: .leading) {
                        Text(song.title)
                            .font(.headline)
                            .foregroundColor(playbackService.currentSong?.id == song.id ? .accentColor : .primary)
                        Text(song.artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if playbackService.currentSong?.id == song.id {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    playbackService.playSongInCurrentList(song)
                    dismiss()
                }
            }
            .navigationTitle("播放列表")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
