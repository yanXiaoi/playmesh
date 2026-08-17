# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(playmesh LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "playmesh")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd4100)
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# The Ninja release builder does not run Flutter's project-generation phase,
# so its ephemeral generated_config.cmake can contain a previous app version.
# Prefer the pubspec-derived values supplied by the release script.
if(DEFINED PLAYMESH_FLUTTER_VERSION)
  set(FLUTTER_VERSION "${PLAYMESH_FLUTTER_VERSION}")
  set(FLUTTER_VERSION_MAJOR "${PLAYMESH_FLUTTER_VERSION_MAJOR}")
  set(FLUTTER_VERSION_MINOR "${PLAYMESH_FLUTTER_VERSION_MINOR}")
  set(FLUTTER_VERSION_PATCH "${PLAYMESH_FLUTTER_VERSION_PATCH}")
  set(FLUTTER_VERSION_BUILD "${PLAYMESH_FLUTTER_VERSION_BUILD}")
endif()

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Go Core 与 Windows Runner 一起构建和安装，发布物不依赖外部 Go 进程。
find_program(GO_EXECUTABLE go REQUIRED)
set(GO_CORE_SOURCE_DIR "${CMAKE_SOURCE_DIR}/../go-core")
set(GO_CORE_BINARY "${CMAKE_BINARY_DIR}/playmesh-core.exe")
file(GLOB_RECURSE GO_CORE_SOURCES CONFIGURE_DEPENDS
  "${GO_CORE_SOURCE_DIR}/*.go"
  "${GO_CORE_SOURCE_DIR}/go.mod"
  "${GO_CORE_SOURCE_DIR}/go.sum"
)
add_custom_command(
  OUTPUT "${GO_CORE_BINARY}"
  COMMAND "${GO_EXECUTABLE}" build -buildvcs=false -trimpath -o "${GO_CORE_BINARY}" .
  DEPENDS ${GO_CORE_SOURCES}
  WORKING_DIRECTORY "${GO_CORE_SOURCE_DIR}"
  COMMENT "Building bundled Playmesh Go Core"
  VERBATIM
)
add_custom_target(playmesh_go_core ALL DEPENDS "${GO_CORE_BINARY}")
add_dependencies(${BINARY_NAME} playmesh_go_core)

# Developer CLI 与桌面 App 一起构建，安装在 Go Core 同级目录。
set(PLAYMESH_CLI_SOURCE_DIR "${CMAKE_SOURCE_DIR}/../dev-cli")
set(PLAYMESH_CLI_BINARY "${CMAKE_BINARY_DIR}/playmesh-cli.exe")
file(GLOB_RECURSE PLAYMESH_CLI_SOURCES CONFIGURE_DEPENDS
  "${PLAYMESH_CLI_SOURCE_DIR}/*.go"
  "${PLAYMESH_CLI_SOURCE_DIR}/internal/adapter/cocos/extension/*"
  "${PLAYMESH_CLI_SOURCE_DIR}/go.mod"
  "${PLAYMESH_CLI_SOURCE_DIR}/go.sum"
)
add_custom_command(
  OUTPUT "${PLAYMESH_CLI_BINARY}"
  COMMAND "${GO_EXECUTABLE}" build -buildvcs=false -trimpath
    -ldflags=-s\ -w -o "${PLAYMESH_CLI_BINARY}" .
  DEPENDS ${PLAYMESH_CLI_SOURCES}
  WORKING_DIRECTORY "${PLAYMESH_CLI_SOURCE_DIR}"
  COMMENT "Building bundled Playmesh Developer CLI"
  VERBATIM
)
add_custom_target(playmesh_dev_cli ALL DEPENDS "${PLAYMESH_CLI_BINARY}")
add_dependencies(${BINARY_NAME} playmesh_dev_cli)

# Windows WebView2 插件需要 NuGet 恢复原生 SDK。项目固定工具版本并校验哈希，
# 避免要求用户全局安装 NuGet，也避免插件输出误导性的未安装提示。
set(PLAYMESH_NUGET_URL
  "https://dist.nuget.org/win-x86-commandline/v7.6.0/nuget.exe")
set(PLAYMESH_NUGET_SHA256
  "751ee5e79481626a428c1241dc7f94bca2739b32588e669715bc5fb54d8fb8a2")
set(NUGET "${CMAKE_BINARY_DIR}/nuget.exe")
set(PLAYMESH_STANDARD_FLUTTER_NUGET
  "${CMAKE_BINARY_DIR}/../x64/nuget.exe")
if(NOT EXISTS "${NUGET}" AND EXISTS "${PLAYMESH_STANDARD_FLUTTER_NUGET}")
  file(SHA256 "${PLAYMESH_STANDARD_FLUTTER_NUGET}"
    PLAYMESH_CACHED_NUGET_SHA256)
  if(PLAYMESH_CACHED_NUGET_SHA256 STREQUAL PLAYMESH_NUGET_SHA256)
    message(STATUS "Reusing verified NuGet 7.6.0 from the Flutter build cache")
    file(COPY_FILE "${PLAYMESH_STANDARD_FLUTTER_NUGET}" "${NUGET}")
  endif()
endif()
if(NOT EXISTS "${NUGET}")
  message(STATUS "Downloading bundled NuGet 7.6.0")
  file(DOWNLOAD "${PLAYMESH_NUGET_URL}" "${NUGET}"
    EXPECTED_HASH "SHA256=${PLAYMESH_NUGET_SHA256}"
    TLS_VERIFY ON
    STATUS PLAYMESH_NUGET_DOWNLOAD_STATUS
  )
  list(GET PLAYMESH_NUGET_DOWNLOAD_STATUS 0 PLAYMESH_NUGET_DOWNLOAD_CODE)
  if(NOT PLAYMESH_NUGET_DOWNLOAD_CODE EQUAL 0)
    list(GET PLAYMESH_NUGET_DOWNLOAD_STATUS 1 PLAYMESH_NUGET_DOWNLOAD_MESSAGE)
    file(REMOVE "${NUGET}")
    message(FATAL_ERROR
      "Failed to download NuGet: ${PLAYMESH_NUGET_DOWNLOAD_MESSAGE}")
  endif()
endif()
file(SHA256 "${NUGET}" PLAYMESH_NUGET_ACTUAL_SHA256)
if(NOT PLAYMESH_NUGET_ACTUAL_SHA256 STREQUAL PLAYMESH_NUGET_SHA256)
  message(FATAL_ERROR "NuGet integrity check failed: ${NUGET}")
endif()

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# NuGet's WebView2 package exposes its native include/library settings through
# MSBuild .targets files. Ninja cannot evaluate those files, so mirror the
# relevant x64 settings when the fallback release builder uses Ninja.
if(TARGET webview_flutter_windows_plugin AND
   NOT CMAKE_GENERATOR MATCHES "^Visual Studio")
  set(PLAYMESH_WEBVIEW2_PACKAGE
    "${CMAKE_BINARY_DIR}/packages/Microsoft.Web.WebView2")
  set(PLAYMESH_WIL_PACKAGE
    "${CMAKE_BINARY_DIR}/packages/Microsoft.Windows.ImplementationLibrary")

  get_target_property(PLAYMESH_WEBVIEW_LINK_LIBRARIES
    webview_flutter_windows_plugin LINK_LIBRARIES)
  set(PLAYMESH_WEBVIEW_FILTERED_LINK_LIBRARIES "")
  foreach(PLAYMESH_WEBVIEW_LIBRARY IN LISTS PLAYMESH_WEBVIEW_LINK_LIBRARIES)
    if(NOT PLAYMESH_WEBVIEW_LIBRARY MATCHES "\\.targets$")
      list(APPEND PLAYMESH_WEBVIEW_FILTERED_LINK_LIBRARIES
        "${PLAYMESH_WEBVIEW_LIBRARY}")
    endif()
  endforeach()
  set_property(TARGET webview_flutter_windows_plugin PROPERTY LINK_LIBRARIES
    "${PLAYMESH_WEBVIEW_FILTERED_LINK_LIBRARIES}")

  target_include_directories(webview_flutter_windows_plugin PRIVATE
    "${PLAYMESH_WEBVIEW2_PACKAGE}/build/native/include"
    "${PLAYMESH_WIL_PACKAGE}/include")
  target_link_libraries(webview_flutter_windows_plugin PRIVATE
    "${PLAYMESH_WEBVIEW2_PACKAGE}/build/native/x64/WebView2Loader.dll.lib")
  list(APPEND PLUGIN_BUNDLED_LIBRARIES
    "${PLAYMESH_WEBVIEW2_PACKAGE}/build/native/x64/WebView2Loader.dll")
endif()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(PROGRAMS "${GO_CORE_BINARY}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(PROGRAMS "${PLAYMESH_CLI_BINARY}" DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${CMAKE_SOURCE_DIR}/../LICENSE"
  DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
