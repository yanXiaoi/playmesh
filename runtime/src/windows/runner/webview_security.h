#pragma once

namespace playmesh_runtime {

// Removes WebView2 debugger environment overrides inherited by this process.
// Returns false when Windows cannot guarantee that every override is absent.
bool DisableWebView2DebugEnvironmentOverrides() noexcept;

}  // namespace playmesh_runtime
