/// Environment / scope-chain module for the Duktape C3 port.
///
/// Provides runtime variable resolution via a scope chain, matching
/// Duktape's var_env / lex_env architecture.
module duktape::env;

import duktape::types;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import libc;

// ============================================================================
// EnvRecord — a single link in the scope chain
// ============================================================================

/// An environment record — a single link in the scope chain.
struct EnvRecord {
    /// Parent scope (null for the global scope).
    EnvRecord* parent;
    /// The object that holds bindings (property name → TVal).
    HObject* bindings;
    /// Is this a declarative (not object) environment?
    bool is_declarative;
}

// ============================================================================
// Creation / destruction
// ============================================================================

/// Create a new object environment record.
fn EnvRecord*? env_create(Heap* heap, EnvRecord* parent) {
    void* raw = libc::malloc(EnvRecord::size);
    if (raw == null) {
        return types::ALLOC_ERROR~;
    }
    libc::memset(raw, 0, EnvRecord::size);

    EnvRecord* env = (EnvRecord*)raw;
    env.parent = parent;
    env.is_declarative = false;

    HObject*? bindings = hobject::hobject_alloc(heap, hobject::ObjClass.OBJECT);
    if (catch err = bindings) {
        libc::free(raw);
        return types::ALLOC_ERROR~;
    }
    env.bindings = bindings;

    return env;
}

/// Create a new declarative environment record.
fn EnvRecord*? env_create_declarative(Heap* heap, EnvRecord* parent) {
    void* raw = libc::malloc(EnvRecord::size);
    if (raw == null) {
        return types::ALLOC_ERROR~;
    }
    libc::memset(raw, 0, EnvRecord::size);

    EnvRecord* env = (EnvRecord*)raw;
    env.parent = parent;
    env.is_declarative = true;

    HObject*? bindings = hobject::hobject_alloc(heap, hobject::ObjClass.OBJECT);
    if (catch err = bindings) {
        libc::free(raw);
        return types::ALLOC_ERROR~;
    }
    env.bindings = bindings;

    return env;
}

/// Destroy an environment record and all its owned resources.
fn void env_destroy(EnvRecord* env) {
    if (env == null) { return; }
    hobject::hobject_free(env.bindings);
    libc::free(env);
}

// ============================================================================
// Variable resolution — scope-chain walk
// ============================================================================

/// Look up a binding by walking the scope chain.
fn TVal? env_get(EnvRecord* env, void* key) {
    EnvRecord* cur = env;
    while (cur != null) {
        if (cur.bindings.has_prop(key)) {
            TVal? result = cur.bindings.get_prop(key);
            if (try v = result) {
                return v;
            }
        }
        cur = cur.parent;
    }
    return hobject::PROP_NOT_FOUND~;
}

/// Check whether a binding exists anywhere in the scope chain.
fn bool env_has(EnvRecord* env, void* key) @inline {
    EnvRecord* cur = env;
    while (cur != null) {
        if (cur.bindings.has_prop(key)) {
            return true;
        }
        cur = cur.parent;
    }
    return false;
}

// ============================================================================
// Mutation — set / declare
// ============================================================================

/// Set a binding value, updating an existing one or creating a new one.
fn bool env_put(EnvRecord* env, void* key, TVal val) {
    EnvRecord* cur = env;
    while (cur != null) {
        if (cur.bindings.has_prop(key)) {
            return cur.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
        }
        cur = cur.parent;
    }
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}

/// Declare a binding in the given environment only (no chain walk).
fn bool env_declare(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}
