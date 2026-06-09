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
target_link_libraries(server PRIVATE kernel32)
# 关键：WIN32_EXECUTABLE=FALSE → 编译为 console 子系统（有 stdin/stdout）
# ShowWindow(GetConsoleWindow(), SW_HIDE) 在 main() 中隐藏窗口
set_target_properties(server PROPERTIES WIN32_EXECUTABLE FALSE)

# Release 优化 + UTF-8 编码
if(MSVC)
    target_compile_options(server PRIVATE /O2 /W3 /utf-8)
else()
    target_compile_options(server PRIVATE -O2 -Wall)
endif()
