#include "webview_host.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>

#include <algorithm>
#include <cctype>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

std::wstring Wide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
  return w;
}

std::string Utf8(const wchar_t* w) {
  if (w == nullptr || *w == 0) return std::string();
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  std::string s(n > 0 ? n - 1 : 0, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), n, nullptr, nullptr);
  return s;
}

// Takes ownership of a CoTaskMem string from WebView2.
std::string Take(LPWSTR w) {
  std::string s = Utf8(w);
  if (w != nullptr) CoTaskMemFree(w);
  return s;
}

std::string Scheme(const std::string& url) {
  auto colon = url.find(':');
  if (colon == std::string::npos) return std::string();
  std::string s = url.substr(0, colon);
  std::transform(s.begin(), s.end(), s.begin(), [](char c) {
    return static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  });
  return s;
}

std::string Host(const std::string& url) {
  auto start = url.find("://");
  if (start == std::string::npos) return url;
  start += 3;
  auto end = url.find_first_of("/:?#", start);
  return url.substr(start, end == std::string::npos ? std::string::npos
                                                      : end - start);
}

std::wstring KnownFolder(REFKNOWNFOLDERID id) {
  PWSTR path = nullptr;
  std::wstring out;
  if (SUCCEEDED(SHGetKnownFolderPath(id, 0, nullptr, &path))) out = path;
  CoTaskMemFree(path);
  return out;
}

const EncodableValue* Arg(const EncodableMap& m, const char* key) {
  auto it = m.find(EncodableValue(key));
  return it == m.end() ? nullptr : &it->second;
}

int IntArg(const EncodableMap& m, const char* key) {
  const EncodableValue* v = Arg(m, key);
  if (v == nullptr) return 0;
  if (auto i = std::get_if<int32_t>(v)) return *i;
  if (auto l = std::get_if<int64_t>(v)) return (int)*l;
  if (auto d = std::get_if<double>(v)) return (int)*d;
  return 0;
}

double DoubleArg(const EncodableMap& m, const char* key, double fallback) {
  const EncodableValue* v = Arg(m, key);
  if (v == nullptr) return fallback;
  if (auto d = std::get_if<double>(v)) return *d;
  if (auto i = std::get_if<int32_t>(v)) return *i;
  return fallback;
}

std::string StringArg(const EncodableMap& m, const char* key) {
  const EncodableValue* v = Arg(m, key);
  if (v == nullptr) return std::string();
  if (auto s = std::get_if<std::string>(v)) return *s;
  return std::string();
}

bool BoolArg(const EncodableMap& m, const char* key) {
  const EncodableValue* v = Arg(m, key);
  if (v == nullptr) return false;
  if (auto b = std::get_if<bool>(v)) return *b;
  return false;
}

}  // namespace

WebViewHost::WebViewHost(flutter::BinaryMessenger* messenger, HWND parent)
    : parent_(parent) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "theapp/webview_win",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { Handle(call, std::move(result)); });
}

WebViewHost::~WebViewHost() {
  channel_->SetMethodCallHandler(nullptr);
  for (auto& [id, v] : views_) {
    if (v->controller) v->controller->Close();
  }
  views_.clear();
}

WebViewHost::View* WebViewHost::Find(int id) {
  auto it = views_.find(id);
  return it == views_.end() ? nullptr : it->second.get();
}

void WebViewHost::Send(const std::string& method, EncodableMap args) {
  channel_->InvokeMethod(method,
                         std::make_unique<EncodableValue>(std::move(args)));
}

void WebViewHost::WithEnvironment(
    std::function<void(ICoreWebView2Environment*)> then) {
  if (env_) {
    then(env_.Get());
    return;
  }
  env_waiters_.push_back(std::move(then));
  if (env_pending_) return;
  env_pending_ = true;
  // Browsing data lives with THEapp's local (not synced, not backed up)
  // files, separate from Edge's own profile.
  std::wstring folder =
      KnownFolder(FOLDERID_LocalAppData) + L"\\THEapp\\WebView2";
  HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, folder.c_str(), nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
            env_pending_ = false;
            if (FAILED(result) || env == nullptr) {
              env_error_ =
                  "The WebView2 Runtime is missing or failed to start. "
                  "Install it from Microsoft (Evergreen Runtime).";
              env_waiters_.clear();
              for (auto& [id, v] : views_) {
                v->error = env_error_;
                SendState(v.get());
              }
              return S_OK;
            }
            env_ = env;
            auto waiters = std::move(env_waiters_);
            env_waiters_.clear();
            for (auto& w : waiters) w(env_.Get());
            return S_OK;
          })
          .Get());
  if (FAILED(hr)) {
    env_pending_ = false;
    env_error_ = "The WebView2 Runtime is not installed.";
    env_waiters_.clear();
  }
}

void WebViewHost::Create(int id, bool is_private) {
  if (Find(id) != nullptr) return;
  auto view = std::make_unique<View>();
  view->id = id;
  view->is_private = is_private;
  views_[id] = std::move(view);
  if (!env_error_.empty()) {
    views_[id]->error = env_error_;
    SendState(views_[id].get());
    return;
  }
  WithEnvironment([this, id](ICoreWebView2Environment* env) {
    auto handler =
        Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
            [this, id](HRESULT result,
                       ICoreWebView2Controller* controller) -> HRESULT {
              View* v = Find(id);
              if (v == nullptr) {
                if (controller) controller->Close();  // tab closed meanwhile
                return S_OK;
              }
              if (FAILED(result) || controller == nullptr) {
                v->error = "This page could not be shown (WebView2 error).";
                SendState(v);
                return S_OK;
              }
              v->controller = controller;
              controller->get_CoreWebView2(&v->web);
              Wire(v);
              Apply(v);
              if (!v->pending_url.empty()) {
                v->web->Navigate(v->pending_url.c_str());
                v->pending_url.clear();
              }
              return S_OK;
            });
    bool is_private = Find(id) != nullptr && Find(id)->is_private;
    ComPtr<ICoreWebView2Environment10> env10;
    if (is_private && SUCCEEDED(env->QueryInterface(IID_PPV_ARGS(&env10)))) {
      // Private tab: an InPrivate profile, nothing kept after it closes.
      ComPtr<ICoreWebView2ControllerOptions> options;
      if (SUCCEEDED(env10->CreateCoreWebView2ControllerOptions(&options))) {
        options->put_IsInPrivateModeEnabled(TRUE);
        env10->CreateCoreWebView2ControllerWithOptions(parent_, options.Get(),
                                                       handler.Get());
        return;
      }
    }
    env->CreateCoreWebView2Controller(parent_, handler.Get());
  });
}

void WebViewHost::Apply(View* v) {
  if (!v->controller) return;
  v->controller->put_Bounds(v->bounds);
  v->controller->put_IsVisible(v->visible ? TRUE : FALSE);
  v->controller->put_ZoomFactor(v->zoom);
}

void WebViewHost::SendState(View* v) {
  EncodableMap state{{EncodableValue("id"), EncodableValue(v->id)}};
  if (v->web) {
    LPWSTR uri = nullptr;
    LPWSTR title = nullptr;
    BOOL back = FALSE, forward = FALSE;
    v->web->get_Source(&uri);
    v->web->get_DocumentTitle(&title);
    v->web->get_CanGoBack(&back);
    v->web->get_CanGoForward(&forward);
    state[EncodableValue("url")] = EncodableValue(Take(uri));
    state[EncodableValue("title")] = EncodableValue(Take(title));
    state[EncodableValue("canGoBack")] = EncodableValue(back == TRUE);
    state[EncodableValue("canGoForward")] = EncodableValue(forward == TRUE);
  }
  state[EncodableValue("loading")] = EncodableValue(v->loading);
  state[EncodableValue("progress")] = EncodableValue(v->loading ? 0.3 : 1.0);
  if (!v->error.empty()) {
    state[EncodableValue("error")] = EncodableValue(v->error);
  }
  Send("state", std::move(state));
}

void WebViewHost::Wire(View* v) {
  const int id = v->id;
  ComPtr<ICoreWebView2Settings> settings;
  if (SUCCEEDED(v->web->get_Settings(&settings))) {
    settings->put_IsStatusBarEnabled(FALSE);
    settings->put_AreDevToolsEnabled(FALSE);
    settings->put_IsZoomControlEnabled(TRUE);
  }
  EventRegistrationToken token;

  // Only web pages load here; other schemes go to the app, which asks the
  // user (mailto:, tel:, app links). javascript:/file: are refused.
  v->web->add_NavigationStarting(
      Callback<ICoreWebView2NavigationStartingEventHandler>(
          [this, id](ICoreWebView2*,
                     ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
            View* v = Find(id);
            if (v == nullptr) return S_OK;
            LPWSTR uri = nullptr;
            args->get_Uri(&uri);
            std::string url = Take(uri);
            std::string scheme = Scheme(url);
            if (scheme != "http" && scheme != "https" && scheme != "about" &&
                scheme != "data" && scheme != "blob") {
              args->put_Cancel(TRUE);
              if (scheme != "javascript" && scheme != "file") {
                Send("external", {{EncodableValue("id"), EncodableValue(id)},
                                  {EncodableValue("url"), EncodableValue(url)}});
              }
              return S_OK;
            }
            v->loading = true;
            v->error.clear();
            SendState(v);
            return S_OK;
          })
          .Get(),
      &token);

  v->web->add_NavigationCompleted(
      Callback<ICoreWebView2NavigationCompletedEventHandler>(
          [this, id](ICoreWebView2*,
                     ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
            View* v = Find(id);
            if (v == nullptr) return S_OK;
            v->loading = false;
            BOOL ok = TRUE;
            args->get_IsSuccess(&ok);
            if (!ok) {
              COREWEBVIEW2_WEB_ERROR_STATUS status;
              args->get_WebErrorStatus(&status);
              switch (status) {
                case COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED:
                  break;
                case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_COMMON_NAME_IS_INCORRECT:
                case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_EXPIRED:
                case COREWEBVIEW2_WEB_ERROR_STATUS_CLIENT_CERTIFICATE_CONTAINS_ERRORS:
                case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_REVOKED:
                case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_IS_INVALID:
                  v->error =
                      "This site's secure connection could not be verified, "
                      "so it was not opened.";
                  break;
                default:
                  v->error = "The page could not be opened.";
              }
            }
            SendState(v);
            return S_OK;
          })
          .Get(),
      &token);

  auto state = [this, id]() {
    if (View* v = Find(id)) SendState(v);
  };
  v->web->add_SourceChanged(
      Callback<ICoreWebView2SourceChangedEventHandler>(
          [state](ICoreWebView2*, ICoreWebView2SourceChangedEventArgs*)
              -> HRESULT {
            state();
            return S_OK;
          })
          .Get(),
      &token);
  v->web->add_DocumentTitleChanged(
      Callback<ICoreWebView2DocumentTitleChangedEventHandler>(
          [state](ICoreWebView2*, IUnknown*) -> HRESULT {
            state();
            return S_OK;
          })
          .Get(),
      &token);
  v->web->add_HistoryChanged(
      Callback<ICoreWebView2HistoryChangedEventHandler>(
          [state](ICoreWebView2*, IUnknown*) -> HRESULT {
            state();
            return S_OK;
          })
          .Get(),
      &token);

  // Pop-ups and target=_blank open as a new THEapp tab.
  v->web->add_NewWindowRequested(
      Callback<ICoreWebView2NewWindowRequestedEventHandler>(
          [this, id](ICoreWebView2*,
                     ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
            LPWSTR uri = nullptr;
            args->get_Uri(&uri);
            args->put_Handled(TRUE);
            Send("newWindow", {{EncodableValue("id"), EncodableValue(id)},
                               {EncodableValue("url"), EncodableValue(Take(uri))}});
            return S_OK;
          })
          .Get(),
      &token);

  // Camera, microphone, location…: the app asks the user (per site).
  v->web->add_PermissionRequested(
      Callback<ICoreWebView2PermissionRequestedEventHandler>(
          [this, id](ICoreWebView2*,
                     ICoreWebView2PermissionRequestedEventArgs* args) -> HRESULT {
            COREWEBVIEW2_PERMISSION_KIND kind;
            args->get_PermissionKind(&kind);
            const char* name = "this permission";
            switch (kind) {
              case COREWEBVIEW2_PERMISSION_KIND_CAMERA:
                name = "camera";
                break;
              case COREWEBVIEW2_PERMISSION_KIND_MICROPHONE:
                name = "microphone";
                break;
              case COREWEBVIEW2_PERMISSION_KIND_GEOLOCATION:
                name = "location";
                break;
              case COREWEBVIEW2_PERMISSION_KIND_NOTIFICATIONS:
                name = "notifications";
                break;
              case COREWEBVIEW2_PERMISSION_KIND_CLIPBOARD_READ:
                name = "clipboard";
                break;
              default:
                break;
            }
            LPWSTR uri = nullptr;
            args->get_Uri(&uri);
            std::string host = Host(Take(uri));
            ComPtr<ICoreWebView2Deferral> deferral;
            args->GetDeferral(&deferral);
            ComPtr<ICoreWebView2PermissionRequestedEventArgs> keep = args;
            auto answer = std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
                [keep, deferral](const EncodableValue* v) {
                  bool allow = v != nullptr && std::holds_alternative<bool>(*v) &&
                               std::get<bool>(*v);
                  keep->put_State(allow ? COREWEBVIEW2_PERMISSION_STATE_ALLOW
                                        : COREWEBVIEW2_PERMISSION_STATE_DENY);
                  deferral->Complete();
                },
                [keep, deferral](const std::string&, const std::string&,
                                 const EncodableValue*) {
                  keep->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
                  deferral->Complete();
                },
                [keep, deferral]() {
                  keep->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
                  deferral->Complete();
                });
            channel_->InvokeMethod(
                "permission",
                std::make_unique<EncodableValue>(EncodableMap{
                    {EncodableValue("id"), EncodableValue(id)},
                    {EncodableValue("host"), EncodableValue(host)},
                    {EncodableValue("kind"), EncodableValue(std::string(name))}}),
                std::move(answer));
            return S_OK;
          })
          .Get(),
      &token);

  // Downloads go to Downloads\THEapp Downloads, with progress for the app.
  ComPtr<ICoreWebView2_4> web4;
  if (SUCCEEDED(v->web.As(&web4))) {
    web4->add_DownloadStarting(
        Callback<ICoreWebView2DownloadStartingEventHandler>(
            [this, id](ICoreWebView2*,
                       ICoreWebView2DownloadStartingEventArgs* args) -> HRESULT {
              View* v = Find(id);
              if (v == nullptr) return S_OK;
              ComPtr<ICoreWebView2DownloadOperation> op;
              if (FAILED(args->get_DownloadOperation(&op))) return S_OK;
              LPWSTR suggested = nullptr;
              args->get_ResultFilePath(&suggested);
              std::wstring original = suggested ? suggested : L"download";
              CoTaskMemFree(suggested);
              std::wstring name = original.substr(original.find_last_of(L"\\/") + 1);
              std::wstring folder =
                  KnownFolder(FOLDERID_Downloads) + L"\\THEapp Downloads";
              CreateDirectoryW(folder.c_str(), nullptr);
              std::wstring target = folder + L"\\" + name;
              for (int n = 2; GetFileAttributesW(target.c_str()) !=
                              INVALID_FILE_ATTRIBUTES;
                   n++) {
                auto dot = name.find_last_of(L'.');
                std::wstring base = dot == std::wstring::npos ? name : name.substr(0, dot);
                std::wstring ext = dot == std::wstring::npos ? L"" : name.substr(dot);
                target = folder + L"\\" + base + L" (" + std::to_wstring(n) + L")" + ext;
              }
              args->put_ResultFilePath(target.c_str());
              args->put_Handled(TRUE);  // no Edge download bubble
              auto d = std::make_shared<Download>();
              d->id = std::to_string(id) + "-" + std::to_string(++v->download_counter);
              LPWSTR uri = nullptr;
              op->get_Uri(&uri);
              d->url = Take(uri);
              d->fileName = Utf8(target.substr(target.find_last_of(L'\\') + 1).c_str());
              d->path = target;
              auto report = [this, id, d](double progress, bool done,
                                              const std::string& error) {
                EncodableMap m{
                    {EncodableValue("id"), EncodableValue(id)},
                    {EncodableValue("downloadId"), EncodableValue(d->id)},
                    {EncodableValue("url"), EncodableValue(d->url)},
                    {EncodableValue("fileName"), EncodableValue(d->fileName)},
                    {EncodableValue("progress"), EncodableValue(progress)},
                    {EncodableValue("done"), EncodableValue(done)}};
                if (done) m[EncodableValue("path")] = EncodableValue(Utf8(d->path.c_str()));
                if (!error.empty()) m[EncodableValue("error")] = EncodableValue(error);
                Send("download", std::move(m));
              };
              EventRegistrationToken t;
              op->add_BytesReceivedChanged(
                  Callback<ICoreWebView2BytesReceivedChangedEventHandler>(
                      [report](ICoreWebView2DownloadOperation* o, IUnknown*) -> HRESULT {
                        INT64 got = 0, total = 0;
                        o->get_BytesReceived(&got);
                        o->get_TotalBytesToReceive(&total);
                        report(total > 0 ? (double)got / (double)total : 0, false, "");
                        return S_OK;
                      })
                      .Get(),
                  &t);
              op->add_StateChanged(
                  Callback<ICoreWebView2StateChangedEventHandler>(
                      [report](ICoreWebView2DownloadOperation* o, IUnknown*) -> HRESULT {
                        COREWEBVIEW2_DOWNLOAD_STATE s;
                        o->get_State(&s);
                        if (s == COREWEBVIEW2_DOWNLOAD_STATE_COMPLETED) {
                          report(1, true, "");
                        } else if (s == COREWEBVIEW2_DOWNLOAD_STATE_INTERRUPTED) {
                          report(0, false, "The download was interrupted.");
                        }
                        return S_OK;
                      })
                      .Get(),
                  &t);
              report(0, false, "");
              return S_OK;
            })
            .Get(),
        &token);
  }
}

void WebViewHost::Handle(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (args == nullptr) {
    result->Error("bad_args", "Arguments must be a map.");
    return;
  }
  const std::string& m = call.method_name();
  const int id = IntArg(*args, "id");
  if (m == "create") {
    Create(id, BoolArg(*args, "private"));
    result->Success();
    return;
  }
  View* v = Find(id);
  if (v == nullptr) {
    result->Success();
    return;
  }
  if (m == "dispose") {
    if (v->controller) v->controller->Close();
    views_.erase(id);
    result->Success();
  } else if (m == "bounds") {
    // Logical pixels from Dart, scaled to the window's physical pixels.
    double scale = DoubleArg(*args, "scale", 1.0);
    v->bounds = RECT{(LONG)(DoubleArg(*args, "x", 0) * scale),
                     (LONG)(DoubleArg(*args, "y", 0) * scale),
                     (LONG)((DoubleArg(*args, "x", 0) + DoubleArg(*args, "w", 0)) * scale),
                     (LONG)((DoubleArg(*args, "y", 0) + DoubleArg(*args, "h", 0)) * scale)};
    v->visible = BoolArg(*args, "visible");
    Apply(v);
    result->Success();
  } else if (m == "load") {
    std::string url = StringArg(*args, "url");
    std::string scheme = Scheme(url);
    if (scheme != "http" && scheme != "https") {
      result->Error("bad_url", "Only web addresses can be opened.");
      return;
    }
    v->error.clear();
    if (v->web) {
      v->web->Navigate(Wide(url).c_str());
    } else {
      v->pending_url = Wide(url);
    }
    result->Success();
  } else if (m == "back") {
    if (v->web) v->web->GoBack();
    result->Success();
  } else if (m == "forward") {
    if (v->web) v->web->GoForward();
    result->Success();
  } else if (m == "reload") {
    v->error.clear();
    if (v->web) v->web->Reload();
    result->Success();
  } else if (m == "stop") {
    if (v->web) v->web->Stop();
    result->Success();
  } else if (m == "zoom") {
    v->zoom = std::clamp(DoubleArg(*args, "factor", 1.0), 0.25, 5.0);
    Apply(v);
    result->Success();
  } else if (m == "evaluate") {
    // Only the app's fixed read-only scripts; never code from a page. The
    // result comes back as JSON (Dart decodes it).
    std::string script = StringArg(*args, "script");
    if (!v->web || (script != "window.getSelection().toString()" &&
                    script != "document.body.innerText" &&
                    script.rfind("window.find(", 0) != 0)) {
      result->Success(EncodableValue(std::string("\"\"")));
      return;
    }
    auto shared = std::shared_ptr<flutter::MethodResult<EncodableValue>>(
        std::move(result));
    v->web->ExecuteScript(
        Wide(script).c_str(),
        Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
            [shared](HRESULT hr, LPCWSTR json) -> HRESULT {
              shared->Success(EncodableValue(
                  SUCCEEDED(hr) && json ? Utf8(json) : std::string("\"\"")));
              return S_OK;
            })
            .Get());
  } else if (m == "clearData") {
    ComPtr<ICoreWebView2_13> web13;
    ComPtr<ICoreWebView2Profile> profile;
    ComPtr<ICoreWebView2Profile2> profile2;
    if (v->web && SUCCEEDED(v->web.As(&web13)) &&
        SUCCEEDED(web13->get_Profile(&profile)) &&
        SUCCEEDED(profile.As(&profile2))) {
      auto shared = std::shared_ptr<flutter::MethodResult<EncodableValue>>(
          std::move(result));
      profile2->ClearBrowsingDataAll(
          Callback<ICoreWebView2ClearBrowsingDataCompletedHandler>(
              [shared](HRESULT) -> HRESULT {
                shared->Success();
                return S_OK;
              })
              .Get());
    } else {
      result->Error("unsupported", "This WebView2 Runtime cannot clear data.");
    }
  } else {
    result->NotImplemented();
  }
}
