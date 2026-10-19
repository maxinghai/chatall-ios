//
//  LoginView.swift
//  ChatAll
//
//  登录 / 注册切换，服务器地址输入（可折叠的高级设置），绿色主色。
//

import SwiftUI

struct LoginView: View {
    @EnvironmentObject var store: AppStore

    @State private var isRegister = false
    @State private var username = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var host = AppConfig.host
    @State private var showAdvanced = false
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 40)

                // Logo
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22)
                            .fill(Color.chatGreen)
                            .frame(width: 88, height: 88)
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    }
                    Text("聊天")
                        .font(.system(size: 24, weight: .semibold))
                }

                // 输入区
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "person")
                            .foregroundColor(.gray)
                            .frame(width: 24)
                        TextField("用户名", text: $username)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                    HStack {
                        Image(systemName: "lock")
                            .foregroundColor(.gray)
                            .frame(width: 24)
                        SecureField("密码", text: $password)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                    if isRegister {
                        HStack {
                            Image(systemName: "face.smiling")
                                .foregroundColor(.gray)
                                .frame(width: 24)
                            TextField("昵称", text: $nickname)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                    }
                }

                // 主按钮
                Button(action: submit) {
                    HStack {
                        if loading { ProgressView().tint(.white) }
                        Text(isRegister ? "注册并登录" : "登录")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.chatGreen)
                    .cornerRadius(10)
                }
                .disabled(loading || username.isEmpty || password.isEmpty)

                // 切换登录/注册
                Button(action: {
                    withAnimation { isRegister.toggle() }
                }) {
                    Text(isRegister ? "已有账号？去登录" : "没有账号？去注册")
                        .font(.system(size: 15))
                        .foregroundColor(.chatGreen)
                }

                // 高级设置：服务器地址
                VStack(spacing: 10) {
                    Button(action: { withAnimation { showAdvanced.toggle() } }) {
                        HStack {
                            Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                                .font(.system(size: 12))
                            Text("高级设置")
                                .font(.system(size: 14))
                            Spacer()
                            Text(AppConfig.host)
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        }
                        .foregroundColor(.gray)
                    }

                    if showAdvanced {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("服务器地址（host:port）")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                            TextField("43.248.188.28:18422", text: $host)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(12)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                            Text("默认 43.248.188.28:18422，仅在自建服务器时修改")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.top, 8)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 28)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .alert(isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Alert(title: Text("提示"),
                  message: Text(store.errorMessage ?? ""),
                  dismissButton: .default(Text("知道了")))
        }
    }

    private func submit() {
        // 保存服务器地址
        let h = host.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty { AppConfig.host = h }

        loading = true
        let u = username
        let p = password
        let n = nickname.isEmpty ? u : nickname
        Task { @MainActor in
            if isRegister {
                await store.register(username: u, password: p, nickname: n)
            } else {
                await store.login(username: u, password: p)
            }
            loading = false
        }
    }
}
