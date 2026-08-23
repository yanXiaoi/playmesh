cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

if(NOT DEFINED PLAYMESH_RUNTIME_PRIVATE_GO_ROOT OR
   PLAYMESH_RUNTIME_PRIVATE_GO_ROOT STREQUAL "")
  message(FATAL_ERROR
    "PLAYMESH_RUNTIME_PRIVATE_GO_ROOT must name this build invocation's private Windows Go staging tree.")
endif()
if(NOT IS_ABSOLUTE "${PLAYMESH_RUNTIME_PRIVATE_GO_ROOT}")
  message(FATAL_ERROR "PLAYMESH_RUNTIME_PRIVATE_GO_ROOT must be absolute.")
endif()
get_filename_component(PLAYMESH_RUNTIME_PRIVATE_GO_ROOT
  "${PLAYMESH_RUNTIME_PRIVATE_GO_ROOT}" ABSOLUTE)
set(PLAYMESH_RUNTIME_PRIVATE_GO_COMMAND
  "${PLAYMESH_RUNTIME_PRIVATE_GO_ROOT}/cmd/playmesh-runtime-crypto")
foreach(PLAYMESH_RUNTIME_PRIVATE_GO_INPUT IN ITEMS
    "${PLAYMESH_RUNTIME_PRIVATE_GO_ROOT}/go.mod"
    "${PLAYMESH_RUNTIME_PRIVATE_GO_COMMAND}")
  if(NOT EXISTS "${PLAYMESH_RUNTIME_PRIVATE_GO_INPUT}")
    message(FATAL_ERROR
      "Windows Runtime private Go staging is missing: ${PLAYMESH_RUNTIME_PRIVATE_GO_INPUT}. Run prepare_private_go_core.ps1 -Variant windows-runtime.")
  endif()
endforeach()
file(GLOB_RECURSE PLAYMESH_RUNTIME_PRIVATE_GO_SOURCES CONFIGURE_DEPENDS
  "${PLAYMESH_RUNTIME_PRIVATE_GO_ROOT}/*.go"
  "${PLAYMESH_RUNTIME_PRIVATE_GO_ROOT}/go.mod"
  "${PLAYMESH_RUNTIME_PRIVATE_GO_ROOT}/go.sum"
  "${PLAYMESH_RUNTIME_PRIVATE_GO_ROOT}/*.pem")
set(PLAYMESH_RUNTIME_PRIVATE_CRYPTO_DLL
  "${CMAKE_BINARY_DIR}/runner/playmesh-runtime-crypto.dll")
add_custom_command(
  OUTPUT "${PLAYMESH_RUNTIME_PRIVATE_CRYPTO_DLL}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory
    "${CMAKE_BINARY_DIR}/runner"
  COMMAND "${CMAKE_COMMAND}" -E env
    "GOWORK=off" "CGO_ENABLED=1" "GOOS=windows" "GOARCH=amd64"
    "${GO_EXECUTABLE}" build
      -buildvcs=false -trimpath -mod=readonly
      -tags playmesh_runtime_private
      -buildmode=c-shared
      "-ldflags=-s -w"
      -o "${PLAYMESH_RUNTIME_PRIVATE_CRYPTO_DLL}"
      ./cmd/playmesh-runtime-crypto
  WORKING_DIRECTORY "${PLAYMESH_RUNTIME_PRIVATE_GO_ROOT}"
  DEPENDS ${PLAYMESH_RUNTIME_PRIVATE_GO_SOURCES}
  COMMENT "Building the Runtime-private Go package decryptor"
  VERBATIM)
add_custom_target(playmesh_runtime_private_crypto ALL
  DEPENDS "${PLAYMESH_RUNTIME_PRIVATE_CRYPTO_DLL}")

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "runtime_package_crypto_host.cpp"
  "speech_recognition_host.cpp"
  "utils.cpp"
  "webview_security.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
if(MSVC)
  target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "sapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE
  "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
add_dependencies(${BINARY_NAME} playmesh_runtime_private_crypto)

# Native contract test for the embedded RSA-OAEP provider. It is deliberately
# excluded from normal Runtime bundles and must be requested explicitly.
add_executable(playmesh_runtime_crypto_host_test EXCLUDE_FROM_ALL
  "runtime_package_crypto_host.cpp"
  "runtime_package_crypto_host_test.cpp")
apply_standard_settings(playmesh_runtime_crypto_host_test)
target_compile_definitions(playmesh_runtime_crypto_host_test PRIVATE
  "NOMINMAX" "WIN32_LEAN_AND_MEAN")
add_dependencies(playmesh_runtime_crypto_host_test
  playmesh_runtime_private_crypto)

# Install only the compiled private module. Its ignored staging sources, PEM,
# generated c-shared header, and any import-library sidecar stay in build roots.
install(FILES "${PLAYMESH_RUNTIME_PRIVATE_CRYPTO_DLL}"
  DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)
