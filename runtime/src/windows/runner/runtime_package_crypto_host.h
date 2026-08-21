#ifndef RUNNER_RUNTIME_PACKAGE_CRYPTO_HOST_H_
#define RUNNER_RUNTIME_PACKAGE_CRYPTO_HOST_H_

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace playmesh::runtime_crypto {

inline constexpr char kChannelName[] = "playmesh/runtime_key";
inline constexpr char kDecryptMethodName[] = "decryptRuntimePackage";
inline constexpr wchar_t kRuntimeCryptoDllName[] =
    L"playmesh-runtime-crypto.dll";

struct DecryptResult {
  bool success = false;
  std::vector<std::uint8_t> plaintext;
  std::string error_code;
  std::string error_message;
};

// Reads only the fixed game.pmp next to this Runtime's flutter_assets and asks
// the Runtime-private Go DLL to authenticate and decrypt it. No caller-provided
// path or ciphertext is accepted by this public host.
DecryptResult DecryptBundledPackage(std::string_view key_id);

}  // namespace playmesh::runtime_crypto

#endif  // RUNNER_RUNTIME_PACKAGE_CRYPTO_HOST_H_
