cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# 图标资源源码目录：dev 模式（flutter run）bundle 未安装时，
# my_application.cc 通过该路径在源码树里找到窗口图标。
add_definitions(-DAPP_ICON_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/icons")

# Add dependency libraries. Add any application-specific dependencies here.
# Flutter's engine exports its bundled _Unwind_* symbols. Load the system
# unwinder first so libstdc++ exceptions from native plugins reach their catch
# handlers (e.g. LibsecretError when no Secret Service is available). Keep this
# dependency even with --as-needed, and restore the linker's previous state.
target_link_libraries(${BINARY_NAME} PRIVATE
  "-Wl,--push-state,--no-as-needed" gcc_s "-Wl,--pop-state")
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
