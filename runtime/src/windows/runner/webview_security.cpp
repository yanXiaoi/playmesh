#include "webview_security.h"

#include <windows.h>

namespace playmesh_runtime {
namespace {

constexpr const wchar_t* kWebView2DebugEnvironmentOverrides[] = {
    L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS",
    L"WEBVIEW2_WAIT_FOR_SCRIPT_DEBUGGER",
    L"WEBVIEW2_PIPE_FOR_SCRIPT_DEBUGGER",
};

bool RemoveEnvironmentVariable(const wchar_t* name) noexcept {
  ::SetLastError(ERROR_SUCCESS);
  if (!::SetEnvironmentVariableW(name, nullptr) &&
      ::GetLastError() != ERROR_ENVVAR_NOT_FOUND) {
    return false;
  }

  // Verify absence instead of assuming that a successful mutation produced
  // the requested process environment. An empty-but-present debugger variable
  // must not be accepted as equivalent to an absent one.
  ::SetLastError(ERROR_SUCCESS);
  const DWORD length = ::GetEnvironmentVariableW(name, nullptr, 0);
  return length == 0 && ::GetLastError() == ERROR_ENVVAR_NOT_FOUND;
}

}  // namespace

bool DisableWebView2DebugEnvironmentOverrides() noexcept {
  for (const wchar_t* name : kWebView2DebugEnvironmentOverrides) {
    if (!RemoveEnvironmentVariable(name)) {
      return false;
    }
  }
  return true;
}

}  // namespace playmesh_runtime
