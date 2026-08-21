#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <string>
#include <string_view>
#include <vector>

#include "runtime_package_crypto_host.h"

namespace {

// Go crypto/rsa.EncryptOAEP interoperability vector: production SPKI, AES key
// 00..1f, and deterministic 32-byte OAEP seed a0..bf. The private Go DLL must
// unwrap this key and then authenticate the PME1 fixture below.
constexpr char kGoInteroperabilityKeyId[] =
    "win-rsa-oaep-sha256-v1:10SbA_plmguDhuFby9uK26FJKk1MlcRKTbpH8QQipFo:FAy-H"
    "GUJf4uosQx-90wO_7kXcCrk55Ao3oxu_RFclEnk0jJARPpZdiOVnUc4RRHb_go_7BWwVUVsV"
    "d2wE_z8tetpEBpi5XJeh95lxSpprKleOFFEieOKDCQYQyb4TIfK8Jj_6jgx9AKg9E2qAxITm"
    "N3C5EyvE9XU5eNV-x8vBA36w3rT1CcMIjAkRfUAoFhxHRF0hONMg8_UNVzAyNg8lWK9wvuen"
    "G-kavqYyg8xd62syx8XK2ExppcJ2FyFmRO0zS7p_gLzoFdSjZolQoUh97ZiacdcmIxpr2vra"
    "_8GPq0N7Psjye0ycCno6XPMawfYgSpDy0ZVQA_6HXz3rghV51JyYaQimW-GkiCTxTBwsaOx0"
    "g-lMJ5L2_Qq9stpwalcYwvO0i6iNkgmyOvp_SgIExAy7SZ00OibgN5l0C9Fu5anzbYU_pZQi"
    "bRIS3U4OhOeGu0MRXVVOednDVkgSLoh4aEB-ugGQN5xy97wEuo00_pFpfWUDt1MunOoBYU_r"
    "EZG";

const std::vector<std::uint8_t> kEncryptedFixture = {
    0x50, 0x4d, 0x45, 0x31, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46,
    0x47, 0x48, 0x49, 0x4a, 0x4b, 0xb2, 0xf2, 0xad, 0x27, 0x56, 0x50,
    0xe6, 0x7a, 0xa0, 0xa1, 0x64, 0x5e, 0xb6, 0x13, 0x7a, 0x35, 0x1d,
    0xa9, 0x25, 0x2f, 0x9a, 0x47, 0x7c, 0x42, 0x5a, 0x31, 0x2b, 0x86,
    0xe3, 0x7c, 0x9f, 0xf6, 0xee, 0x39, 0x86, 0x32, 0x62, 0x13, 0x2a,
    0x1f, 0x5f, 0xab, 0x32, 0xa2, 0xac, 0x4b, 0x3a, 0xc6, 0xe3, 0x88,
};

const std::vector<std::uint8_t> kClearFixture = {
    0x50, 0x4b, 0x03, 0x04, 0x70, 0x6c, 0x61, 0x79, 0x6d, 0x65, 0x73,
    0x68, 0x2d, 0x77, 0x69, 0x6e, 0x64, 0x6f, 0x77, 0x73, 0x2d, 0x72,
    0x73, 0x61, 0x2d, 0x76, 0x65, 0x63, 0x74, 0x6f, 0x72, 0x2d, 0x76,
    0x31,
};

class FileHandle final {
 public:
  explicit FileHandle(HANDLE value) : value_(value) {}
  ~FileHandle() {
    if (value_ != INVALID_HANDLE_VALUE) {
      CloseHandle(value_);
    }
  }
  HANDLE get() const { return value_; }

 private:
  HANDLE value_ = INVALID_HANDLE_VALUE;
};

bool Check(bool condition, std::string_view message) {
  if (!condition) {
    std::cerr << "FAILED: " << message << '\n';
  }
  return condition;
}

bool ModuleDirectory(std::wstring* directory) {
  std::array<wchar_t, 32768> path{};
  const DWORD length =
      GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (directory == nullptr || length == 0 || length >= path.size()) {
    return false;
  }
  const std::wstring_view value(path.data(), length);
  const std::size_t separator = value.find_last_of(L"\\/");
  if (separator == std::wstring_view::npos) {
    return false;
  }
  directory->assign(value.substr(0, separator));
  return true;
}

bool EnsureDirectory(const std::wstring& path) {
  return CreateDirectoryW(path.c_str(), nullptr) != FALSE ||
         GetLastError() == ERROR_ALREADY_EXISTS;
}

bool WriteFixture(const std::vector<std::uint8_t>& data,
                  std::wstring* package_path) {
  std::wstring root;
  if (package_path == nullptr || !ModuleDirectory(&root)) {
    return false;
  }
  const std::array<std::wstring_view, 4> segments = {
      L"data", L"flutter_assets", L"assets", L"runtime"};
  for (const std::wstring_view segment : segments) {
    root.push_back(L'\\');
    root.append(segment);
    if (!EnsureDirectory(root)) {
      return false;
    }
  }
  *package_path = root + L"\\game.pmp";
  FileHandle file(CreateFileW(package_path->c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (file.get() == INVALID_HANDLE_VALUE) {
    return false;
  }
  DWORD written = 0;
  return WriteFile(file.get(), data.data(), static_cast<DWORD>(data.size()),
                   &written, nullptr) != FALSE &&
         written == static_cast<DWORD>(data.size()) &&
         FlushFileBuffers(file.get()) != FALSE;
}

}  // namespace

int main(int argument_count, char** arguments) {
  if (argument_count == 3 &&
      std::string_view(arguments[1]) == "--bundled-key-id") {
    playmesh::runtime_crypto::DecryptResult bundled =
        playmesh::runtime_crypto::DecryptBundledPackage(arguments[2]);
    const bool is_zip =
        bundled.plaintext.size() >= 4 && bundled.plaintext[0] == 0x50 &&
        bundled.plaintext[1] == 0x4b && bundled.plaintext[2] == 0x03 &&
        bundled.plaintext[3] == 0x04;
    const bool passed =
        Check(bundled.success, "the installed Runtime package did not decrypt") &&
        Check(is_zip, "the installed Runtime package is not a clear ZIP");
    if (!bundled.plaintext.empty()) {
      SecureZeroMemory(bundled.plaintext.data(), bundled.plaintext.size());
    }
    if (!passed) {
      return 1;
    }
    std::cout << "Installed Windows Runtime package decryption passed.\n";
    return 0;
  }
  if (argument_count != 1) {
    std::cerr << "usage: playmesh_runtime_crypto_host_test "
                 "[--bundled-key-id KEY_ID]\n";
    return 2;
  }

  bool passed = true;
  std::wstring package_path;
  passed &= Check(WriteFixture(kEncryptedFixture, &package_path),
                  "could not stage the fixed PME1 package fixture");
  if (!passed) {
    return 1;
  }

  playmesh::runtime_crypto::DecryptResult result =
      playmesh::runtime_crypto::DecryptBundledPackage(kGoInteroperabilityKeyId);
  passed &= Check(result.success,
                  "the private Go DLL rejected the Go RSA/PME1 vector");
  passed &= Check(result.plaintext == kClearFixture,
                  "the private Go DLL returned the wrong clear package");
  if (!result.plaintext.empty()) {
    SecureZeroMemory(result.plaintext.data(), result.plaintext.size());
  }

  result = playmesh::runtime_crypto::DecryptBundledPackage(
      "win-rsa-oaep-sha256-v1:invalid");
  passed &= Check(!result.success &&
                      result.error_code == "runtime_package_key_rejected",
                  "an invalid RSA key identifier was not rejected");

  std::vector<std::uint8_t> tampered = kEncryptedFixture;
  tampered.back() ^= 0x01;
  passed &= Check(WriteFixture(tampered, &package_path),
                  "could not stage the tampered PME1 fixture");
  result = playmesh::runtime_crypto::DecryptBundledPackage(
      kGoInteroperabilityKeyId);
  passed &= Check(!result.success &&
                      result.error_code ==
                          "runtime_package_authentication_failed",
                  "a tampered PME1 authentication tag was not rejected");
  SecureZeroMemory(tampered.data(), tampered.size());

  DeleteFileW(package_path.c_str());
  if (!passed) {
    return 1;
  }
  std::cout << "Windows Runtime private Go crypto bridge tests passed.\n";
  return 0;
}
