cmake_minimum_required(VERSION 3.18)
project(cc_ssh_wrapper C)

find_package(Threads REQUIRED)

set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON CACHE BOOL "" FORCE)
add_subdirectory(third_party/mbedtls)

add_library(libssh2::mbedcrypto ALIAS mbedcrypto)

set(BUILD_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(LIBSSH2_DISABLE_INSTALL ON CACHE BOOL "" FORCE)
set(LIBSSH2_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(LIBSSH2_USE_PKGCONFIG OFF CACHE BOOL "" FORCE)
set(CRYPTO_BACKEND mbedTLS CACHE STRING "" FORCE)
set(MBEDTLS_FOUND ON CACHE BOOL "" FORCE)
set(MBEDTLS_VERSION 3.6.3 CACHE STRING "" FORCE)
set(MBEDTLS_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mbedtls/include" CACHE PATH "" FORCE)
set(MBEDCRYPTO_LIBRARY mbedcrypto CACHE STRING "" FORCE)

add_subdirectory(third_party/libssh2)

add_library(ccssh SHARED cc_ssh.c)
target_include_directories(ccssh PRIVATE third_party/libssh2/include)
target_link_libraries(ccssh PRIVATE libssh2_static Threads::Threads)
