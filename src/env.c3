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
    /// Is this a `with`-statement environment? When true, env_put
    /// skips this record when creating new bindings (unresolvable
    /// references go to the enclosing non-with scope).
    bool is_with;
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

/// Create a new `with` environment record wrapping an existing HObject.
///
/// Unlike `env_create`, this does NOT allocate a new bindings object —
/// it uses the caller-supplied object directly. The `is_with` flag is
/// set so that `env_put` skips this record when creating *new* bindings
/// (spec-compliant: unresolvable references inside `with` go to the
/// enclosing scope, not to the with-object).
fn EnvRecord*? env_create_with_object(EnvRecord* parent, HObject* bindings) {
    void* raw = libc::malloc(EnvRecord::size);
    if (raw == null) {
        return types::ALLOC_ERROR~;
    }
    libc::memset(raw, 0, EnvRecord::size);

    EnvRecord* env = (EnvRecord*)raw;
    env.parent = parent;
    env.bindings = bindings;
    env.is_declarative = false;
    env.is_with = true;

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
///
/// For `with`-env records (`is_with == true`) we walk the prototype
/// chain of the bindings object (ES5 §10.2.1.2.1 — HasBinding uses
/// [[HasProperty]]).  For declarative envs we only check own properties.
fn TVal? env_get(EnvRecord* env, void* key) {
    EnvRecord* cur = env;
    while (cur != null) {
        if (cur.is_with) {
            if (cur.bindings.has_prop_proto(key)) {
                TVal? result = cur.bindings.get_prop_proto(key);
                if (try v = result) {
                    return v;
                }
            }
        } else {
            if (cur.bindings.has_prop(key)) {
                TVal? result = cur.bindings.get_prop(key);
                if (try v = result) {
                    return v;
                }
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
        bool found = cur.is_with
                     ? cur.bindings.has_prop_proto(key)
                     : cur.bindings.has_prop(key);
        if (found) {
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
///
/// When the variable is found in an existing env record (including
/// with-envs), it is updated in-place.  When the variable is NOT found
/// anywhere, the new binding is created in the first *non-with* record
/// (the function/global scope) — this is the ES5-spec-compliant
/// behaviour for unresolvable references inside `with` blocks.
///
/// For `with`-envs (`is_with == true`) we walk the prototype chain
/// when checking for existing bindings (matching [[HasProperty]]).
fn bool env_put(EnvRecord* env, void* key, TVal val) {
    EnvRecord* cur = env;
    EnvRecord* first_non_with = null;
    while (cur != null) {
        bool found = cur.is_with
                     ? cur.bindings.has_prop_proto(key)
                     : cur.bindings.has_prop(key);
        if (found) {
            return cur.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
        }
        if (!cur.is_with && first_non_with == null) {
            first_non_with = cur;
        }
        cur = cur.parent;
    }
    // Not found in the entire chain — create in the first non-with scope
    // (which is the function/global scope that contains the with block).
    EnvRecord* target = (first_non_with != null) ? first_non_with : env;
    return target.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}

/// Declare a binding in the given environment only (no chain walk).
fn bool env_declare(EnvRecord* env, void* key, TVal val) @inline {
    return env.bindings.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}
