cmake_minimum_required(VERSION 3.20)
# C 语言用于 vendored miniz 与可选的 WAMR 插件解释器
project(ffmpegpp_server LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 避免 Windows.h 的 min/max 宏冲突
if(WIN32)
    add_definitions(-DNOMINMAX)
endif()

# 共享源文件列表（两个目标共用）
set(SHARED_SOURCES
    src/handlers.cpp
    src/json_io.cpp
    src/message_queues.cpp
    src/subprocess.cpp
    src/probe.cpp
    src/transcoder.cpp
    src/subtitle.cpp
    src/installer.cpp
    src/parser.cpp
    src/audit.cpp
    src/ffmpeg_features.cpp
    src/fppx2.cpp
    src/fppx_crypto.cpp
    src/fppx_validate.cpp
    src/fppx_legacy.cpp
    src/fppx_gzip.cpp
    src/node_registry.cpp
    src/plugin_runtime.cpp
)

# vendored miniz（纯 C，仅 gzip 用的 tinfl/tdefl；zip 归档 API 不参与编译）
set(MINIZ_SOURCES
    include/miniz/miniz.c
    include/miniz/miniz_tinfl.c
    include/miniz/miniz_tdef.c
)

# ═══════════════════════════════════════════════
# 共享库目标（主要部署方式）
# ═══════════════════════════════════════════════
add_library(ffmpegpp SHARED
    src/dll_main.cpp
    ${SHARED_SOURCES}
    ${MINIZ_SOURCES}
)

target_include_directories(ffmpegpp PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_compile_definitions(ffmpegpp PRIVATE
    FFMPEGPP_BUILDING_DLL
)

option(FFMPEGPP_ENABLE_PLUGINS "Embed bounded WAMR plugin interpreter" ON)
if(FFMPEGPP_ENABLE_PLUGINS)
    add_subdirectory(runtime)
    target_link_libraries(ffmpegpp PRIVATE ffmpegpp_wamr_runtime)
    target_compile_definitions(ffmpegpp PRIVATE FFMPEGPP_ENABLE_PLUGINS=1)
else()
    target_compile_definitions(ffmpegpp PRIVATE FFMPEGPP_ENABLE_PLUGINS=0)
endif()

if(WIN32)
    target_link_libraries(ffmpegpp PRIVATE kernel32 user32 bcrypt)
elseif(APPLE)
    target_link_libraries(ffmpegpp PRIVATE pthread)
    target_compile_options(ffmpegpp PRIVATE -fvisibility=hidden)
    set_target_properties(ffmpegpp PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        MACOSX_RPATH ON
        INSTALL_RPATH "@loader_path"
    )
else()
    # Android (bionic) 无 libpthread：pthread 并入 libc，无需（也无法）链接 -lpthread
    if(NOT ANDROID)
        target_link_libraries(ffmpegpp PRIVATE pthread)
    endif()
    target_compile_options(ffmpegpp PRIVATE -fvisibility=hidden)
    set_target_properties(ffmpegpp PROPERTIES POSITION_INDEPENDENT_CODE ON)
endif()

if(MSVC)
    target_compile_options(ffmpegpp PRIVATE /O2 /W3 /utf-8 /MP12)
else()
    target_compile_options(ffmpegpp PRIVATE -O2 -Wall)
endif()

if(WIN32)
    set_target_properties(ffmpegpp PROPERTIES
        OUTPUT_NAME "ffmpegpp"
        PREFIX ""
    )
else()
    set_target_properties(ffmpegpp PROPERTIES
        OUTPUT_NAME "ffmpegpp"
    )
endif()

# ═══════════════════════════════════════════════
# FPPX 单元测试（可选：-DFFMPEGPP_BUILD_TESTS=ON 后 ctest）
# ═══════════════════════════════════════════════
option(FFMPEGPP_BUILD_TESTS "Build fppx unit tests" OFF)
if(FFMPEGPP_BUILD_TESTS)
    enable_testing()
    add_executable(fppx_test
        tests/fppx_test.cpp
        src/fppx2.cpp
        src/fppx_crypto.cpp
        src/fppx_validate.cpp
        src/fppx_legacy.cpp
        src/fppx_gzip.cpp
        src/node_registry.cpp
        ${MINIZ_SOURCES}
    )
    target_include_directories(fppx_test PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${CMAKE_CURRENT_SOURCE_DIR}/src
    )
    if(WIN32)
        target_link_libraries(fppx_test PRIVATE bcrypt)
    endif()
    if(MSVC)
        target_compile_options(fppx_test PRIVATE /W3 /utf-8)
    else()
        target_compile_options(fppx_test PRIVATE -Wall)
    endif()
    add_test(NAME fppx_test COMMAND fppx_test)
    if(FFMPEGPP_ENABLE_PLUGINS)
        add_executable(plugin_runtime_test tests/plugin_runtime_test.cpp)
        target_include_directories(plugin_runtime_test PRIVATE src include)
        target_link_libraries(plugin_runtime_test PRIVATE ffmpegpp)
        add_test(NAME plugin_runtime_test COMMAND plugin_runtime_test
            "${CMAKE_CURRENT_SOURCE_DIR}/../docs/public/examples/plugin-demo.wasm"
            "${CMAKE_CURRENT_SOURCE_DIR}/../docs/public/examples/plugin-fixtures/selftest.json")
        set_tests_properties(plugin_runtime_test PROPERTIES TIMEOUT 30)
    endif()
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    add_test(
        NAME generate_fppx_fixtures
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/gen_fixtures.py
    )
    set_tests_properties(generate_fppx_fixtures PROPERTIES
        FIXTURES_SETUP fppx_legacy_fixture
    )
    set_tests_properties(fppx_test PROPERTIES
        FIXTURES_REQUIRED fppx_legacy_fixture
    )
endif()
