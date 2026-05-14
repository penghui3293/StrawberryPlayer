import SwiftUI

struct LoginView: View {
    @EnvironmentObject var userService: UserService
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var lyricsService: LyricsService
    @Environment(\.dismiss) var dismiss
    
    @State private var phone = ""
    @State private var verifyCode = ""
    @State private var isSendingCode = false
    @State private var countdown = 0
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var keyboardHeight: CGFloat = 0
    
    @FocusState private var focusedField: Field?
    private enum Field {
        case phone, code
    }
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                VStack(spacing: 24) {
                    Spacer(minLength: 80)
                    
                    Text("手机号登录")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 40)
                    
                    TextField("手机号", text: $phone)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.phonePad)
                        .autocapitalization(.none)
                        .focused($focusedField, equals: .phone)
                        .padding(.horizontal, 40)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .code
                        }
                    
                    HStack {
                        TextField("验证码", text: $verifyCode)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .code)
                            .submitLabel(.done)
                            .onSubmit {
                                focusedField = nil
                            }
                        
                        Button(action: sendCode) {
                            if isSendingCode {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                                    .scaleEffect(0.8)
                            } else {
                                Text(countdown > 0 ? "\(countdown)秒后重发" : "获取验证码")
                                    .font(.caption)
                                    .foregroundColor(countdown > 0 ? .gray : .blue)
                            }
                        }
                        .disabled(countdown > 0 || isSendingCode)
                    }
                    .padding(.horizontal, 40)
                    
                    Button(action: login) {
                        Text("登录")
                            .bold()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
                    
                    Spacer(minLength: 100)
                }
                .frame(width: geometry.size.width)
                .offset(y: -min(keyboardHeight, 200))      // 键盘弹起时整体上移（最多上移200pt）
                .animation(.easeOut(duration: 0.25), value: keyboardHeight)
            }
            .ignoresSafeArea(.keyboard)                    // 关闭系统自动避让，改用手动偏移
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                    }
                }
            }
            .alert("提示", isPresented: $showAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .onReceive(timer) { _ in
                if countdown > 0 {
                    countdown -= 1
                }
            }
            .onAppear {
                lyricsService.pauseDriver()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedField = .phone
                }
            }
            .onDisappear {
                lyricsService.resumeDriver()
            }
            // 监听键盘通知，更新键盘高度
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notif in
                if let frame = notif.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    keyboardHeight = frame.height
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled()
    }
    
    private func sendCode() {
        guard phone.count == 11, phone.allSatisfy({ $0.isNumber }) else {
            alertMessage = "请输入正确的手机号"
            showAlert = true
            return
        }
        guard !isSendingCode else { return }
        
        isSendingCode = true
        userService.sendVerificationCode(to: phone) { success in
            DispatchQueue.main.async {
                isSendingCode = false
                if success {
                    countdown = 60
                    alertMessage = "验证码已发送"
                } else {
                    alertMessage = "发送失败，请重试"
                }
                showAlert = true
            }
        }
    }
    
    private func login() {
        guard phone.count == 11, phone.allSatisfy({ $0.isNumber }) else {
            alertMessage = "请输入正确的手机号"
            showAlert = true
            return
        }
        guard !verifyCode.isEmpty else {
            alertMessage = "请输入验证码"
            showAlert = true
            return
        }
        
        focusedField = nil
        
        let wasPlaying = playbackService.isPlaying
        let currentSongId = playbackService.currentSong?.id
        
        userService.loginOrRegister(phone: phone, code: verifyCode) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    playbackService.syncFavorites()
                    if let currentSong = playbackService.currentSong {
                        playbackService.fetchLikeCount(for: currentSong)
                        playbackService.fetchCommentCount(for: currentSong)
                    }
                    if wasPlaying, playbackService.currentSong?.id == currentSongId {
                        playbackService.play()
                        playbackService.lyricsService.updateCurrentIndex(with: playbackService.currentTime)
                        playbackService.forceRecalibrateLyrics()
                    }
                    dismiss()
                case .failure(let error):
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }
}
