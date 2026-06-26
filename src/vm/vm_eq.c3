module duktape::vm;

import duktape::types;
import duktape::hstring;
import std::math;

fn bool abstract_eq(Vm* vm, TVal* a, TVal* b) {
    // Same type -> strict equality
    if (a.get_tag() == b.get_tag()) {
        return strict_eq(a, b);
    }

    // null/undefined pair
    if ((a.is_null() && b.is_undefined()) ||
        (a.is_undefined() && b.is_null())) {
        return true;
    }

    // NUMBER/FASTINT: treat as same "numeric" type
    if (a.is_number() && b.is_fastint()) {
        return a.get_number() == (double)b.get_fastint();
    }
    if (a.is_fastint() && b.is_number()) {
        return (double)a.get_fastint() == b.get_number();
    }

    // Boolean -> ToNumber
    if (a.is_boolean()) {
        TVal a_num;
        a_num.set_number(a.get_boolean() ? 1.0 : 0.0);
        return abstract_eq(vm, &a_num, b);
    }
    if (b.is_boolean()) {
        TVal b_num;
        b_num.set_number(b.get_boolean() ? 1.0 : 0.0);
        return abstract_eq(vm, a, &b_num);
    }

    // String + Number -> ToNumber(string)
    if (a.is_string() && (b.is_number() || b.is_fastint())) {
        double num = hstring_to_number((HString*)a.get_heapptr());
        if (b.is_fastint()) return num == (double)b.get_fastint();
        return num == b.get_number();
    }
    if (b.is_string() && (a.is_number() || a.is_fastint())) {
        double num = hstring_to_number((HString*)b.get_heapptr());
        if (a.is_fastint()) return (double)a.get_fastint() == num;
        return a.get_number() == num;
    }

    // Object + Boolean/Number/String -> ToPrimitive
    if (a.is_object() && (b.is_boolean() || b.is_number() || b.is_fastint() || b.is_string())) {
        TVal prim = to_primitive_value(vm, a);
        if (!prim.is_object()) {
            return abstract_eq(vm, &prim, b);
        }
        return false;
    }
    if (b.is_object() && (a.is_boolean() || a.is_number() || a.is_fastint() || a.is_string())) {
        TVal prim = to_primitive_value(vm, b);
        if (!prim.is_object()) {
            return abstract_eq(vm, a, &prim);
        }
        return false;
    }

    return false;
}

/// Strict equality check (same as SEQ).
fn bool strict_eq(TVal* a, TVal* b) @inline {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) && math::is_nan(b.get_number())) return false;
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING: {
                HString* sa = (HString*)a.get_heapptr();
                HString* sb = (HString*)b.get_heapptr();
                return sa != null && sb != null && sa.equals_hstring(sb);
            }
            case OBJECT:    return a.get_heapptr() == b.get_heapptr();
            default:        return false;
        }
    }
    // NUMBER and FASTINT are the same ES type
    if (a.is_number() && b.is_fastint()) {
        return a.get_number() == (double)b.get_fastint();
    }
    if (a.is_fastint() && b.is_number()) {
        return (double)a.get_fastint() == b.get_number();
    }
    return false;
}
