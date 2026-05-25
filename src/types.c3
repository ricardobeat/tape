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

/// A tagged value – the universal currency of the value stack.
///
/// Uses an explicit tag + union rather than NaN-boxing so that the
/// representation is clear and the compiler can optimise discriminated
/// access.
/// FASTINT uses 52-bit signed integer range (fits in double mantissa exactly).
const long FASTINT_MIN = -2251799813685248L;  // -2^51
const long FASTINT_MAX =  2251799813685247L;  //  2^51 - 1

struct TVal {
    TValTag tag;
    union {
        bool    boolean;
        double  number;
        long    fastint;
        void*   pointer;
    }
}

// ---------------------------------------------------------------------------
// TVal — type predicates
// ---------------------------------------------------------------------------

/// Returns true when the value is ECMAScript undefined.
fn bool TVal.is_undefined(&self)      { return self.tag == UNDEFINED; }
/// Returns true when the value is ECMAScript null.
fn bool TVal.is_null(&self)           { return self.tag == NULL_VAL; }
/// Returns true when the value is a boolean.
fn bool TVal.is_boolean(&self)        { return self.tag == BOOLEAN; }
/// Returns true when the value is a double-precision number.
fn bool TVal.is_number(&self)         { return self.tag == NUMBER; }
/// Returns true when the value is a fast integer.
fn bool TVal.is_fastint(&self)        { return self.tag == FASTINT; }
/// Returns true when the value is a heap-allocated string.
fn bool TVal.is_string(&self)         { return self.tag == STRING; }
/// Returns true when the value is a heap-allocated object.
fn bool TVal.is_object(&self)         { return self.tag == OBJECT; }
/// Returns true when the value is a heap-allocated buffer.
fn bool TVal.is_buffer(&self)         { return self.tag == BUFFER; }
/// Returns true when the value is a raw pointer.
fn bool TVal.is_pointer(&self)        { return self.tag == POINTER; }
/// Returns true when the value is a lightweight function.
fn bool TVal.is_lightfunc(&self)      { return self.tag == LIGHTFUNC; }

/// Returns true when the value is either undefined or null
/// (the two "nullish" values in ECMAScript).
fn bool TVal.is_nullish(&self) {
    return self.tag == UNDEFINED || self.tag == NULL_VAL;
}

/// Returns true when the value is any numeric type (double or fastint).
fn bool TVal.is_numeric(&self) {
    return self.tag == NUMBER || self.tag == FASTINT;
}

/// Returns true when the value holds a GC-managed heap pointer
/// (string, object, or buffer).
fn bool TVal.is_heap_allocated(&self) {
    return self.tag == STRING || self.tag == OBJECT || self.tag == BUFFER;
}

// ---------------------------------------------------------------------------
// TVal — getters
// ---------------------------------------------------------------------------

/// Retrieves the boolean payload.  Undefined behaviour when tag != BOOLEAN.
fn bool   TVal.get_boolean(&self)  { return self.boolean; }
/// Retrieves the double payload.  Undefined behaviour when tag != NUMBER.
fn double TVal.get_number(&self)   { return self.number; }
/// Retrieves the fast-integer payload.  Undefined behaviour when tag != FASTINT.
fn long   TVal.get_fastint(&self)  { return self.fastint; }
/// Retrieves the pointer payload (valid for STRING, OBJECT, BUFFER,
/// POINTER, and LIGHTFUNC tags).
fn void*  TVal.get_heapptr(&self)  { return self.pointer; }

/// Returns the numeric value as a double, promoting a fastint if necessary.
fn double TVal.get_number_or_fastint(&self) {
    if (self.tag == FASTINT) {
        return (double)self.fastint;
    }
    return self.number;
}

// ---------------------------------------------------------------------------
// TVal — mutating setters
// ---------------------------------------------------------------------------

/// Overwrites the slot with undefined.
fn void TVal.set_undefined(&self) @inline {
    self.tag     = UNDEFINED;
    self.pointer = null;
}

/// Overwrites the slot with null.
fn void TVal.set_null(&self) @inline {
    self.tag     = NULL_VAL;
    self.pointer = null;
}

/// Overwrites the slot with a boolean.
fn void TVal.set_boolean(&self, bool val) @inline {
    self.tag     = BOOLEAN;
    self.boolean = val;
}

/// Overwrites the slot with a double-precision number.
fn void TVal.set_number(&self, double val) @inline {
    self.tag    = NUMBER;
    self.number = val;
}

/// Overwrites the slot with a fast integer.
fn void TVal.set_fastint(&self, long val) @inline {
    self.tag     = FASTINT;
    self.fastint = val;
}

/// Overwrites the slot with a heap string pointer.
fn void TVal.set_string(&self, void* ptr) {
    self.tag     = STRING;
    self.pointer = ptr;
}

/// Overwrites the slot with a heap object pointer.
fn void TVal.set_object(&self, void* ptr) {
    self.tag     = OBJECT;
    self.pointer = ptr;
}

/// Overwrites the slot with a heap buffer pointer.
fn void TVal.set_buffer(&self, void* ptr) {
    self.tag     = BUFFER;
    self.pointer = ptr;
}

/// Overwrites the slot with a raw pointer.
fn void TVal.set_pointer(&self, void* ptr) {
    self.tag     = POINTER;
    self.pointer = ptr;
}

/// Overwrites the slot with a lightweight function pointer.
fn void TVal.set_lightfunc(&self, void* ptr) {
    self.tag     = LIGHTFUNC;
    self.pointer = ptr;
}

// ---------------------------------------------------------------------------
// TVal — static constructors
// ---------------------------------------------------------------------------

/// Creates a TVal representing undefined.
fn TVal make_undefined() {
    return (TVal){ .tag = UNDEFINED };
}

/// Creates a TVal representing null.
fn TVal make_null() {
    return (TVal){ .tag = NULL_VAL };
}

/// Creates a TVal from a boolean.
fn TVal make_boolean(bool val) {
    TVal tv;
    tv.tag     = BOOLEAN;
    tv.boolean = val;
    return tv;
}

/// Creates a TVal from a double-precision number.
fn TVal make_number(double val) {
    TVal tv;
    tv.tag    = NUMBER;
    tv.number = val;
    return tv;
}

/// Creates a TVal from a fast integer.
fn TVal make_fastint(long val) {
    TVal tv;
    tv.tag     = FASTINT;
    tv.fastint = val;
    return tv;
}

/// Creates a TVal from a heap string pointer.
fn TVal make_string(void* ptr) {
    TVal tv;
    tv.tag     = STRING;
    tv.pointer = ptr;
    return tv;
}

/// Creates a TVal from a heap object pointer.
fn TVal make_object(void* ptr) {
    TVal tv;
    tv.tag     = OBJECT;
    tv.pointer = ptr;
    return tv;
}

/// Creates a TVal from a heap buffer pointer.
fn TVal make_buffer(void* ptr) {
    TVal tv;
    tv.tag     = BUFFER;
    tv.pointer = ptr;
    return tv;
}

/// Creates a TVal from a raw pointer.
fn TVal make_pointer(void* ptr) {
    TVal tv;
    tv.tag     = POINTER;
    tv.pointer = ptr;
    return tv;
}

/// Creates a TVal from a lightweight function pointer.
fn TVal make_lightfunc(void* ptr) {
    TVal tv;
    tv.tag     = LIGHTFUNC;
    tv.pointer = ptr;
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
