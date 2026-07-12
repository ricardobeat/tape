/// ESM module system — data structures, host API, loader, linker.
///
/// Implements the ES6 module lifecycle:
///   1. COMPILE:  compile_module() → parse import/export → emit bytecode → ModuleDef
///   2. RESOLVE:  load all transitive dependencies (recursive compile_module)
///   3. LINK:     share env bindings between modules for live exports
///   4. EXECUTE:  run module body (top-level statements)
///   5. NAMESPACE: build Module Namespace Object for `import *`
module duktape::esm;

import duktape::types;
import duktape::bytecode;
import duktape::env;
import duktape::heap;
import duktape::hobject;
import duktape::hstring;
import duktape::lexer;
import duktape::compiler;
import duktape::builtins;
import duktape::vm;
import std::io;
import libc;

// ============================================================================
// Fault codes
// ============================================================================

faultdef MODULE_ERROR;

// ============================================================================
// Module status lifecycle
// ============================================================================

enum ModuleStatus : char {
    UNLOADED,
    LOADING,       // currently being compiled (cycle detection)
    LOADED,        // compiled, not yet linked
    LINKING,       // being linked
    LINKED,        // ready for evaluation
    EVALUATING,    // being executed
    EVALUATED,     // fully executed
}

// ============================================================================
// Import/export metadata entries
// ============================================================================

struct ImportEntry {
    char[] local_name;      // the local binding name ("foo", "default", "ns")
    char[] import_name;     // the imported name ("foo", "default", "*")
    uint   req_module_idx;  // index into ModuleDef.req_modules
    bool   is_star;         // true for `import * as ns`
    bool   is_default;      // true for `import foo from ...`
}

struct ExportEntry {
    char[] local_name;      // the local binding name
    char[] export_name;     // the exported name ("default" for default export)
    bool   is_indirect;     // true for `export { x } from './other'`
    uint   req_module_idx;  // for indirect exports
}

struct StarExportEntry {
    uint req_module_idx;    // index into ModuleDef.req_modules
}

struct ReqModuleEntry {
    char[]       module_name;   // the specifier string
    void*        resolved;      // ModuleDef* filled during resolve phase (opaque to avoid cycle)
}

// ============================================================================
// ModuleHostHooks — pluggable host callbacks
// ============================================================================

alias ResolveNameFn = fn char[]?(char[] base_name, char[] specifier, void* udata);
alias ReadSourceFn  = fn char[]?(char[] normalized_name, void* udata);
alias OnModuleLoadedFn    = fn void?(void* mod, void* udata);
alias OnModuleEvaluatedFn = fn void?(void* mod, void* udata);

struct ModuleHostHooks {
    ResolveNameFn      resolve_name;
    ReadSourceFn       read_source;
    OnModuleLoadedFn   on_module_loaded;
    OnModuleEvaluatedFn on_module_evaluated;
    void*              udata;
}

// ============================================================================
// ModuleDef — a single module's definition
// ============================================================================

const uint MAX_IMPORTS      = 64;
const uint MAX_EXPORTS      = 64;
const uint MAX_STAR_EXPORTS = 16;
const uint MAX_REQ_MODULES  = 32;

struct ModuleDef {
    char[]                module_name;    // normalized path / identifier
    ModuleStatus          status;

    // Import/export metadata (populated during compilation)
    ImportEntry[MAX_IMPORTS]      imports;
    uint                          import_count;
    ExportEntry[MAX_EXPORTS]      exports;
    uint                          export_count;
    StarExportEntry[MAX_STAR_EXPORTS] star_exports;
    uint                          star_export_count;
    ReqModuleEntry[MAX_REQ_MODULES] req_modules;
    uint                          req_module_count;

    // Compiled bytecode for this module's body
    bytecode::CompiledFunction*   func;

    // Runtime environment holding this module's bindings
    env::EnvRecord*               env;

    // Module namespace object (lazily created for `import *`)
    HObject*                      namespace_obj;
}

// ============================================================================
// Module cache on Heap
// ============================================================================

const uint INITIAL_MODULE_CAP = 16;

/// Find a loaded module by normalized name. Returns null if not found.
fn ModuleDef* heap_find_loaded_module(Heap* heap, char[] name) {
    if (heap.module_cache == null) return null;
    ModuleDef** cache = (ModuleDef**)heap.module_cache;
    for (uint i = 0; i < heap.module_cache_count; i++) {
        if (cache[i] != null && cache[i].module_name.len == name.len) {
            bool match = true;
            for (usz j = 0; j < name.len; j++) {
                if (cache[i].module_name[j] != name[j]) { match = false; break; }
            }
            if (match) return cache[i];
        }
    }
    return null;
}

// ============================================================================
// Default module host callbacks
// ============================================================================

/// Default source reader: read file from disk via libc.
fn char[]? default_module_read(char[] normalized_name, void* udata) {
    // Null-terminate for fopen
    usz len = normalized_name.len;
    void* raw = libc::malloc(len + 1);
    if (raw == null) return MODULE_ERROR~;
    libc::memcpy(raw, normalized_name.ptr, len);
    ((char*)raw)[len] = 0;

    libc::CFile fp = libc::fopen((ZString)raw, "r");
    libc::free(raw);
    if (fp == null) return MODULE_ERROR~;

    // Get file size
    libc::fseek(fp, 0, libc::SEEK_END);
    long size = libc::ftell(fp);
    libc::fseek(fp, 0, libc::SEEK_SET);

    if (size <= 0) {
        libc::fclose(fp);
        return MODULE_ERROR~;
    }

    // Allocate buffer and read
    void* buf = libc::malloc((usz)size + 1);
    if (buf == null) {
        libc::fclose(fp);
        return MODULE_ERROR~;
    }
    usz n = libc::fread(buf, 1, (usz)size, fp);
    libc::fclose(fp);

    ((char*)buf)[n] = 0;
    return ((char*)buf)[:n];
}

// ============================================================================
// Module loader — resolve, load, compile, link, execute
// ============================================================================

/// Call the host's resolve_name hook, or use the default.
fn char[]? call_resolve_name(Heap* heap, char[] base_name, char[] specifier) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.resolve_name != null) {
            return hooks.resolve_name(base_name, specifier, hooks.udata);
        }
    }
    // Bare specifier (no leading dot) — return as-is
    if (specifier.len > 0 && specifier[0] != '.') return specifier;
    // Relative specifier — resolve against base_name's directory
    if (base_name.len == 0) return specifier;
    // Find last '/' in base_name to get directory
    int last_slash = -1;
    for (usz i = 0; i < base_name.len; i++) {
        if (base_name[i] == '/') last_slash = (int)i;
    }
    if (last_slash < 0) return specifier;
    char[] dir = base_name[:last_slash + 1];
    char[] rel = specifier;
    if (rel.len >= 2 && rel[0] == '.' && rel[1] == '/') {
        rel = rel[2..];
    }
    usz total = dir.len + rel.len;
    void* raw = libc::malloc(total + 1);
    if (raw == null) return MODULE_ERROR~;
    libc::memcpy(raw, dir.ptr, dir.len);
    libc::memcpy((char*)raw + dir.len, rel.ptr, rel.len);
    ((char*)raw)[total] = 0;
    char[] result = ((char*)raw)[:total];
    return result;
}

/// Call the host's read_source hook, or use the default.
fn char[]? call_read_source(Heap* heap, char[] normalized_name) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.read_source != null) {
            return hooks.read_source(normalized_name, hooks.udata);
        }
    }
    return default_module_read(normalized_name, null);
}

/// Call the host's on_module_loaded hook (if set).
fn void call_on_module_loaded(Heap* heap, void* mod) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.on_module_loaded != null) {
            (void)hooks.on_module_loaded(mod, hooks.udata);
        }
    }
}

/// Call the host's on_module_evaluated hook (if set).
fn void call_on_module_evaluated(Heap* heap, void* mod) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.on_module_evaluated != null) {
            (void)hooks.on_module_evaluated(mod, hooks.udata);
        }
    }
}

/// Find or create a ModuleDef by name in the heap's module cache.
fn ModuleDef*? heap_ensure_module(Heap* heap, char[] name) {
    // Check existing cache
    if (heap.module_cache != null) {
        ModuleDef** cache = (ModuleDef**)heap.module_cache;
        for (uint i = 0; i < heap.module_cache_count; i++) {
            if (cache[i] != null && cache[i].module_name.len == name.len) {
                bool match = true;
                for (usz j = 0; j < name.len; j++) {
                    if (cache[i].module_name[j] != name[j]) { match = false; break; }
                }
                if (match) return cache[i];
            }
        }
    }

    // Allocate new ModuleDef
    void* raw = heap.alloc_func(heap.heap_udata, ModuleDef::size);
    if (raw == null) return MODULE_ERROR~;
    libc::memset(raw, 0, ModuleDef::size);
    ModuleDef* mod = (ModuleDef*)raw;
    mod.module_name = name;
    mod.status = ModuleStatus.UNLOADED;

    // Grow cache if needed
    if (heap.module_cache_count >= heap.module_cache_cap) {
        uint new_cap = heap.module_cache_cap == 0 ? INITIAL_MODULE_CAP : heap.module_cache_cap * 2;
        usz new_bytes = (usz)new_cap * void*::size;
        void* new_arr;
        if (heap.module_cache == null) {
            new_arr = heap.alloc_func(heap.heap_udata, new_bytes);
        } else {
            new_arr = heap.realloc_func(heap.heap_udata, heap.module_cache, new_bytes);
        }
        if (new_arr == null) {
            heap.free_func(heap.heap_udata, raw);
            return MODULE_ERROR~;
        }
        heap.module_cache = new_arr;
        heap.module_cache_cap = new_cap;
    }

    ((ModuleDef**)heap.module_cache)[heap.module_cache_count] = mod;
    heap.module_cache_count++;

    return mod;
}

/// Resolve a module specifier, compile it, and recursively resolve dependencies.
fn ModuleDef*? resolve_module(Heap* heap, char[] specifier, char[] base_name) {
    // 1. Normalize name via host hook
    char[]? normalized_opt = call_resolve_name(heap, base_name, specifier);
    if (catch err = normalized_opt) return MODULE_ERROR~;
    char[] normalized = normalized_opt;

    // 2. Check engine cache
    ModuleDef* cached = heap_find_loaded_module(heap, normalized);
    if (cached != null) return cached;

    // 3. Read source via host hook
    char[]? source_opt = call_read_source(heap, normalized);
    if (catch err = source_opt) return MODULE_ERROR~;
    char[] source = source_opt;
    if (source.len == 0) return MODULE_ERROR~;

    // 4. Create ModuleDef (marks as LOADING for cycle detection)
    ModuleDef*? mod_opt = heap_ensure_module(heap, normalized);
    if (catch err = mod_opt) return MODULE_ERROR~;
    ModuleDef* mod = mod_opt;
    mod.status = ModuleStatus.LOADING;

    // 5. Compile
    Lexer lex = lexer::lexer_init(source, heap);
    bytecode::CompiledFunction*? func_opt = compiler::compile_module(&lex, heap, normalized, mod);
    if (catch err = func_opt) {
        char* msg  = compiler::last_error_msg();
        uint  line = compiler::last_error_line();
        uint  col  = compiler::last_error_col();
        usz   msg_len = (usz)libc::strlen((ZString)msg);
        // Build the module name portion into a temp buffer for printing.
        char[512] name_buf;
        usz name_copy = normalized.len < 511 ? normalized.len : 511;
        libc::memcpy(&name_buf[0], normalized.ptr, name_copy);
        name_buf[name_copy] = 0;
        if (msg_len > 0) {
            io::eprintfn("%s: compile error at line %d:%d: %s",
                         (ZString)name_buf[0..], line, col, (ZString)msg);
        } else {
            io::eprintfn("%s: compile error at line %d:%d",
                         (ZString)name_buf[0..], line, col);
        }
        return MODULE_ERROR~;
    }
    mod.func = func_opt;

    // 6. Notify host
    call_on_module_loaded(heap, mod);

    // 7. Recursively resolve dependencies
    for (uint i = 0; i < mod.req_module_count; i++) {
        ReqModuleEntry* rme = &mod.req_modules[i];
        ModuleDef*? dep = resolve_module(heap, rme.module_name, normalized);
        if (catch err = dep) {
            return MODULE_ERROR~;
        }
        rme.resolved = dep;
    }

    mod.status = ModuleStatus.LOADED;
    return mod;
}

/// Link a module: resolve import bindings from source modules' envs.
/// Phase 1 (initial): import bindings are copied at link time.
fn bool link_module(Heap* heap, ModuleDef* mod, EnvRecord* global_env) {
    if (mod.status == ModuleStatus.LINKED || mod.status == ModuleStatus.EVALUATED) return true;
    // LINKING means we're already linking this module further up the call
    // stack — a dependency cycle (including a self-import). Treat it as done to
    // break the recursion; its env exists and bindings resolve once the
    // outermost link_module completes. Without this a cyclic import recurses
    // until the C stack overflows (SIGSEGV).
    if (mod.status == ModuleStatus.LINKING) return true;
    mod.status = ModuleStatus.LINKING;

    // Create module env (declarative), parented to the global env so that
    // globals (Object, print, Error, ...) resolve via the scope chain from
    // inside module code.
    EnvRecord*? env_opt = env::env_create_declarative(heap, global_env);
    if (catch err = env_opt) return false;
    mod.env = env_opt;

    // Link dependencies first
    for (uint i = 0; i < mod.req_module_count; i++) {
        ReqModuleEntry* rme = &mod.req_modules[i];
        if (rme.resolved == null) continue;
        ModuleDef* dep = (ModuleDef*)rme.resolved;
        if (dep.status != ModuleStatus.LINKED && dep.status != ModuleStatus.EVALUATED) {
            if (!link_module(heap, dep, global_env)) return false;
        }
    }

    // Resolve import bindings: copy values from source module's env
    for (uint i = 0; i < mod.import_count; i++) {
        ImportEntry* ie = &mod.imports[i];
        if (ie.req_module_idx >= mod.req_module_count) continue;
        ReqModuleEntry* rme = &mod.req_modules[ie.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* source_mod = (ModuleDef*)rme.resolved;

        if (ie.is_star) {
            // `import * as ns` — create namespace object
            // For now, skip namespace object creation (Phase 2)
            continue;
        }

        // Look up the exported name in the source module's env
        HString* key = heap.str_intern(ie.import_name);
        if (key == null) continue;

        TVal? val_opt = env::env_get(source_mod.env, key);
        if (catch err = val_opt) {
            // Binding not found — set to undefined (will be live-binding later)
            TVal undef;
            undef.set_undefined();
            env::env_declare(mod.env, key, undef);
        } else {
            env::env_declare(mod.env, key, val_opt);
        }

        // Also declare the local name if different from import name
        if (ie.local_name.len != ie.import_name.len ||
            !char_slice_eq(ie.local_name, ie.import_name)) {
            HString* local_key = heap.str_intern(ie.local_name);
            if (local_key != null) {
                TVal? local_val = env::env_get(source_mod.env, key);
                if (catch err2 = local_val) {
                    TVal undef;
                    undef.set_undefined();
                    env::env_declare(mod.env, local_key, undef);
                } else {
                    env::env_declare(mod.env, local_key, local_val);
                }
            }
        }
    }

    // Resolve indirect exports
    for (uint i = 0; i < mod.export_count; i++) {
        ExportEntry* ee = &mod.exports[i];
        if (!ee.is_indirect) continue;
        if (ee.req_module_idx >= mod.req_module_count) continue;
        ReqModuleEntry* rme = &mod.req_modules[ee.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* source_mod = (ModuleDef*)rme.resolved;

        HString* source_key = heap.str_intern(ee.local_name);
        HString* export_key = heap.str_intern(ee.export_name);
        if (source_key == null || export_key == null) continue;

        TVal? val_opt = env::env_get(source_mod.env, source_key);
        if (catch err = val_opt) {
            TVal undef;
            undef.set_undefined();
            env::env_declare(mod.env, export_key, undef);
        } else {
            env::env_declare(mod.env, export_key, val_opt);
        }
    }

    // Declare local export bindings in the module env
    // (These will be populated when the module body executes)
    for (uint i = 0; i < mod.export_count; i++) {
        ExportEntry* ee = &mod.exports[i];
        if (ee.is_indirect) continue;
        HString* key = heap.str_intern(ee.local_name);
        if (key == null) continue;
        // Check if already declared (from import resolution)
        if (!env::env_has(mod.env, key)) {
            TVal undef;
            undef.set_undefined();
            env::env_declare(mod.env, key, undef);
        }
    }

    mod.status = ModuleStatus.LINKED;
    return true;
}

/// Execute a module: run dependencies first, then resolve imports, then run body.
fn bool execute_module(Heap* heap, Vm* vm, ModuleDef* mod) {
    if (mod.status == ModuleStatus.EVALUATED) return true;
    if (mod.status == ModuleStatus.EVALUATING) return true; // cycle guard
    mod.status = ModuleStatus.EVALUATING;

    // Create module env if not already done, parented to the global env so
    // that globals (console, Error, etc.) are visible inside modules.
    if (mod.env == null) {
        EnvRecord*? env_opt = env::env_create_declarative(heap, vm.global_env);
        if (catch err = env_opt) return false;
        mod.env = env_opt;
        // Register the env bindings as a GC root so that objects stored in module
        // envs (e.g. exported functions) are not swept between module evaluations.
        if (mod.env.bindings != null) {
            heap.register_gc_root(mod.env.bindings.as_header());
        }
    }

    // Execute dependencies first (so their exports are available)
    for (uint i = 0; i < mod.req_module_count; i++) {
        ReqModuleEntry* rme = &mod.req_modules[i];
        if (rme.resolved == null) continue;
        ModuleDef* dep = (ModuleDef*)rme.resolved;
        if (dep.status != ModuleStatus.EVALUATED) {
            if (!execute_module(heap, vm, dep)) return false;
        }
    }

    // Resolve import bindings: copy values from (now-executed) source modules
    for (uint i = 0; i < mod.import_count; i++) {
        ImportEntry* ie = &mod.imports[i];
        if (ie.req_module_idx >= mod.req_module_count) continue;
        ReqModuleEntry* rme = &mod.req_modules[ie.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* source_mod = (ModuleDef*)rme.resolved;

        if (ie.is_star) {
            // `import * as ns from '...'` — build a Module Namespace Object
            HObject*? ns_opt = build_namespace_object(heap, source_mod);
            if (catch err = ns_opt) continue;
            HObject* ns = ns_opt;
            TVal ns_val;
            ns_val.set_object(ns);
            HString* local_key = heap.str_intern(ie.local_name);
            if (local_key != null) {
                env::env_declare(mod.env, local_key, ns_val);
            }
            continue;
        }

        // Resolve the export name to the actual local binding name in the source module.
        // For example, `export default 42` stores the value under "*default*" but
        // exports it under the name "default".
        char[] src_local_name = resolve_export_local_name(source_mod, ie.import_name);

        // Look up the exported binding in the source module's env
        HString* key = heap.str_intern(src_local_name);
        if (key == null) continue;

        TVal val;
        TVal? val_opt = env::env_get(source_mod.env, key);
        if (catch err = val_opt) {
            val.set_undefined();
        } else {
            val = val_opt;
        }

        // Declare the local binding with the imported value
        HString* local_key = heap.str_intern(ie.local_name);
        if (local_key != null) {
            env::env_declare(mod.env, local_key, val);
        }
    }

    // Resolve indirect exports
    for (uint i = 0; i < mod.export_count; i++) {
        ExportEntry* ee = &mod.exports[i];
        if (!ee.is_indirect) continue;
        if (ee.req_module_idx >= mod.req_module_count) continue;
        ReqModuleEntry* rme = &mod.req_modules[ee.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* source_mod = (ModuleDef*)rme.resolved;

        // Resolve the local name in the source module (handles "*default*" style names)
        char[] src_local = resolve_export_local_name(source_mod, ee.local_name);
        HString* source_key = heap.str_intern(src_local);
        HString* export_key = heap.str_intern(ee.export_name);
        if (source_key == null || export_key == null) continue;

        TVal val;
        TVal? val_opt;
        if (source_mod.env != null) {
            val_opt = env::env_get(source_mod.env, source_key);
        } else {
            val_opt = hobject::PROP_NOT_FOUND~;
        }
        if (catch err = val_opt) {
            val.set_undefined();
        } else {
            val = val_opt;
        }
        env::env_declare(mod.env, export_key, val);
    }

    // Execute module body in its own env. A module compiled with top-level
    // await is async: run it through the async path so `await` suspends and
    // the module's evaluation promise drives to settlement. A rejection (e.g.
    // `await Promise.reject(e)`) surfaces `e` in heap.error_value.
    if (mod.func != null) {
        if (mod.func.is_async()) {
            bool? ok = vm.execute_module_async(mod.func, mod.env);
            if (catch err = ok) return false;
            if (!ok) return false;  // rejected — reason is in heap.error_value
        } else {
            TVal? res = vm.execute_in_env(mod.func, mod.env);
            if (catch err = res) {
                return false;
            }
        }
    }

    mod.status = ModuleStatus.EVALUATED;
    call_on_module_evaluated(heap, mod);
    return true;
}

// ============================================================================
// Top-level entry point
// ============================================================================

/// Load, link, and evaluate a module program given its file path.
///
/// `path` is used both to read the top-level module source and as the base
/// name against which relative imports (`./x.js`) are resolved, so it must be
/// the module file's real path (absolute or relative to cwd). Drives the full
/// resolve -> link -> evaluate pipeline.
///
/// Return values (an int rather than a fault so the caller can distinguish
/// the failure kind, mirroring the worker's exec_js contract):
///   0 = evaluated successfully
///   1 = a runtime error was thrown during evaluation of the module or one of
///       its dependencies. The thrown value is left in `heap.error_value` so
///       the caller (e.g. the test harness) can inspect its type.
///   2 = the module (or a dependency) failed to load/compile/link.
fn int run_module_file(Heap* heap, Vm* vm, char[] path) {
    // Reading + compiling + recursively resolving dependencies. A failure here
    // is a load/compile/link error (rc 2), not a thrown runtime value.
    ModuleDef*? mod_opt = resolve_module(heap, path, "");
    if (catch err = mod_opt) { return 2; }
    ModuleDef* mod = mod_opt;

    if (!link_module(heap, mod, vm.global_env)) { return 2; }

    // Evaluation. execute_module returns false when the module body (or a
    // dependency's body) throws; the thrown value persists in heap.error_value
    // (the uncaught-error unwind copies it there). Distinguish "threw at
    // runtime" (rc 1, error_value populated) from a structural failure.
    heap.error_value.set_undefined();
    heap.has_error = false;
    if (!execute_module(heap, vm, mod)) {
        if (heap.has_error || heap.error_value.is_object() || heap.error_value.is_string()) {
            return 1;  // a value was thrown during evaluation
        }
        return 2;  // structural evaluation failure with no thrown value
    }
    return 0;
}

// ============================================================================
// Dynamic import — `import(specifier)` (ES2020)
// ============================================================================

/// Resolve, link and evaluate the module named by `specifier` and return a
/// Promise (as a TVal carrying one caller-owned reference — the caller must
/// decref after storing it) that fulfills with the module's namespace object
/// or rejects with the module's load/evaluation error. Load and evaluation
/// failures reject the returned promise; a fault means promise allocation
/// itself failed.
///
/// Relative specifiers resolve against the running module's name: the
/// currently executing function's filename when it has one, else
/// heap.current_module_name (maintained by execute_module around body runs).
fn TVal? dynamic_import(Heap* heap, Vm* vm, char[] specifier) {
    HObject*? prom_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return MODULE_ERROR~;
    HObject* prom = prom_raw;
    prom.prototype = heap.promise_proto;
    builtins::promise_init(prom);
    prom.as_header().incref();  // caller-owned reference

    // Placeholder: reject unconditionally until the resolution/evaluation
    // implementation lands.
    TVal reason;
    reason.set_undefined();
    builtins::promise_settle(prom, builtins::PROMISE_REJECTED, &reason, heap);
    builtins::promise_trigger_reactions(prom, heap, (void*)vm);

    TVal result;
    result.set_object(prom);
    return result;
}

// ============================================================================
// Helpers
// ============================================================================

/// Resolve an export name to the local binding name in a module's exports table.
/// For most exports local_name == export_name, but for `export default <expr>`
/// the compiler emits local_name="*default*" and export_name="default".
fn char[] resolve_export_local_name(ModuleDef* mod, char[] export_name) {
    for (uint i = 0; i < mod.export_count; i++) {
        ExportEntry* ee = &mod.exports[i];
        if (!ee.is_indirect && char_slice_eq(ee.export_name, export_name)) {
            return ee.local_name;
        }
    }
    return export_name; // fallback: identity
}

/// Build a Module Namespace Object for `import * as ns`.
/// The returned HObject has one own enumerable property per export of source_mod.
fn HObject*? build_namespace_object(Heap* heap, ModuleDef* source_mod) {
    HObject*? ns_opt = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = ns_opt) return MODULE_ERROR~;
    HObject* ns = ns_opt;

    for (uint i = 0; i < source_mod.export_count; i++) {
        ExportEntry* ee = &source_mod.exports[i];
        // Declare the export_name property on the namespace object
        HString* export_key = heap.str_intern(ee.export_name);
        if (export_key == null) continue;

        // Look up the local binding in the source module's env
        char[] lookup_name = ee.is_indirect ? ee.local_name : ee.local_name;
        HString* local_key = heap.str_intern(lookup_name);
        if (local_key == null) continue;

        TVal val;
        if (source_mod.env != null) {
            TVal? val_opt = env::env_get(source_mod.env, local_key);
            if (catch err = val_opt) {
                val.set_undefined();
            } else {
                val = val_opt;
            }
        } else {
            val.set_undefined();
        }

        ns.put_prop(export_key, val, hobject::PROP_FLAGS_WEC);
    }

    return ns;
}

fn bool char_slice_eq(char[] a, char[] b) {
    if (a.len != b.len) return false;
    for (usz i = 0; i < a.len; i++) {
        if (a[i] != b[i]) return false;
    }
    return true;
}
