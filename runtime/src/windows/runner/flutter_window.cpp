#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "runtime_package_crypto_host.h"
#include "speech_recognition_host.h"

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

  runtime_crypto_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          playmesh::runtime_crypto::kChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  runtime_crypto_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<
             flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() !=
            playmesh::runtime_crypto::kDecryptMethodName) {
          result->NotImplemented();
          return;
        }

        const flutter::EncodableMap* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr || arguments->size() != 1) {
          result->Error(
              "invalid_runtime_crypto_request",
              "decryptRuntimePackage requires exactly one keyId argument.");
          return;
        }
        const auto key_id_entry =
            arguments->find(flutter::EncodableValue("keyId"));
        if (key_id_entry == arguments->end()) {
          result->Error(
              "invalid_runtime_crypto_request",
              "decryptRuntimePackage requires a keyId string argument.");
          return;
        }
        const std::string* key_id =
            std::get_if<std::string>(&key_id_entry->second);
        if (key_id == nullptr || key_id->empty()) {
          result->Error(
              "invalid_runtime_crypto_request",
              "decryptRuntimePackage requires a non-empty keyId string.");
          return;
        }

        playmesh::runtime_crypto::DecryptResult decrypt_result =
            playmesh::runtime_crypto::DecryptBundledPackage(*key_id);
        if (!decrypt_result.success) {
          result->Error(decrypt_result.error_code,
                        decrypt_result.error_message);
          return;
        }
        result->Success(
            flutter::EncodableValue(std::move(decrypt_result.plaintext)));
      });
  speech_recognition_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          playmesh::speech_recognition::kChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  speech_recognition_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<
             flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() !=
            playmesh::speech_recognition::kDiagnoseInitializationFailureMethod) {
          result->NotImplemented();
          return;
        }
        const auto availability =
            playmesh::speech_recognition::DiagnoseInitializationFailure();
        flutter::EncodableMap detail;
        detail[flutter::EncodableValue("stage")] =
            flutter::EncodableValue(availability.stage);
        detail[flutter::EncodableValue("diagnostic")] =
            flutter::EncodableValue(availability.diagnostic);
        flutter::EncodableMap response;
        response[flutter::EncodableValue("available")] =
            flutter::EncodableValue(availability.available);
        response[flutter::EncodableValue("code")] =
            flutter::EncodableValue(availability.code);
        response[flutter::EncodableValue("message")] =
            flutter::EncodableValue(availability.message);
        response[flutter::EncodableValue("detail")] =
            flutter::EncodableValue(detail);
        result->Success(flutter::EncodableValue(response));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  if (speech_recognition_channel_) {
    speech_recognition_channel_->SetMethodCallHandler(nullptr);
    speech_recognition_channel_.reset();
  }
  if (runtime_crypto_channel_) {
    runtime_crypto_channel_->SetMethodCallHandler(nullptr);
    runtime_crypto_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_.reset();
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
