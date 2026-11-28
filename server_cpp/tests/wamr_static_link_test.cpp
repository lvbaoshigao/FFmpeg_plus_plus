// Model a host compilation that did not receive CMake's static API definitions.
#undef WASM_RUNTIME_API_EXTERN
#undef WASM_API_EXTERN
#include "wamr_static_api.h"

#ifdef _WIN32
#define STRINGIFY_API_IMPL(...) #__VA_ARGS__
#define STRINGIFY_API(...) STRINGIFY_API_IMPL(__VA_ARGS__)
static_assert(sizeof("" STRINGIFY_API(WASM_RUNTIME_API_EXTERN)) == 1,
              "Embedded WAMR runtime API must not use DLL import/export");
static_assert(sizeof("" STRINGIFY_API(WASM_API_EXTERN)) == 1,
              "Embedded WAMR C API must not use DLL import/export");
#undef STRINGIFY_API
#undef STRINGIFY_API_IMPL
#endif

int main() {
    if (!wasm_runtime_init()) return 1;
    wasm_runtime_set_log_level(WASM_LOG_LEVEL_ERROR);
    const bool needsThreadEnv = !wasm_runtime_thread_env_inited();
    if (needsThreadEnv && !wasm_runtime_init_thread_env()) {
        wasm_runtime_destroy();
        return 2;
    }
    if (needsThreadEnv) wasm_runtime_destroy_thread_env();
    wasm_runtime_destroy();
    return 0;
}
