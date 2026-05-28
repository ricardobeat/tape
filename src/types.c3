/// Core types for the Duktape JavaScript engine.
///
/// This module defines the fundamental value representation (TVal),
/// garbage-collected heap object headers (HeapHeader), portable type
/// aliases, numeric constants, and engine fault codes.
module duktape::types;

// ============================================================================
// Portable type aliases
// ============================================================================

/// 32-bit signed integer used throughout the API.
alias DukInt       = int;
/// 32-bit unsigned integer.
alias DukUint      = uint;
/// Platform-native size type.
alias DukSize      = usz;
/// Value-stack index (signed so negative indices work).
alias DukIdx       = int;
/// Compact signed integer for space-sensitive structures.
alias DukSmallInt  = short;
/// Compact unsigned integer.
alias DukSmallUint = ushort;
/// Boolean (mirrors the built-in bool).
alias DukBool      = bool;
/// IEEE 754 double precision float.
alias DukDouble    = double;
/// Unicode codepoint (U+0000 .. U+10FFFF).
alias DukCodepoint = uint;

// ============================================================================
// Common constants
// ============================================================================

/// IEEE 754 Not-a-Number.
const double DUK_DOUBLE_NAN      = double::nan;
/// IEEE 754 positive infinity.
const double DUK_DOUBLE_INFINITY = double::inf;
/// Sentinel returned when a stack index is invalid.
const int    DUK_INVALID_INDEX   = int::min;
/// Maximum safe integer representable in a double (2^53 - 1).
const long   DUK_MAX_SAFE_INT    = 9007199254740991;
/// Minimum safe integer representable in a double -(2^53 - 1).
const long   DUK_MIN_SAFE_INT    = -9007199254740991;

// ============================================================================
// Fault codes (used with C3's faultdef / optional error handling)
// ============================================================================

/// Memory allocation failure.
faultdef ALLOC_ERROR;
/// ECMAScript TypeError.
faultdef TYPE_ERROR;
/// ECMAScript RangeError.
faultdef RANGE_ERROR;
/// ECMAScript SyntaxError.
faultdef SYNTAX_ERROR;
/// ECMAScript ReferenceError.
faultdef REFERENCE_ERROR;
/// ECMAScript URIError.
faultdef URI_ERROR;
/// ECMAScript EvalError.
faultdef EVAL_ERROR;
/// Internal engine error (bug or unrecoverable condition).
faultdef INTERNAL_ERROR;
/// Public C API misuse.
faultdef API_ERROR;

// ============================================================================
// TVal — Tagged value (the core JS value representation)
// ============================================================================

/// Discriminator for the payload stored inside a TVal.
enum TValTag : char {
    /// ECMAScript undefined.
    UNDEFINED,
    /// ECMAScript null.
    NULL_VAL,
    /// ECMAScript boolean (true / false).
    BOOLEAN,
    /// IEEE 754 double – the general ECMAScript number type.
    NUMBER,
    /// 48-bit fast integer optimisation path.
    FASTINT,
    /// Pointer to a heap-allocated HString.
    STRING,
    /// Pointer to a heap-allocated HObject.
    OBJECT,
    /// Pointer to a heap-allocated HBuffer.
    BUFFER,
    /// Raw void* exposed to user code.
    POINTER,
    /// Lightweight function pointer (no heap allocation).
    LIGHTFUNC,
}

/// FASTINT uses 52-bit signed integer range (fits in double mantissa exactly).
const long FASTINT_MIN = -2251799813685248L;  // -2^51
const long FASTINT_MAX =  2251799813685247L;  //  2^51 - 1

/// Toggle for NaN-boxing representation. When true, TVal is an 8-byte
/// NaN-boxed ulong. When false, TVal is the 16-byte tagged union.
const bool USE_NANBOX = true;

// ============================================================================
// NaN-boxing constants and helpers (used when USE_NANBOX = true)
// ============================================================================

const ulong NANBOX_BASE     = 0xFFF8000000000000;
const ulong NANBOX_TAG_MASK = 0x0000FF0000000000;  // bits 47-40
const ulong NANBOX_PAYLOAD_MASK = 0x000000FFFFFFFFFF;  // bits 39-0
const int   NANBOX_TAG_SHIFT = 40;

/// Tag values for NaN-boxed representation. Ordinals match TValTag.
const ulong TAG_UNDEFINED  = 0;
const ulong TAG_NULL_VAL   = 1;
const ulong TAG_BOOLEAN    = 2;
const ulong TAG_FASTINT    = 3;  // same ordinal as TValTag.FASTINT
const ulong TAG_STRING     = 4;
const ulong TAG_OBJECT     = 5;  // same ordinal as TValTag.OBJECT
const ulong TAG_BUFFER     = 6;
const ulong TAG_POINTER    = 7;
const ulong TAG_LIGHTFUNC  = 8;

fn ulong nanbox_encode_tagged(ulong tag, ulong payload) @inline {
    return NANBOX_BASE | (tag << NANBOX_TAG_SHIFT) | (payload & NANBOX_PAYLOAD_MASK);
}

fn bool nanbox_is_double(ulong v) @inline {
    return ((v >> 52) & 0x7FF) != 0x7FF;
}

fn ulong nanbox_get_tag(ulong v) @inline {
    return (v & NANBOX_TAG_MASK) >> NANBOX_TAG_SHIFT;
}

fn ulong nanbox_get_payload(ulong v) @inline {
    return v & NANBOX_PAYLOAD_MASK;
}

/// A tagged value – the universal currency of the value stack.
struct TVal @if(USE_NANBOX) {
    /// NaN-boxed: 8-byte representation.
    ulong bits;
}

struct TVal @if(!USE_NANBOX) {
    /// Explicit tag + union: 16-byte representation.
    TValTag tag;
    union {
        bool    boolean;
        double  number;
        long    fastint;
        void*   pointer;
    }
}

// ---------------------------------------------------------------------------
// TVal — tag query (for switch statements)
// ---------------------------------------------------------------------------

/// Returns the TValTag discriminator. In the NaN-box path, this decodes
/// from the NaN-box tag bits.
fn TValTag TVal.get_tag(&self) @inline {
$if USE_NANBOX:
    if (nanbox_is_double(self.bits)) return NUMBER;
    switch (nanbox_get_tag(self.bits)) {
        case TAG_UNDEFINED:  return UNDEFINED;
        case TAG_NULL_VAL:   return NULL_VAL;
        case TAG_BOOLEAN:    return BOOLEAN;
        case TAG_FASTINT:    return FASTINT;
        case TAG_STRING:     return STRING;
        case TAG_OBJECT:     return OBJECT;
        case TAG_BUFFER:     return BUFFER;
        case TAG_POINTER:    return POINTER;
        case TAG_LIGHTFUNC:  return LIGHTFUNC;
        default:             return UNDEFINED;
    }
$else
    return self.tag;
$endif
}

// ---------------------------------------------------------------------------
// TVal — type predicates
// ---------------------------------------------------------------------------

fn bool TVal.is_undefined(&self) @inline {
$if USE_NANBOX:
    return self.bits == NANBOX_BASE;
$else
    return self.tag == UNDEFINED;
$endif
}

fn bool TVal.is_null(&self) @inline {
$if USE_NANBOX:
    return self.bits == nanbox_encode_tagged(TAG_NULL_VAL, 0);
$else
    return self.tag == NULL_VAL;
$endif
}

fn bool TVal.is_boolean(&self) @inline {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_BOOLEAN;
$else
    return self.tag == BOOLEAN;
$endif
}

fn bool TVal.is_number(&self) @inline {
$if USE_NANBOX:
    return nanbox_is_double(self.bits);
$else
    return self.tag == NUMBER;
$endif
}

fn bool TVal.is_fastint(&self) @inline {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_FASTINT;
$else
    return self.tag == FASTINT;
$endif
}

fn bool TVal.is_string(&self) @inline {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_STRING;
$else
    return self.tag == STRING;
$endif
}

fn bool TVal.is_object(&self) @inline {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_OBJECT;
$else
    return self.tag == OBJECT;
$endif
}

fn bool TVal.is_buffer(&self) @inline {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_BUFFER;
$else
    return self.tag == BUFFER;
$endif
}

fn bool TVal.is_pointer(&self) @inline {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_POINTER;
$else
    return self.tag == POINTER;
$endif
}

fn bool TVal.is_lightfunc(&self) @inline {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_LIGHTFUNC;
$else
    return self.tag == LIGHTFUNC;
$endif
}

fn bool TVal.is_nullish(&self) @inline {
$if USE_NANBOX:
    return self.is_undefined() || self.is_null();
$else
    return self.tag == UNDEFINED || self.tag == NULL_VAL;
$endif
}

fn bool TVal.is_numeric(&self) @inline {
$if USE_NANBOX:
    return nanbox_is_double(self.bits) || nanbox_get_tag(self.bits) == TAG_FASTINT;
$else
    return self.tag == NUMBER || self.tag == FASTINT;
$endif
}

fn bool TVal.is_heap_allocated(&self) @inline {
$if USE_NANBOX:
    ulong tag = nanbox_get_tag(self.bits);
    return tag == TAG_STRING || tag == TAG_OBJECT || tag == TAG_BUFFER;
$else
    return self.tag == STRING || self.tag == OBJECT || self.tag == BUFFER;
$endif
}

// ---------------------------------------------------------------------------
// TVal — getters
// ---------------------------------------------------------------------------

fn bool TVal.get_boolean(&self) @inline {
$if USE_NANBOX:
    return nanbox_get_payload(self.bits) != 0;
$else
    return self.boolean;
$endif
}

fn double TVal.get_number(&self) @inline {
$if USE_NANBOX:
    return bitcast(self.bits, double);
$else
    return self.number;
$endif
}

fn long TVal.get_fastint(&self) @inline {
$if USE_NANBOX:
    ulong payload = nanbox_get_payload(self.bits);
    if (payload & (1L << 39) != 0) {
        // Negative: sign-extend from 40-bit two's complement
        return (long)(payload | 0xFFFFFF0000000000);
    }
    return (long)payload;
$else
    return self.fastint;
$endif
}

fn void* TVal.get_heapptr(&self) @inline {
$if USE_NANBOX:
    return (void*)nanbox_get_payload(self.bits);
$else
    return self.pointer;
$endif
}

fn double TVal.get_number_or_fastint(&self) @inline {
$if USE_NANBOX:
    if (nanbox_get_tag(self.bits) == TAG_FASTINT) {
        return (double)self.get_fastint();
    }
    return bitcast(self.bits, double);
$else
    if (self.tag == FASTINT) {
        return (double)self.fastint;
    }
    return self.number;
$endif
}

// ---------------------------------------------------------------------------
// TVal — mutating setters
// ---------------------------------------------------------------------------

fn void TVal.set_undefined(&self) @inline {
$if USE_NANBOX:
    self.bits = NANBOX_BASE;
$else
    self.tag     = UNDEFINED;
    self.pointer = null;
$endif
}

fn void TVal.set_null(&self) @inline {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_NULL_VAL, 0);
$else
    self.tag     = NULL_VAL;
    self.pointer = null;
$endif
}

fn void TVal.set_boolean(&self, bool val) @inline {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_BOOLEAN, val ? 1 : 0);
$else
    self.tag     = BOOLEAN;
    self.boolean = val;
$endif
}

fn void TVal.set_number(&self, double val) @inline {
$if USE_NANBOX:
    self.bits = bitcast(val, ulong);
$else
    self.tag    = NUMBER;
    self.number = val;
$endif
}

fn void TVal.set_fastint(&self, long val) @inline {
$if USE_NANBOX:
    // Two's complement in 40-bit payload: negative values wrap naturally
    self.bits = nanbox_encode_tagged(TAG_FASTINT, (ulong)val);
$else
    self.tag     = FASTINT;
    self.fastint = val;
$endif
}

fn void TVal.set_string(&self, void* ptr) @inline {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_STRING, (usz)ptr);
$else
    self.tag     = STRING;
    self.pointer = ptr;
$endif
}

fn void TVal.set_object(&self, void* ptr) @inline {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_OBJECT, (usz)ptr);
$else
    self.tag     = OBJECT;
    self.pointer = ptr;
$endif
}

fn void TVal.set_buffer(&self, void* ptr) @inline {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_BUFFER, (usz)ptr);
$else
    self.tag     = BUFFER;
    self.pointer = ptr;
$endif
}

fn void TVal.set_pointer(&self, void* ptr) @inline {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_POINTER, (usz)ptr);
$else
    self.tag     = POINTER;
    self.pointer = ptr;
$endif
}

fn void TVal.set_lightfunc(&self, void* ptr) @inline {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_LIGHTFUNC, (usz)ptr);
$else
    self.tag     = LIGHTFUNC;
    self.pointer = ptr;
$endif
}

// ---------------------------------------------------------------------------
// TVal — static constructors
// ---------------------------------------------------------------------------

fn TVal make_undefined() @inline {
$if USE_NANBOX:
    TVal tv;
    tv.bits = NANBOX_BASE;
    return tv;
$else
    return (TVal){ .tag = UNDEFINED };
$endif
}

fn TVal make_null() @inline {
$if USE_NANBOX:
    TVal tv;
    tv.bits = nanbox_encode_tagged(TAG_NULL_VAL, 0);
    return tv;
$else
    return (TVal){ .tag = NULL_VAL };
$endif
}

fn TVal make_boolean(bool val) @inline {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_BOOLEAN, val ? 1 : 0);
$else
    tv.tag     = BOOLEAN;
    tv.boolean = val;
$endif
    return tv;
}

fn TVal make_number(double val) @inline {
    TVal tv;
$if USE_NANBOX:
    tv.bits = bitcast(val, ulong);
$else
    tv.tag    = NUMBER;
    tv.number = val;
$endif
    return tv;
}

fn TVal make_fastint(long val) @inline {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_FASTINT, (ulong)val);
$else
    tv.tag     = FASTINT;
    tv.fastint = val;
$endif
    return tv;
}

fn TVal make_string(void* ptr) @inline {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_STRING, (usz)ptr);
$else
    tv.tag     = STRING;
    tv.pointer = ptr;
$endif
    return tv;
}

fn TVal make_object(void* ptr) @inline {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_OBJECT, (usz)ptr);
$else
    tv.tag     = OBJECT;
    tv.pointer = ptr;
$endif
    return tv;
}

fn TVal make_buffer(void* ptr) @inline {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_BUFFER, (usz)ptr);
$else
    tv.tag     = BUFFER;
    tv.pointer = ptr;
$endif
    return tv;
}

fn TVal make_pointer(void* ptr) @inline {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_POINTER, (usz)ptr);
$else
    tv.tag     = POINTER;
    tv.pointer = ptr;
$endif
    return tv;
}

fn TVal make_lightfunc(void* ptr) @inline {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_LIGHTFUNC, (usz)ptr);
$else
    tv.tag     = LIGHTFUNC;
    tv.pointer = ptr;
$endif
    return tv;
}

// ============================================================================
// HeapHeader — common header for all GC-managed objects
// ============================================================================

/// Discriminator for the three heap-allocated object families.
enum HType : char {
    STRING,
    OBJECT,
    BUFFER,
}

/// Bit-packed flags stored at the front of every heap header.
///
/// Bits 0-1:  heap type (HType)
/// Bit  2:    reachable by the mark phase
/// Bit  3:    temporary root during incremental GC
/// Bit  4:    has a C finalizer attached
/// Bit  5:    the finalizer has already run
/// Bit  6:    the object is read-only
/// Bits 7-31: available for subtype-specific flags
bitstruct HeapFlags : uint {
    HType htype        : 0..1;
    bool  reachable    : 2;
    bool  temproot     : 3;
    bool  finalizable  : 4;
    bool  finalized    : 5;
    bool  readonly     : 6;
}

/// Every GC-managed object begins with this header.  The doubly-linked
/// list (next / prev) threads all live heap objects together so the
/// sweep phase can walk them.
struct HeapHeader {
    HeapFlags    flags;
    uint         refcount;
    HeapHeader*  next;
    HeapHeader*  prev;
}

// ---------------------------------------------------------------------------
// HeapHeader — type queries
// ---------------------------------------------------------------------------

/// Returns the HType stored in the flags word.
fn HType HeapHeader.get_type(&self)  { return self.flags.htype; }
/// Returns true when this header belongs to an object.
fn bool  HeapHeader.is_object(&self) { return self.flags.htype == HType.OBJECT; }
/// Returns true when this header belongs to a string.
fn bool  HeapHeader.is_string(&self) { return self.flags.htype == HType.STRING; }
/// Returns true when this header belongs to a buffer.
fn bool  HeapHeader.is_buffer(&self) { return self.flags.htype == HType.BUFFER; }

// ---------------------------------------------------------------------------
// HeapHeader — flag accessors
// ---------------------------------------------------------------------------

/// Marks the object as reachable (used by the mark phase).
fn void HeapHeader.set_reachable(&self)     { self.flags.reachable = true; }
/// Clears the reachable flag (used before a new mark pass).
fn void HeapHeader.clear_reachable(&self)   { self.flags.reachable = false; }
/// Returns true when the object has been marked reachable.
fn bool HeapHeader.is_reachable(&self)      { return self.flags.reachable; }

/// Marks the object as a temporary root for incremental GC.
fn void HeapHeader.set_temproot(&self)      { self.flags.temproot = true; }
/// Clears the temporary-root flag.
fn void HeapHeader.clear_temproot(&self)    { self.flags.temproot = false; }
/// Returns true when the object is a temporary root.
fn bool HeapHeader.is_temproot(&self)       { return self.flags.temproot; }

/// Marks the object as having a C finalizer.
fn void HeapHeader.set_finalizable(&self)   { self.flags.finalizable = true; }
/// Clears the finalizable flag.
fn void HeapHeader.clear_finalizable(&self) { self.flags.finalizable = false; }
/// Returns true when the object has a finalizer.
fn bool HeapHeader.is_finalizable(&self)    { return self.flags.finalizable; }

/// Marks the object's finalizer as having already run.
fn void HeapHeader.set_finalized(&self)     { self.flags.finalized = true; }
/// Clears the finalized flag (re-arms the finalizer).
fn void HeapHeader.clear_finalized(&self)   { self.flags.finalized = false; }
/// Returns true when the finalizer has already executed.
fn bool HeapHeader.is_finalized(&self)      { return self.flags.finalized; }

/// Marks the object as read-only.
fn void HeapHeader.set_readonly(&self)      { self.flags.readonly = true; }
/// Clears the read-only flag.
fn void HeapHeader.clear_readonly(&self)    { self.flags.readonly = false; }
/// Returns true when the object is read-only.
fn bool HeapHeader.is_readonly(&self)       { return self.flags.readonly; }

// ---------------------------------------------------------------------------
// HeapHeader — reference counting helpers
// ---------------------------------------------------------------------------

/// Increments the reference count by one.
fn void HeapHeader.incref(&self) {
    self.refcount++;
}

/// Decrements the reference count and returns the new count.
/// When the returned value is zero the caller is responsible for
/// destroying the object.
fn uint HeapHeader.decref(&self) {
    self.refcount--;
    return self.refcount;
}

// ---------------------------------------------------------------------------
// HeapHeader — linked-list helpers
// ---------------------------------------------------------------------------

/// Initialises the header for a freshly allocated heap object of the
/// given htype.  Links it at the head of the heap list whose current
/// head is *list_head.
fn void HeapHeader.init(&self, HType htype, HeapHeader** list_head) {
    self.flags       = {};
    self.flags.htype = htype;
    self.refcount    = 0;
    self.prev        = null;
    self.next        = *list_head;
    if (*list_head != null) {
        (*list_head).prev = self;
    }
    *list_head = self;
}

/// Unlinks this header from its doubly-linked heap list.  Callers must
/// still free the underlying memory.
fn void HeapHeader.unlink(&self, HeapHeader** list_head) {
    if (self.prev != null) {
        self.prev.next = self.next;
    } else {
        *list_head = self.next;
    }
    if (self.next != null) {
        self.next.prev = self.prev;
    }
    self.next = null;
    self.prev = null;
}
