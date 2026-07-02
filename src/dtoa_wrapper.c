/*
 * dtoa wrapper — implementation. See dtoa_wrapper.h.
 */
#include <inttypes.h>
#include "dtoa_wrapper.h"
#include "dtoa.h"

double duktape_js_atod(const char *str, const char **pnext, int radix, int flags,
                       void *tmp)
{
    return js_atod(str, pnext, radix, flags, (JSATODTempMem *)tmp);
}