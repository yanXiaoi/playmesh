#include "speech_recognition_host.h"

#include <sapi.h>
#include <windows.h>
#include <wrl/client.h>

#include <cstdint>
#include <iomanip>
#include <sstream>
#include <string>

namespace playmesh::speech_recognition {
namespace {

std::string FormatHresult(HRESULT value) {
  std::ostringstream output;
  output << "0x" << std::uppercase << std::hex << std::setw(8)
         << std::setfill('0') << static_cast<std::uint32_t>(value);
  return output.str();
}

Diagnosis Failure(const char* code, const char* message, const char* stage,
                  HRESULT diagnostic) {
  return Diagnosis{false, code, message, stage, FormatHresult(diagnostic)};
}

}  // namespace

Diagnosis DiagnoseInitializationFailure() {
  Microsoft::WRL::ComPtr<ISpRecognizer> recognizer;
  HRESULT result = ::CoCreateInstance(
      CLSID_SpInprocRecognizer, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(recognizer.GetAddressOf()));
  if (FAILED(result)) {
    return Failure("speech_recognizer_unavailable",
                   "系统未安装或未启用语音识别服务", "recognizer", result);
  }

  Microsoft::WRL::ComPtr<ISpAudio> audio;
  result = ::CoCreateInstance(CLSID_SpMMAudioIn, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(audio.GetAddressOf()));
  if (FAILED(result)) {
    return Failure("speech_audio_input_unavailable",
                   "系统语音识别无法访问默认录音设备", "audio_input", result);
  }

  result = recognizer->SetInput(audio.Get(), TRUE);
  if (FAILED(result)) {
    return Failure("speech_audio_input_unavailable",
                   "系统语音识别无法访问默认录音设备", "set_input", result);
  }

  Microsoft::WRL::ComPtr<ISpRecoContext> context;
  result = recognizer->CreateRecoContext(context.GetAddressOf());
  if (FAILED(result)) {
    return Failure("speech_engine_initialization_failed",
                   "系统语音识别引擎初始化失败", "recognition_context",
                   result);
  }

  Microsoft::WRL::ComPtr<ISpRecoGrammar> grammar;
  result = context->CreateGrammar(0, grammar.GetAddressOf());
  if (FAILED(result)) {
    return Failure("speech_engine_initialization_failed",
                   "系统语音识别引擎初始化失败", "recognition_grammar",
                   result);
  }

  result = grammar->LoadDictation(nullptr, SPLO_STATIC);
  if (FAILED(result)) {
    return Failure("speech_language_unavailable",
                   "系统没有可用的听写语言资源", "dictation", result);
  }

  return Diagnosis{true, "available", "系统语音识别服务可用", "ready",
                   FormatHresult(S_OK)};
}

}  // namespace playmesh::speech_recognition
