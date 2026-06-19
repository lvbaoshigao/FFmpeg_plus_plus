cmake_minimum_required(VERSION 3.20)
project(ffmpegpp_server LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 避免 Windows.h 的 min/max 宏冲突
add_definitions(-DNOMINMAX)

# Windows 子系统：控制台（有 stdin/stdout，不弹窗）
add_executable(server
    src/main.cpp
    src/json_io.cpp
    src/subprocess.cpp
    src/probe.cpp
    src/transcoder.cpp
    src/subtitle.cpp
    src/installer.cpp
    src/parser.cpp
    src/audit.cpp
    src/ffmpeg_features.cpp
)

target_include_directories(server PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Windows 特定链接
target_link_libraries(server PRIVATE kernel32 user32)
# 关键：WIN32_EXECUTABLE=FALSE → 编译为 console 子系统（有 stdin/stdout）
# ShowWindow(GetConsoleWindow(), SW_HIDE) 在 main() 中隐藏窗口
set_target_properties(server PROPERTIES WIN32_EXECUTABLE FALSE)

# Release 优化 + UTF-8 编码 + 并行编译
if(MSVC)
    target_compile_options(server PRIVATE /O2 /W3 /utf-8 /MP12)
else()
    target_compile_options(server PRIVATE -O2 -Wall)
endif()

# 构建后用 mt.exe 替换 UAC manifest（asInvoker，不需要管理员权限）
if(MSVC)
    # 编译图标资源
    set(ICON_RC "${CMAKE_CURRENT_SOURCE_DIR}/icon.rc")
    set(ICON_RES "${CMAKE_CURRENT_BINARY_DIR}/icon.res")
    if(EXISTS "${ICON_RC}")
        add_custom_command(
            OUTPUT "${ICON_RES}"
            COMMAND rc.exe /fo"${ICON_RES}" "${ICON_RC}"
            DEPENDS "${ICON_RC}"
            COMMENT "Compiling icon resource"
        )
        target_sources(server PRIVATE "${ICON_RES}")
    endif()

    # 查找 Windows SDK 的 mt.exe
    find_program(MT_EXECUTABLE mt.exe
        HINTS
            "C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64"
            "C:/Program Files (x86)/Windows Kits/10/bin/10.0.22621.0/x64"
            "C:/Program Files (x86)/Windows Kits/10/bin/10.0.22000.0/x64"
    )
    if(MT_EXECUTABLE)
        add_custom_command(TARGET server POST_BUILD
            COMMAND "${MT_EXECUTABLE}" -nologo
                -manifest "${CMAKE_CURRENT_SOURCE_DIR}/server.exe.manifest"
                -outputresource:"$<TARGET_FILE:server>"
            COMMENT "Embedding asInvoker manifest into server.exe"
        )
    else()
        message(WARNING "mt.exe not found - server.exe will require admin privileges!")
    endif()
endif()
