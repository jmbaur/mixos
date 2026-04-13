#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

void kmod_log_wrapper(void *data, int priority, const char *file, int line,
                      const char *fn, const char *format, va_list args) {

  void (*kmod_log_unwrapped)(int, char *) = (void (*)(int, char *))data;
  char *str;

  if (vasprintf(&str, format, args) < 0)
    return;

  kmod_log_unwrapped(priority, str);

  free(str);
}
