#pragma once

// The plugin host embeds WAMR in the same binary. Set its declaration mode
// before the upstream header, independently of command-line definitions.
#ifdef _WIN32
#ifdef _WASM_EXPORT_H
#error "Include wamr_static_api.h before wasm_export.h for the embedded runtime"
#endif
#undef WASM_RUNTIME_API_EXTERN
#define WASM_RUNTIME_API_EXTERN
#undef WASM_API_EXTERN
#define WASM_API_EXTERN
#endif

#include "wasm_export.h"
