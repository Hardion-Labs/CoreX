/*
 * CoreXEngine — Native Module ABI (C++ extension contract).
 *
 * Status: CONTRACT DEFINED. The engine-side loader is not implemented yet.
 * See docs/native-module-api.md for the full contract.
 *
 * A native module is a shared library exporting the three symbols below.
 * The boundary is a plain C ABI: no Zig types and no C++ mangling cross it.
 * Modules are trusted native code; there is no sandbox.
 */
#ifndef COREX_NATIVE_MODULE_H
#define COREX_NATIVE_MODULE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The ABI version this header declares. The engine only loads modules whose
 * reported abi_version equals its own supported value. Any mismatch is a hard
 * load failure. Bumping this is a breaking change (recorded in CHANGELOG). */
#define COREX_ABI_VERSION 1u

/* Result codes. Non-zero means failure. C++ exceptions must not cross the ABI;
 * catch them and translate to a CorexResult. */
typedef enum CorexResult {
    COREX_OK = 0,
    COREX_ERR_UNKNOWN = 1,
    COREX_ERR_INVALID_ARGUMENT = 2,
    COREX_ERR_OUT_OF_MEMORY = 3,
    COREX_ERR_UNSUPPORTED = 4
} CorexResult;

/* Log severity levels, mirroring the engine log. */
typedef enum CorexLogLevel {
    COREX_LOG_ERROR = 0,
    COREX_LOG_WARN = 1,
    COREX_LOG_INFO = 2,
    COREX_LOG_DEBUG = 3
} CorexLogLevel;

/* Static module metadata returned by corex_module_query(). The pointed-to
 * struct and its strings must have static lifetime (valid without init). */
typedef struct CorexModuleInfo {
    uint32_t abi_version;      /* must equal COREX_ABI_VERSION */
    const char* name;          /* stable, NUL-terminated, UTF-8 */
    const char* module_version; /* informational, independent of the ABI */
} CorexModuleInfo;

/* Host services provided by the engine. Read-only for the module. Valid only
 * between init and shutdown. The table is append-only; its layout changes bump
 * COREX_ABI_VERSION. */
typedef struct CorexHostApi {
    uint32_t abi_version; /* ABI the host implements */

    /* Scoped logging into the engine log. `scope` and `message` are borrowed,
     * NUL-terminated UTF-8. */
    void (*log)(int32_t level, const char* scope, const char* message);

    /* Engine allocator, so module allocations can be tracked. Memory from
     * alloc must be returned with free. alloc returns NULL on failure. */
    void* (*alloc)(size_t size);
    void (*free)(void* ptr);
} CorexHostApi;

/* Required module exports. */

/* Return static metadata. Callable before init; must not allocate. */
const CorexModuleInfo* corex_module_query(void);

/* Initialize the module and register its contributions using the host API.
 * Returns COREX_OK on success. The host pointer is valid until shutdown. */
CorexResult corex_module_init(const CorexHostApi* host);

/* Release everything the module owns. Called once before unload. */
void corex_module_shutdown(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* COREX_NATIVE_MODULE_H */
