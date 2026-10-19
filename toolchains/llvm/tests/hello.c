// End-to-end check of the hermetic LLVM toolchain: libc (stdio, malloc,
// string formatting, files), compiler-rt builtins (128-bit division) and the
// start files (constructors, exit status).
//
// Prints a greeting, or writes it to the file named by the first argument.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int constructed;

__attribute__((constructor)) static void init(void) { constructed = 1; }

int main(int argc, char **argv) {
  if (!constructed) {
    fprintf(stderr, "constructor did not run\n");
    return 1;
  }

  // Lowered to __udivti3 from libclang_rt.builtins.
  volatile unsigned __int128 big = (unsigned __int128)UINT64_MAX * 1000;
  uint64_t quotient = (uint64_t)(big / 1000);
  if (quotient != UINT64_MAX) {
    fprintf(stderr, "128-bit division is wrong\n");
    return 1;
  }

  char *greeting = malloc(64);
  if (greeting == NULL) {
    return 1;
  }
  snprintf(greeting, 64, "hello from a hermetic toolchain");
  if (strcmp(greeting, "hello from a hermetic toolchain") != 0) {
    return 1;
  }

  FILE *out = stdout;
  if (argc > 1 && (out = fopen(argv[1], "w")) == NULL) {
    perror(argv[1]);
    return 1;
  }
  fprintf(out, "%s\n", greeting);
  free(greeting);
  return fclose(out) == 0 ? 0 : 1;
}
