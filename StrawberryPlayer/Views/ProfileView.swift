
// MARK: - ProfileView.swift (修改后)
import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var userService: UserService
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var libraryService: LibraryService
    @EnvironmentObject var virtualArtistService: VirtualArtistService  // 需要注入
    
    @State private var showLogin = false
    
    init() {
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.backgroundColor = .clear
        navBarAppearance.backgroundEffect = nil
        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance
    }
    
    var body: some View {
        NavigationStack {
            if userService.isLoggedIn, let user = userService.currentUser {
                // 已登录状态
                List {
                    Section {
                        HStack {
                            AsyncImage(url: URL(string: user.avatarURL ?? "")) { phase in
                                if let image = phase.image {
                                    image.resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                } else {
                                    Image(systemName: "person.circle.fill")
                                        .resizable()
                                        .frame(width: 80, height: 80)
                                        .foregroundColor(.gray)
                                }
                            }
                            .id(user.avatarURL ?? user.phone ?? user.nickname ?? "avatar")

                            VStack(alignment: .leading) {
                                Text(user.nickname)
                                    .font(.headline)
                            }
                        }
                        .padding(.vertical)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    Section {
                        Button("退出登录", role: .destructive) {
                            userService.logout()
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    
                    
                    // 创作区域
                    Section {
                        NavigationLink(destination: MyArtistsView()) {
                            Label("虚拟艺人作品", systemImage: "person.fill.badge.plus")
                        }
                        NavigationLink(destination: MyUploadedWorksView()) {
                            Label("公共版权作品", systemImage: "music.note.list")
                        }
                    } header: {
                        Text("创作")
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .navigationTitle("我的")
                .toolbarBackground(.hidden, for: .navigationBar)
            } else {
                // 未登录状态（保持不变）
                VStack(spacing: 20) {
                    Image(systemName: "person.crop.circle")
                        .resizable()
                        .frame(width: 100, height: 100)
                        .foregroundColor(.gray)
                    
                    Text("登录后享受更多功能")
                        .font(.headline)
                    
                    Button("立即登录") {
                        showLogin = true
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
                .navigationTitle("我的")
                .toolbarBackground(.hidden, for: .navigationBar)
                .fullScreenCover(isPresented: $showLogin) {
                    LoginView()
                        .environmentObject(userService)
                }
            }
        }
        .background(Color.clear)
        .onAppear {
                playbackService.setAllowMiniPlayer(false)
            }
    }
}
