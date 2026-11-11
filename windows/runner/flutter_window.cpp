#include "flutter_window.h"

#include <shellapi.h>

#include <optional>
#include <string>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "pdf_renderer.h"
#include "utils.h"

namespace {
// Posted when a background job queued a reply for the platform thread.
constexpr UINT kRunUiTasksMessage = WM_APP + 0x5D;
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "theapp/windows",
      &flutter::StandardMethodCodec::GetInstance());
  // Dart -> native: "setWindowTheme" colours the native frame to match the
  // app's light/dark theme (see lib/platform/window_chrome.dart).
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        // PDF rendering (Windows.Data.Pdf): work runs on a worker thread,
        // the reply is marshalled back to this (the platform) thread.
        if (call.method_name() == "pdfInfo" ||
            call.method_name() == "pdfRenderPage") {
          std::string path;
          int page = 0, width = 0;
          if (call.method_name() == "pdfInfo") {
            const auto* p = std::get_if<std::string>(call.arguments());
            if (!p) {
              result->Error("bad-args", "Expected a path");
              return;
            }
            path = *p;
          } else {
            const auto* args =
                std::get_if<flutter::EncodableMap>(call.arguments());
            if (!args) {
              result->Error("bad-args", "Expected a map");
              return;
            }
            auto path_it = args->find(flutter::EncodableValue("path"));
            if (path_it != args->end()) {
              if (const auto* v = std::get_if<std::string>(&path_it->second)) {
                path = *v;
              }
            }
            auto read_arg = [args](const char* key) -> int {
              auto it = args->find(flutter::EncodableValue(key));
              if (it == args->end()) return 0;
              if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
              if (const auto* v = std::get_if<int64_t>(&it->second)) {
                return static_cast<int>(*v);
              }
              return 0;
            };
            page = read_arg("page");
            width = read_arg("width");
            if (path.empty()) {
              result->Error("bad-args", "Expected a path");
              return;
            }
          }
          std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>
              shared(result.release());
          auto reply = [this, shared](flutter::EncodableValue value,
                                      std::string error) {
            PostUiTask([shared, value = std::move(value),
                        error = std::move(error)]() {
              if (error.empty()) {
                shared->Success(value);
              } else {
                shared->Error("pdf", error);
              }
            });
          };
          if (call.method_name() == "pdfInfo") {
            pdf_renderer::PageSizes(path, std::move(reply));
          } else {
            pdf_renderer::RenderPage(path, page, width, std::move(reply));
          }
          return;
        }
        if (call.method_name() != "setWindowTheme") {
          result->NotImplemented();
          return;
        }
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) {
          result->Error("bad-args", "Expected a map");
          return;
        }
        auto read_int = [args](const char* key, int64_t fallback) -> int64_t {
          auto it = args->find(flutter::EncodableValue(key));
          if (it == args->end()) return fallback;
          if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
          if (const auto* v = std::get_if<int64_t>(&it->second)) return *v;
          return fallback;
        };
        bool dark = true;
        auto dark_it = args->find(flutter::EncodableValue("dark"));
        if (dark_it != args->end()) {
          if (const auto* v = std::get_if<bool>(&dark_it->second)) dark = *v;
        }
        SetAppTheme(dark, static_cast<DWORD>(read_int("caption", 0)),
                    static_cast<DWORD>(read_int("text", 0xFFFFFF)),
                    static_cast<DWORD>(read_int("border", 0x474D3A)));
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  webviews_ = std::make_unique<WebViewHost>(
      flutter_controller_->engine()->messenger(),
      flutter_controller_->view()->GetNativeWindow());
  // Files dragged from File Explorer arrive as WM_DROPFILES.
  DragAcceptFiles(GetHandle(), TRUE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  {
    // Late PDF replies must not reach a torn-down engine.
    std::lock_guard<std::mutex> lock(ui_tasks_->mutex);
    ui_tasks_->alive = false;
    ui_tasks_->tasks.clear();
  }
  webviews_ = nullptr;  // before the engine it talks through
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::PostUiTask(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(ui_tasks_->mutex);
    if (!ui_tasks_->alive) return;
    ui_tasks_->tasks.push_back(std::move(task));
  }
  PostMessage(GetHandle(), kRunUiTasksMessage, 0, 0);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case kRunUiTasksMessage: {
      std::vector<std::function<void()>> tasks;
      {
        std::lock_guard<std::mutex> lock(ui_tasks_->mutex);
        tasks.swap(ui_tasks_->tasks);
      }
      for (auto& task : tasks) {
        task();
      }
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DROPFILES: {
      HDROP drop = reinterpret_cast<HDROP>(wparam);
      UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      flutter::EncodableList files;
      for (UINT i = 0; i < count; i++) {
        UINT length = DragQueryFileW(drop, i, nullptr, 0);
        std::wstring path(length + 1, L'\0');
        DragQueryFileW(drop, i, path.data(), length + 1);
        path.resize(length);
        files.push_back(flutter::EncodableValue(Utf8FromUtf16(path.c_str())));
      }
      DragFinish(drop);
      if (channel_ && !files.empty()) {
        channel_->InvokeMethod(
            "filesDropped",
            std::make_unique<flutter::EncodableValue>(std::move(files)));
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
