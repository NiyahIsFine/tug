#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  host_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "dev.tug/windows_host",
      &flutter::StandardMethodCodec::GetInstance());
  host_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "ready") {
          host_ready_ = true;
          for (const auto& request : pending_launches_) {
            host_channel_->InvokeMethod("launch", std::make_unique<flutter::EncodableValue>(request));
          }
          pending_launches_.clear();
          Show();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  host_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
    case WM_COPYDATA: {
      const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (data == nullptr || data->dwData != 0x545547 || data->lpData == nullptr ||
          data->cbData == 0 || data->cbData > 256) return FALSE;
      const auto* bytes = static_cast<const char*>(data->lpData);
      if (bytes[data->cbData - 1] != '\0') return FALSE;
      const std::string request(bytes, data->cbData - 1);
      if (request.size() > 256) return FALSE;
      if (host_channel_ && host_ready_) {
        host_channel_->InvokeMethod("launch", std::make_unique<flutter::EncodableValue>(request));
      } else if (pending_launches_.size() < 8) {
        pending_launches_.push_back(request);
      }
      return TRUE;
    }
    case WM_ACTIVATE:
      if (host_channel_ && host_ready_) host_channel_->InvokeMethod("focus", nullptr);
      break;
    case WM_GETMINMAXINFO: {
      const auto limits = reinterpret_cast<MINMAXINFO*>(lparam);
      const auto dpi = GetDpiForWindow(hwnd);
      limits->ptMinTrackSize.x = MulDiv(540, dpi, 96);
      limits->ptMinTrackSize.y = MulDiv(480, dpi, 96);
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
