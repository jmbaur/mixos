#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

void kmod_log_wrapper(void *data, int priority, const char *file, int line,
                      const char *fn, const char *format, va_list args) {

  void (*inner_log_fn)(int, char *) = (void (*)(int, char *))data;

  char *str;

  if (vasprintf(&str, format, args) < 0)
    return;

  inner_log_fn(priority, str);

  free(str);
}
