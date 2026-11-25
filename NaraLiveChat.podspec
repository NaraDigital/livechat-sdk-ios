Pod::Spec.new do |s|
  s.name             = "NaraLiveChat"
  s.version          = "1.0.1"
  s.summary          = "NaraChat live-chat messenger SDK for iOS (SwiftUI, native UI)."
  s.description      = "Native live-chat messenger for iOS apps, connected to NaraChat: a native SwiftUI interface (not a WebView) on SDK API v1."
  s.homepage         = "https://narachat.com"
  s.license      = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { "NaraChat" => "dev@narachat.com" }
  s.source           = { :git => "https://github.com/NaraDigital/livechat-sdk-ios.git", :tag => s.version.to_s }
  s.ios.deployment_target = "15.0"
  s.swift_version    = "5.9"
  s.source_files     = "Sources/NaraLiveChat/**/*.swift"
end
