#ifndef RUNNER_WEBVIEW_HOST_H_
#define RUNNER_WEBVIEW_HOST_H_

// THEapp's Windows browser engine: Microsoft Edge WebView2 views hosted by
// the runner itself (no Flutter plugin, so Windows Developer Mode is not
// needed). Each Safari tab on Windows is one view, placed over the Flutter
// page where Dart says (method channel "theapp/webview_win"). Needs the
// WebView2 Runtime (installed with Windows 10/11 updates and Edge).

#include <windows.h>
#include <wrl.h>

#include <WebView2.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

class WebViewHost {
 public:
  WebViewHost(flutter::BinaryMessenger* messenger, HWND parent);
  ~WebViewHost();

 private:
  struct Download {
    std::string id;
    std::string url;
    std::string fileName;
    std::wstring path;
  };

  struct View {
    int id = 0;
    bool is_private = false;
    Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller;
    Microsoft::WRL::ComPtr<ICoreWebView2> web;
    std::wstring pending_url;
    RECT bounds{0, 0, 0, 0};
    bool visible = false;
    double zoom = 1.0;
    bool loading = false;
    std::string error;
    int download_counter = 0;
  };

  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                  result);
  void WithEnvironment(std::function<void(ICoreWebView2Environment*)> then);
  void Create(int id, bool is_private);
  void Wire(View* v);
  void Apply(View* v);
  void SendState(View* v);
  void Send(const std::string& method, flutter::EncodableMap args);
  View* Find(int id);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND parent_;
  Microsoft::WRL::ComPtr<ICoreWebView2Environment> env_;
  bool env_pending_ = false;
  std::string env_error_;
  std::vector<std::function<void(ICoreWebView2Environment*)>> env_waiters_;
  std::map<int, std::unique_ptr<View>> views_;
};

#endif  // RUNNER_WEBVIEW_HOST_H_
