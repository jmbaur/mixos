#include <stdarg.h>

void kmod_log_wrapper(void *data, int priority, const char *file, int line,
                      const char *fn, const char *format, va_list args);
