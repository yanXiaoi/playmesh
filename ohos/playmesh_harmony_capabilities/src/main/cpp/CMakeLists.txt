cmake_minimum_required(VERSION 3.5.0)
project(playmesh_core_napi)

set(PLAYMESH_CORE_LIB_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../libs/${OHOS_ARCH}")

add_library(playmesh_core SHARED IMPORTED)
set_target_properties(playmesh_core PROPERTIES
    IMPORTED_LOCATION "${PLAYMESH_CORE_LIB_DIR}/libplaymesh_core.so")

add_library(playmesh_core_napi SHARED playmesh_core_napi.cpp)
set_target_properties(playmesh_core_napi PROPERTIES
    SKIP_BUILD_RPATH TRUE
    BUILD_WITH_INSTALL_RPATH FALSE
    INSTALL_RPATH "")
target_include_directories(playmesh_core_napi PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(playmesh_core_napi PUBLIC
    playmesh_core
    libace_napi.z.so)
