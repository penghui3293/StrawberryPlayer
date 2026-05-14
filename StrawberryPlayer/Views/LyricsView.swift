//
//  LyricsView.swift
//  Player
//
//  Created by penghui zhang on 2026/2/15.
//

// LyricsView.swift


import SwiftUI

struct LyricsView: View {
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var lyricsService: LyricsService

    var body: some View {
        VStack {
            // 可选：显示偏移调整滑块（不必须，但如果有的话可以保留）
            if let currentSong = playbackService.currentSong {
                HStack {
                    Text("偏移: \(String(format: "%.1f", lyricsService.lyricOffset))秒")
                    Slider(value: $lyricsService.lyricOffset, in: -5...5, step: 0.1) { editing in
                        if !editing {
                            lyricsService.saveLyricOffset(for: currentSong)
                        }
                    }
                }
                .padding()
            }

            // 歌词列表
            ScrollViewReader { proxy in
                List(Array(lyricsService.lyrics.enumerated()), id: \.offset) { index, line in
                    Text(line.text)
                        .font(.system(size: index == lyricsService.currentLyricIndex ? 18 : 14))
                        .foregroundColor(index == lyricsService.currentLyricIndex ? .blue : .primary)
                        .fontWeight(index == lyricsService.currentLyricIndex ? .bold : .regular)
                        .id(index)
                }
                .onChange(of: lyricsService.currentLyricIndex) { newIndex in
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .onChange(of: playbackService.currentSong) { newSong in
            if let song = newSong {
//                lyricsService.loadLyrics(for: song)
                  lyricsService.fetchLyrics(for: song)
            }
        }
        .onReceive(playbackService.$currentTime) { time in
            lyricsService.updateCurrentIndex(with: time)
        }
    }
}

  
 


