#include "runtime_package_crypto_host.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace playmesh::runtime_crypto {
namespace {

constexpr std::uint64_t kMaximumEncryptedPackageBytes =
    (std::uint64_t{512} << 20) + 4 + 12 + 16;
constexpr std::uint64_t kMinimumEncryptedPackageBytes = 4 + 12 + 16 + 1;
constexpr std::size_t kMaximumKeyIdBytes = 1024;
constexpr std::size_t kMaximumNativeErrorBytes = 4096;
constexpr wchar_t kBundledPackageRelativePath[] =
    L"data\\flutter_assets\\assets\\runtime\\game.pmp";

using DecryptFunction = std::int32_t(__cdecl *)(
    const std::uint8_t* envelope, std::uint64_t envelope_len,
    const char* key_id, std::uint64_t key_id_len, std::uint8_t** out_data,
    std::uint64_t* out_len, char** out_error, std::uint64_t* out_error_len);
using FreeFunction = void(__cdecl *)(void* value, std::uint64_t length);

DecryptResult Failure(std::string code, std::string message) {
  DecryptResult result;
  result.error_code = std::move(code);
  result.error_message = std::move(message);
  return result;
}

class FileHandle final {
 public:
  explicit FileHandle(HANDLE value) : value_(value) {}
  ~FileHandle() {
    if (value_ != INVALID_HANDLE_VALUE) {
      CloseHandle(value_);
    }
  }

  FileHandle(const FileHandle&) = delete;
  FileHandle& operator=(const FileHandle&) = delete;
  HANDLE get() const { return value_; }

 private:
  HANDLE value_ = INVALID_HANDLE_VALUE;
};

bool GetRuntimeDirectory(std::wstring* directory) {
  if (directory == nullptr) {
    return false;
  }
  std::array<wchar_t, 32768> module_path{};
  const DWORD length = GetModuleFileNameW(
      nullptr, module_path.data(), static_cast<DWORD>(module_path.size()));
  if (length == 0 || length >= module_path.size()) {
    return false;
  }
  const std::wstring_view path(module_path.data(), length);
  const std::size_t separator = path.find_last_of(L"\\/");
  if (separator == std::wstring_view::npos || separator == 0) {
    return false;
  }
  directory->assign(path.substr(0, separator));
  return true;
}

std::wstring JoinRuntimePath(std::wstring_view directory,
                             std::wstring_view relative_path) {
  std::wstring result(directory);
  result.push_back(L'\\');
  result.append(relative_path);
  return result;
}

bool ReadBundledEnvelope(const std::wstring& runtime_directory,
                         std::vector<std::uint8_t>* envelope,
                         std::string* error_message) {
  if (envelope == nullptr || error_message == nullptr) {
    return false;
  }
  const std::wstring package_path =
      JoinRuntimePath(runtime_directory, kBundledPackageRelativePath);
  FileHandle file(CreateFileW(
      package_path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
      nullptr));
  if (file.get() == INVALID_HANDLE_VALUE) {
    *error_message = "The bundled Runtime game package could not be opened.";
    return false;
  }

  BY_HANDLE_FILE_INFORMATION information{};
  if (!GetFileInformationByHandle(file.get(), &information) ||
      (information.dwFileAttributes &
       (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0) {
    *error_message = "The bundled Runtime game package is not a regular file.";
    return false;
  }
  LARGE_INTEGER file_size{};
  if (!GetFileSizeEx(file.get(), &file_size) || file_size.QuadPart < 0) {
    *error_message = "The bundled Runtime game package size is unavailable.";
    return false;
  }
  const std::uint64_t size = static_cast<std::uint64_t>(file_size.QuadPart);
  if (size < kMinimumEncryptedPackageBytes ||
      size > kMaximumEncryptedPackageBytes ||
      size > static_cast<std::uint64_t>(
                 std::numeric_limits<std::size_t>::max())) {
    *error_message = "The bundled Runtime game package size is invalid.";
    return false;
  }

  envelope->assign(static_cast<std::size_t>(size), 0);
  std::size_t offset = 0;
  while (offset < envelope->size()) {
    const DWORD requested = static_cast<DWORD>(std::min<std::size_t>(
        envelope->size() - offset, std::size_t{1} << 20));
    DWORD received = 0;
    if (!ReadFile(file.get(), envelope->data() + offset, requested, &received,
                  nullptr) ||
        received == 0) {
      SecureZeroMemory(envelope->data(), envelope->size());
      envelope->clear();
      *error_message = "The bundled Runtime game package could not be read.";
      return false;
    }
    offset += received;
  }
  return true;
}

class RuntimeCryptoDll final {
 public:
  RuntimeCryptoDll() {
    std::wstring runtime_directory;
    if (!GetRuntimeDirectory(&runtime_directory)) {
      error_ = "The Runtime installation directory is unavailable.";
      return;
    }
    const std::wstring dll_path =
        JoinRuntimePath(runtime_directory, kRuntimeCryptoDllName);
    module_ = LoadLibraryExW(
        dll_path.c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (module_ == nullptr) {
      error_ = "The private Runtime crypto module could not be loaded.";
      return;
    }
    decrypt_ = reinterpret_cast<DecryptFunction>(
        GetProcAddress(module_, "PlaymeshRuntimeDecrypt"));
    free_ = reinterpret_cast<FreeFunction>(
        GetProcAddress(module_, "PlaymeshRuntimeFree"));
    if (decrypt_ == nullptr || free_ == nullptr) {
      error_ = "The private Runtime crypto module ABI is incompatible.";
      decrypt_ = nullptr;
      free_ = nullptr;
    }
  }

  RuntimeCryptoDll(const RuntimeCryptoDll&) = delete;
  RuntimeCryptoDll& operator=(const RuntimeCryptoDll&) = delete;

  bool available() const { return decrypt_ != nullptr && free_ != nullptr; }
  DecryptFunction decrypt() const { return decrypt_; }
  FreeFunction release() const { return free_; }
  const std::string& error() const { return error_; }

 private:
  // Go c-shared runtimes are process-scoped. Deliberately retain the module
  // until process termination instead of calling FreeLibrary after a request.
  HMODULE module_ = nullptr;
  DecryptFunction decrypt_ = nullptr;
  FreeFunction free_ = nullptr;
  std::string error_;
};

RuntimeCryptoDll& GetRuntimeCryptoDll() {
  static RuntimeCryptoDll instance;
  return instance;
}

std::string ErrorCodeForStatus(std::int32_t status) {
  switch (status) {
    case 1:
      return "invalid_runtime_crypto_request";
    case 2:
      return "runtime_package_key_rejected";
    case 3:
      return "runtime_package_authentication_failed";
    case 4:
    default:
      return "runtime_crypto_unavailable";
  }
}

std::string ErrorMessageForStatus(std::int32_t status) {
  switch (status) {
    case 1:
      return "The Runtime crypto request is invalid.";
    case 2:
      return "The bundled game package targets a different Runtime key.";
    case 3:
      return "The bundled game package failed authentication.";
    case 4:
    default:
      return "The private Runtime crypto module could not decrypt the game package.";
  }
}

}  // namespace

DecryptResult DecryptBundledPackage(std::string_view key_id) {
  if (key_id.empty() || key_id.size() > kMaximumKeyIdBytes) {
    return Failure("invalid_runtime_crypto_request",
                   "The Runtime package key identifier is invalid.");
  }

  std::wstring runtime_directory;
  if (!GetRuntimeDirectory(&runtime_directory)) {
    return Failure("runtime_crypto_unavailable",
                   "The Runtime installation directory is unavailable.");
  }
  RuntimeCryptoDll& dll = GetRuntimeCryptoDll();
  if (!dll.available()) {
    return Failure("runtime_crypto_unavailable", dll.error());
  }

  std::vector<std::uint8_t> envelope;
  std::string read_error;
  if (!ReadBundledEnvelope(runtime_directory, &envelope, &read_error)) {
    return Failure("runtime_package_read_failed", std::move(read_error));
  }

  std::uint8_t* output = nullptr;
  std::uint64_t output_length = 0;
  char* native_error = nullptr;
  std::uint64_t native_error_length = 0;
  const std::int32_t status = dll.decrypt()(
      envelope.data(), static_cast<std::uint64_t>(envelope.size()),
      key_id.data(), static_cast<std::uint64_t>(key_id.size()), &output,
      &output_length, &native_error, &native_error_length);
  SecureZeroMemory(envelope.data(), envelope.size());
  envelope.clear();

  const bool success_contract =
      status == 0 && output != nullptr && output_length != 0 &&
      output_length <= (std::uint64_t{512} << 20) && native_error == nullptr &&
      native_error_length == 0;
  const bool failure_contract =
      status != 0 && output == nullptr && output_length == 0 &&
      ((native_error == nullptr && native_error_length == 0) ||
       (native_error != nullptr &&
        native_error_length <= kMaximumNativeErrorBytes));
  if (!success_contract && !failure_contract) {
    if (output != nullptr) {
      if (output_length <= (std::uint64_t{512} << 20)) {
        SecureZeroMemory(output, static_cast<std::size_t>(output_length));
      }
      dll.release()(output, output_length);
    }
    if (native_error != nullptr) {
      dll.release()(native_error, native_error_length);
    }
    return Failure("runtime_crypto_abi_violation",
                   "The private Runtime crypto module returned an invalid result.");
  }

  if (status != 0) {
    if (native_error != nullptr) {
      // The private module's diagnostic is intentionally not returned across
      // the Flutter boundary. It is bounded and freed here only.
      dll.release()(native_error, native_error_length);
    }
    return Failure(ErrorCodeForStatus(status), ErrorMessageForStatus(status));
  }

  DecryptResult result;
  result.success = true;
  result.plaintext.assign(output, output + output_length);
  SecureZeroMemory(output, static_cast<std::size_t>(output_length));
  dll.release()(output, output_length);
  return result;
}

}  // namespace playmesh::runtime_crypto
