#include "my_application.h"

#include <cstring>

int main(int argc, char** argv) {
  bool is_panel_process = false;
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "ffmpegpp-panel-v1") == 0) {
      is_panel_process = true;
      break;
    }
  }
  g_autoptr(MyApplication) app = my_application_new(is_panel_process);
  return g_application_run(G_APPLICATION(app), argc, argv);
}
