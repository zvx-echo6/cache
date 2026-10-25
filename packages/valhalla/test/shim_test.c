/* Tiny C test for valhalla_shim.
 * usage: valhalla_shim_test <config.json> <route|matrix|locate|trace_attributes> <request.json> [repeats] [-q] [-o out.json]
 * Prints init time, per-call time, response size; the response body unless -q. */
#include "valhalla_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
static double now_ms(void) {
  LARGE_INTEGER f, c;
  QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&c);
  return 1000.0 * (double)c.QuadPart / (double)f.QuadPart;
}
#else
#include <time.h>
static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}
#endif

static char* read_file(const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char* buf = (char*)malloc((size_t)n + 1);
  size_t got = fread(buf, 1, (size_t)n, f);
  buf[got] = 0;
  fclose(f);
  return buf;
}

int main(int argc, char** argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s <config.json> <route|matrix|locate|trace_attributes> <request.json> [repeats] [-q] [-o out.json]\n", argv[0]);
    return 2;
  }
  int repeats = 1, quiet = 0;
  const char* outpath = NULL;
  for (int i = 4; i < argc; i++) {
    if (!strcmp(argv[i], "-q")) quiet = 1;
    else if (!strcmp(argv[i], "-o") && i + 1 < argc) outpath = argv[++i];
    else repeats = atoi(argv[i]);
  }
  char* req = read_file(argv[3]);
  if (!req) { fprintf(stderr, "cannot read %s\n", argv[3]); return 2; }

  printf("valhalla %s\n", valhalla_shim_version());
  double t0 = now_ms();
  valhalla_shim_t* h = valhalla_shim_init(argv[1]);
  if (!h) { fprintf(stderr, "init failed: %s\n", valhalla_shim_last_error(NULL)); return 1; }
  printf("init_ms %.1f\n", now_ms() - t0);

  for (int i = 0; i < repeats; i++) {
    double t1 = now_ms();
    char* out = NULL;
    if (!strcmp(argv[2], "route")) out = valhalla_shim_route(h, req);
    else if (!strcmp(argv[2], "matrix")) out = valhalla_shim_matrix(h, req);
    else if (!strcmp(argv[2], "locate")) out = valhalla_shim_locate(h, req);
    else if (!strcmp(argv[2], "trace_attributes")) out = valhalla_shim_trace_attributes(h, req);
    else { fprintf(stderr, "unknown action %s\n", argv[2]); return 2; }
    double dt = now_ms() - t1;
    if (!out) { fprintf(stderr, "call failed: %s\n", valhalla_shim_last_error(h)); return 1; }
    printf("call %d %s_ms %.1f bytes %zu\n", i + 1, argv[2], dt, strlen(out));
    if (!quiet && i == 0) printf("%s\n", out);
    if (outpath && i == 0) { FILE* o = fopen(outpath, "wb"); if (o) { fwrite(out, 1, strlen(out), o); fclose(o); } }
    valhalla_shim_string_free(out);
  }
  valhalla_shim_destroy(h);
  free(req);
  return 0;
}
