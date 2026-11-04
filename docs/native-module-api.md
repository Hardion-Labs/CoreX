# Native Module API (C++) — Contract

This document defines the stable contract for extending the CoreXEngine with
native C++ modules. The engine is written in Zig; native modules attach through
a **C ABI**, never through Zig internals, so modules and engine can evolve
independently.

> Status: **contract defined**. The engine-side loader is not implemented yet.
> The header [`include/corex/native_module.h`](../include/corex/native_module.h)
> is the authoritative ABI declaration. Nothing loads modules until the loader
> lands; this contract exists so module authors and the engine agree on the
> boundary before implementation.

## Goals

- Let C++ code extend the engine (systems, components, importers, tools) without
  recompiling the engine.
- Keep the boundary a plain C ABI: no Zig types, no C++ name mangling across it.
- Version the ABI explicitly and reject incompatible modules at load time.
- Make ownership and lifetime explicit.

## Non-goals

- The engine does not build, install, or manage native modules' toolchains.
- The engine does not sandbox native code. A native module is trusted code with
  the same privileges as the engine process.
- This is not the gameplay scripting path; gameplay uses Lua (planned). Native
  modules are for performance-critical or platform-specific extension.

## Module shape

A native module is a shared library (`.so` / `.dll` / `.dylib`) that exports
three C symbols:

```c
const CorexModuleInfo* corex_module_query(void);
CorexResult            corex_module_init(const CorexHostApi* host);
void                   corex_module_shutdown(void);
```

- `corex_module_query` returns static metadata (name, version, ABI version). It
  must be callable before `init` and must not allocate.
- `corex_module_init` receives the host API table and registers the module's
  contributions. It returns `COREX_OK` on success.
- `corex_module_shutdown` releases everything the module owns. It is called once
  before the library is unloaded.

## ABI versioning

`CorexModuleInfo.abi_version` is a single integer. The engine only loads modules
whose `abi_version` equals the engine's supported `COREX_ABI_VERSION`. Any
mismatch is a hard load failure (the engine never guesses compatibility).

Bumping the ABI is a breaking change and is recorded in the CHANGELOG. Module
*content* version (`module_version`) is independent and informational.

## Host API

The engine passes a `CorexHostApi` struct of function pointers. The module must
treat it as read-only and must not retain it past `shutdown`. The initial table
provides:

- `abi_version` — the ABI the host implements.
- `log` — scoped logging into the engine log.
- `alloc` / `free` — the engine allocator, so module allocations can be tracked.

The table is append-only: new function pointers are added at the end, and the
`abi_version` is bumped whenever the layout changes.

## Ownership and lifetime

- The module owns anything it allocates and must free it in `shutdown` (or
  earlier when done).
- Memory obtained from `host->alloc` must be returned with `host->free`.
- Strings passed across the ABI are UTF-8, NUL-terminated, and borrowed unless a
  function documents a transfer of ownership.
- The host API table and any pointers it yields are valid only between `init`
  and `shutdown`.

## Errors

Functions return `CorexResult` (`COREX_OK = 0`, non-zero on failure). A module
must not let C++ exceptions cross the ABI boundary; catch them and translate to
a `CorexResult`.

## Loading (planned)

When the loader is implemented, the engine will discover modules from a
documented project location, call `query`, check `abi_version`, then `init`.
Discovery/management UX (installing, enabling, listing modules) is out of scope
for the engine where it overlaps the Hub; the engine only loads what a project
references.
