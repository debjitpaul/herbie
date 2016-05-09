#define _POSIX_C_SOURCE 199309L
#include <tgmath.h>
#include <time.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <gmp.h>
#include <mpfr.h>

#ifdef __MACH__
#include <mach/clock.h>
#include <mach/mach.h>
#endif

#define ITERS 1000000

#ifndef NARGS
#define NARGS 1
#endif

#if NARGS == 1
#define ARGMAP(f, ...) f(0, __VA_ARGS__)
#elif NARGS == 2
#define ARGMAP(f, ...) f(0, __VA_ARGS__), f(1, __VA_ARGS__)
#elif NARGS == 3
#define ARGMAP(f, ...) f(0, __VA_ARGS__), f(1, __VA_ARGS__), f(2, __VA_ARGS__)
#elif NARGS == 4
#define ARGMAP(f, ...) f(0, __VA_ARGS__), f(1, __VA_ARGS__), f(2, __VA_ARGS__), f(3, __VA_ARGS__)
#elif NARGS == 5
#define ARGMAP(f, ...) f(0, __VA_ARGS__), f(1, __VA_ARGS__), f(2, __VA_ARGS__), f(3, __VA_ARGS__), f(4, __VA_ARGS__)
#elif NARGS == 6
#define ARGMAP(f, ...) f(0, __VA_ARGS__), f(1, __VA_ARGS__), f(2, __VA_ARGS__), f(3, __VA_ARGS__), f(4, __VA_ARGS__), f(5, __VA_ARGS__)
#else
#define ARGMAP(f, ...) abort()
#endif

#define SND(a, b) b
#define ARGS(t) ARGMAP(SND, t)

void setup_mpfr_f_im(void);
void setup_mpfr_f_fm(void);
void setup_mpfr_f_dm(void);
double f_if(ARGS(float));
double f_id(ARGS(double));
double f_im(ARGS(double));
double f_of(ARGS(float));
double f_od(ARGS(double));
double f_om(ARGS(double));
extern char *name;

typedef unsigned long long int u64;
typedef unsigned int u32;
typedef signed long long int i64;
typedef signed int i32;

u32 ulpf(float x, float y) {
        i32 xx, yy;

        if (x == 0) x = fabsf(x); // -0 == 0
        if (y == 0) y = fabsf(y); // -0 == 0

        if (x != x && y != y) return 0;
        if (x != x) return INT_MIN; // Maximum error
        if (y != y) return INT_MIN; // Maximum error

        memcpy(&xx, &x, sizeof(float));
        memcpy(&yy, &y, sizeof(float));

        xx = xx > INT_MAX ? INT_MIN - xx : xx;
        yy = yy > INT_MAX ? INT_MIN - yy : yy;

        return xx >= yy ? xx - yy : yy - xx;
}

u64 ulpd(double x, double y) {
        i64 xx, yy;

        if (x == 0) x = fabs(x); // -0 == 0
        if (y == 0) y = fabs(y); // -0 == 0

        if (x != x && y != y) return 0;
        if (x != x) return LLONG_MIN; // Maximum error
        if (y != y) return LLONG_MIN; // Maximum error

        memcpy(&xx, &x, sizeof(double));
        memcpy(&yy, &y, sizeof(double));

        xx = xx < 0 ? LLONG_MIN - xx : xx;
        yy = yy < 0 ? LLONG_MIN - yy : yy;

        return xx >= yy ? xx - yy : yy - xx;
}

char ordinaryf(float x) {
        return 1 / x != 0 && x == x;
}

char ordinaryd(double x) {
        return 1 / x != 0 && x == x;
}

#define ulpl ulpd
#define ulpm ulpd

double rand_double() {
        u64 c0 = rand()&0xffff;
        u64 c1 = rand()&0xffff;
        u64 c2 = rand()&0xffff;
        u64 c3 = rand()&0xffff;
        u64 c = ((c3 << 48) | (c2 << 32) | (c1<<16) | c0);

        double cc;
        memcpy(&cc, &c, sizeof(double));
        return cc;
}

float rand_float() {
        u32 c0 = rand()&0xffff;
        u32 c1 = rand()&0xffff;
        u32 c = ((c1<<16) | c0);

        double cc;
        memcpy(&cc, &c, sizeof(double));
        return cc;
}

float *get_random_floats(int nums) {
        int i;
        float *arr = malloc(sizeof(float) * nums * NARGS);
        for (i = 0; i < nums * NARGS; i++) {
                float rand;
                do {
                        rand = rand_float();
                } while (!ordinaryf(rand));
                arr[i] = rand;
        }
        return arr;
}

double *get_random_doubles(int nums) {
        int i;
        double *arr = malloc(sizeof(double) * nums * NARGS);
        for (i = 0; i < nums * NARGS; i++) {
                double rand;
                do {
                        rand = rand_double();
                } while (!ordinaryd(rand));
                arr[i] = rand;
        }
        return arr;
}

#ifdef __MACH__ // OS X does not have clock_gettime, use clock_get_time

#define CLOCK(ts) \
  clock_get_time(cclock, &mts); \
  ts.tv_sec = mts.tv_sec; \
  ts.tv_nsec = mts.tv_nsec;

#else

#define CLOCK(ts) \
  clock_gettime(CLOCK_REALTIME, &ts);

#endif

/* Some macros to make looping a bit easier */

#define LOOP(iter) \
        CLOCK(start); \
        for (i = 0; i < iter; i++)

#define END() \
        CLOCK(end); \
        rtime = (end.tv_sec - start.tv_sec) * 1.0e9 + (end.tv_nsec - start.tv_nsec);

/* Calling a function with some number of arguments */
#define EVALAUX(n, rands) rands[NARGS*i] + n
#define EVAL(rands, f) f(ARGMAP(EVALAUX, rands))

#define CHECK(io, type, iter)                                           \
        max = total = 0;                                                \
        for (i = 0; i < iter; i++) {                                    \
                if (ordinary##type(true##type[i])) {                    \
                        u64 error = ulp##type(out##io##type[i], true##type[i]); \
                                if (error > max) max = error;           \
                                total += log(error + 1.0) / log(2);     \
                }                                                       \
        }                                                               \
        printf("%s%s,%15g,%15g,%15g\n", #io, #type, rtime,             \
               log(max + 1.0) / log(2), total / count##type);

int main(int argc, char** argv) {

#ifdef __MACH__
        clock_serv_t cclock;
        mach_timespec_t mts;
        host_get_clock_service(mach_host_self(), SYSTEM_CLOCK, &cclock);
#endif

        struct timespec start, end;
        int i;
        u64 max = 0, maxcount = 0;
        double rtime, total = 0;
        int countf = 0, countd = 0;
        double *ind, *outid, *outod, *trued;
        float *inf, *outif, *outof, *truef;
        setup_mpfr_f_im();

        int iter = ITERS;
        if (argc > 1) iter = atoi(argv[1]);

        inf = get_random_floats(NARGS * iter);
        ind = get_random_doubles(NARGS * iter);
        outif = malloc(sizeof(float) * iter);
        outid = malloc(sizeof(double) * iter);
        outof = malloc(sizeof(float) * iter);
        outod = malloc(sizeof(double) * iter);
        truef = malloc(sizeof(float) * iter);
        trued = malloc(sizeof(double) * iter);

        LOOP(iter) { truef[i] = (float) EVAL(inf, f_im); } END();
        LOOP(iter) { trued[i] = EVAL(ind, f_im); } END();

        LOOP(iter) { countf += (int) ordinaryf(truef[i]); } END();
        LOOP(iter) { countd += (int) ordinaryd(trued[i]); } END();

        printf("%s\n", name);
        printf("pf,%11d\n", countf);
        printf("pd,%11d\n", countd);
        printf("test,         time,            max,            avg\n");

        LOOP(iter) { outif[i] = EVAL(inf, f_if); } END();
        CHECK(i, f, iter);

        LOOP(iter) { outid[i] = EVAL(ind, f_id); } END();
        CHECK(i, d, iter);

        LOOP(iter) { outof[i] = EVAL(inf, f_of); } END();
        CHECK(o, f, iter);

        LOOP(iter) { outod[i] = EVAL(ind, f_od); } END();
        CHECK(o, d, iter);

        max = maxcount = 0;
        for (i = 0; i < iter; i++) {
                if (ordinaryd(trued[i])) {
                        u32 ierror = ulpf(outif[i], truef[i]);
                        u32 oerror = ulpf(outof[i], truef[i]);
                        if (ierror < oerror) {
                                maxcount++;
                                if (max < oerror - ierror) max = oerror - ierror;
                        }
                }
        }
        printf("df,%15g,%15llu\n", log(max + 1.0) / log(2), maxcount);

        max = maxcount = 0;
        for (i = 0; i < iter; i++) {
                if (ordinaryd(trued[i])) {
                        u64 ierror = ulpd(outid[i], trued[i]);
                        u64 oerror = ulpd(outod[i], trued[i]);
                        if (ierror < oerror) {
                                maxcount++;
                                if (max < oerror - ierror) max = oerror - ierror;
                        }
                }
        }
        printf("dd,%15g,%15llu\n", log(max + 1.0) / log(2), maxcount);

#ifdef __MACH__
        mach_port_deallocate(mach_task_self(), cclock);
#endif

        return 0;
}
