#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <functional>
#include <memory>
#include <mutex>
#include <vector>

#include "webview_host.h"
#include "win32_window.h"

// Tasks queued from worker threads, run on the platform thread by
// FlutterWindow::MessageHandler. |alive| turns false when the engine is
// being torn down, after which queued tasks are dropped.
struct UiTaskQueue {
  std::mutex mutex;
  std::vector<std::function<void()>> tasks;
  bool alive = true;
};

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // "theapp/windows": tells Dart about files dropped on the window.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // Safari's engine on Windows (WebView2 views over the Flutter page).
  std::unique_ptr<WebViewHost> webviews_;

  // Replies from background work (the PDF renderer), marshalled back to
  // the platform thread. Shared with worker threads, so it outlives the
  // window if a job finishes late.
  std::shared_ptr<UiTaskQueue> ui_tasks_ = std::make_shared<UiTaskQueue>();

  // Queues |task| and pokes the window; safe from any thread.
  void PostUiTask(std::function<void()> task);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
