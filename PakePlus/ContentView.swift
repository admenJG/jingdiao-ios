//
//  ContentView.swift
//  PakePlus
//
//  Created by Song on 2025/3/29.
//

import SwiftUI
import UIKit
import WebKit

struct ContentView: View {
    // read value from info
    let webUrl = Bundle.main.object(forInfoDictionaryKey: "WEBURL") as? String ?? ""
    let debug = Bundle.main.object(forInfoDictionaryKey: "DEBUG") as? Bool ?? false
    let fullScreen = Bundle.main.object(forInfoDictionaryKey: "FULLSCREEN") as? Bool ?? false
    let launchImage = Bundle.main.object(forInfoDictionaryKey: "LAUNCHIMAGE") as? Bool ?? false
    let screenOn = Bundle.main.object(forInfoDictionaryKey: "SCREENON") as? Bool ?? false

    @Environment(\.scenePhase) private var scenePhase
    @State private var isWebLoaded: Bool = false
    // 持有 WKWebView 实例，供底部工具栏控制返回/刷新/回首页
    @State private var webViewRef: WKWebView?

    var body: some View {
        // BottomMenuView()
        ZStack {
            // webview
            WebView(
                webUrl: URL(string: webUrl)!,
                debug: debug,
                onLoadFinished: {
                    isWebLoaded = true
                },
                webViewRef: $webViewRef
            )
            .ignoresSafeArea(edges: [.all])
            .allowsHitTesting(isWebLoaded)
            
            // 底部导航工具栏：返回 / 刷新 / 首页（常驻，解决「进下一层回不来」）
            VStack {
                Spacer()
                HStack(spacing: 0) {
                    Button(action: {
                        webViewRef?.goBack()
                    }) {
                        Text("返回")
                            .font(.system(size: 16, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    Divider().frame(height: 22)
                    Button(action: {
                        webViewRef?.reload()
                    }) {
                        Text("刷新")
                            .font(.system(size: 16, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    Divider().frame(height: 22)
                    Button(action: {
                        if let u = URL(string: webUrl) {
                            webViewRef?.load(URLRequest(url: u))
                        }
                    }) {
                        Text("首页")
                            .font(.system(size: 16, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                }
                .foregroundColor(.primary)
                .background(Color(.systemBackground))
                .overlay(
                    Rectangle().frame(height: 0.5).foregroundColor(Color(.systemGray4)),
                    alignment: .top
                )
            }

            // loading screen
            if !isWebLoaded && launchImage {
                Image("LaunchScreen")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .statusBarHidden(fullScreen)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = screenOn
        }
        .onChange(of: scenePhase) { phase in
            UIApplication.shared.isIdleTimerDisabled = screenOn && (phase == .active)
        }
    }
}

// #Preview {
//     ContentView()
// }
