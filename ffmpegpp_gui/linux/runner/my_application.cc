#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <string>
#include <unistd.h>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
// 独立面板窗口（desktop_multi_window）：子窗口是独立引擎，插件不会自动
// 注册进去，必须在这里给新注册表再跑一遍 fl_register_plugins。
#include "desktop_multi_window/desktop_multi_window_plugin.h"

namespace {

// 当前可执行文件所在目录（用于定位随包安装的图标资源）。
std::string ExecutableDirectory() {
  char buf[4096];
  ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (n <= 0) return std::string();
  buf[n] = '\0';
  const std::string path(buf);
  const auto pos = path.find_last_of('/');
  return pos == std::string::npos ? std::string() : path.substr(0, pos);
}

// 把目录加入 GTK 图标主题搜索路径（append 语义，不覆盖系统默认路径）。
// 这样桌面环境的图标名解析（Wayland/GNOME、X11 fallback）能找到 bundle 内的
// share/icons/hicolor 图标树。
void EnsureIconThemeSearchPath(const std::string& dir) {
  if (dir.empty() || !g_file_test(dir.c_str(), G_FILE_TEST_IS_DIR)) return;
  GtkIconTheme* theme = gtk_icon_theme_get_default();
  if (!theme) return;
  gtk_icon_theme_append_search_path(theme, dir.c_str());
}

// 设置窗口图标（主窗口与独立面板窗口都经过 activate，都会走到这里）。
// 1) 图标主题搜索路径加入 bundle 的 share/icons，让图标名可解析；
// 2) gtk_window_set_icon_name：Wayland/GNOME 以及 X11 无 _NET_WM_ICON 时按名解析；
// 3) gtk_window_set_icon_from_file：直接写入窗口像素（X11 _NET_WM_ICON 首选）。
void SetupWindowIcon(GtkWindow* window) {
  const std::string exe_dir = ExecutableDirectory();
  const std::string app_id = APPLICATION_ID;

  // 注意：bundle 布局里主程序与 share/ 同目录（bundle/ffmpegpp_gui、
  // bundle/share/icons/...），不要再加 ../。
  if (!exe_dir.empty()) {
    EnsureIconThemeSearchPath(exe_dir + "/share/icons");
  }
  gtk_window_set_icon_name(window, app_id.c_str());

  std::vector<std::string> candidates;
  if (!exe_dir.empty()) {
    candidates.push_back(
        exe_dir + "/share/icons/hicolor/256x256/apps/" + app_id + ".png");
    candidates.push_back(
        exe_dir + "/share/icons/hicolor/128x128/apps/" + app_id + ".png");
  }
#ifdef APP_ICON_SOURCE_DIR
  // dev 模式（flutter run）bundle 未安装，图标还在源码树里。
  candidates.push_back(std::string(APP_ICON_SOURCE_DIR) +
                       "/hicolor/256x256/apps/" + app_id + ".png");
#endif
  for (const auto& candidate : candidates) {
    GError* error = nullptr;
    if (gtk_window_set_icon_from_file(window, candidate.c_str(), &error)) {
      if (error) g_error_free(error);
      return;
    }
    if (error) g_error_free(error);
  }
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  gboolean use_header_bar = FALSE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    // CSD: let Flutter handle the title bar
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "FFmpeg++");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "FFmpeg++");
  }

  gtk_window_set_default_size(window, 1280, 720);
  SetupWindowIcon(window);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  desktop_multi_window_plugin_set_window_created_callback(
      [](FlPluginRegistry* registry) { fl_register_plugins(registry); });

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

static gint my_application_command_line(GApplication* application, GApplicationCommandLine* command_line) {
  MyApplication* self = MY_APPLICATION(application);
  gchar** arguments = g_application_command_line_get_arguments(command_line, nullptr);
  self->dart_entrypoint_arguments = g_strdupv(arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     return 1;
  }

  g_application_activate(application);

  return 0;
}

static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new(bool is_panel_process) {
  std::string application_id = APPLICATION_ID;
  if (is_panel_process) {
    application_id += ".panel.p" + std::to_string(getpid());
  }
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", application_id.c_str(),
                                     "flags", G_APPLICATION_HANDLES_COMMAND_LINE,
                                     nullptr));
}
