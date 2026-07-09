/*
 * Host-side model test for firmware/f103-microros/src/dwt_time.c.
 *
 * This does not touch STM32 registers. It models the double-buffer generation
 * algorithm used by dwt_tick_update()/dwt_now_ns() so we can exercise wrap and
 * interleaving cases while SWD is unavailable.
 */

#include <assert.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

static uint32_t s_hi[2];
static uint32_t s_last[2];
static uint32_t s_gen;

static uint64_t cycles(uint32_t hi, uint32_t low)
{
    return ((uint64_t)hi << 32) | (uint64_t)low;
}

static uint64_t ns_from_cycles(uint64_t c)
{
    return (c * 125ULL) / 9ULL;
}

static void model_init(uint32_t hi, uint32_t last, uint32_t gen)
{
    s_gen = gen;
    s_hi[0] = hi;
    s_hi[1] = hi;
    s_last[0] = last;
    s_last[1] = last;
}

static void model_tick_update(uint32_t now)
{
    uint32_t gen = s_gen;
    uint32_t active = gen & 1u;
    uint32_t hi = s_hi[active];
    uint32_t last = s_last[active];

    if (now < last) {
        hi++;
    }

    uint32_t next_gen = gen + 1u;
    uint32_t inactive = next_gen & 1u;
    s_hi[inactive] = hi;
    s_last[inactive] = now;
    s_gen = next_gen;
}

static int model_read_once(uint32_t low, uint32_t forced_gen2, uint64_t *out)
{
    uint32_t gen1 = s_gen;
    uint32_t slot = gen1 & 1u;
    uint32_t hi = s_hi[slot];
    uint32_t last = s_last[slot];
    uint32_t gen2 = forced_gen2;

    if (gen1 != gen2) {
        return 0;
    }
    if (low < last) {
        hi++;
    }
    *out = cycles(hi, low);
    return 1;
}

static uint64_t model_now(uint32_t low)
{
    uint64_t out = 0;
    int ok = model_read_once(low, s_gen, &out);
    assert(ok);
    return out;
}

static void test_no_wrap_monotonic(void)
{
    model_init(3u, 1000u, 0u);
    uint64_t a = model_now(1500u);
    model_tick_update(2000u);
    uint64_t b = model_now(2500u);
    assert(a == cycles(3u, 1500u));
    assert(b == cycles(3u, 2500u));
    assert(b > a);
}

static void test_lag_window_compensation(void)
{
    model_init(7u, 0xFFFFFFF0u, 0u);
    uint64_t before = model_now(0xFFFFFFF8u);
    uint64_t after = model_now(0x00000020u);
    assert(before == cycles(7u, 0xFFFFFFF8u));
    assert(after == cycles(8u, 0x00000020u));
    assert(after > before);
}

static void test_silent_wrap_then_resume(void)
{
    model_init(0u, 0xFFFF0000u, 0u);
    uint64_t before_silence = model_now(0xFFFF8000u);

    model_tick_update(0x00001000u);
    model_tick_update(0x00011000u);
    uint64_t after_silence = model_now(0x00018000u);

    assert(before_silence == cycles(0u, 0xFFFF8000u));
    assert(after_silence == cycles(1u, 0x00018000u));
    assert(after_silence > before_silence);
}

static void test_reader_during_inactive_write(void)
{
    model_init(4u, 0xFFFFFFF0u, 0u);

    /* Simulate writer having filled inactive slot but not published s_gen yet. */
    s_hi[1] = 5u;
    s_last[1] = 0x00000020u;
    uint64_t before_publish = model_now(0x00000030u);

    s_gen = 1u;
    uint64_t after_publish = model_now(0x00000030u);

    assert(before_publish == cycles(5u, 0x00000030u));
    assert(after_publish == cycles(5u, 0x00000030u));
}

static void test_generation_change_retries(void)
{
    model_init(2u, 200u, 8u);
    uint64_t ignored = 0;
    assert(!model_read_once(250u, 9u, &ignored));
    assert(model_read_once(250u, 8u, &ignored));
    assert(ignored == cycles(2u, 250u));
}

static void test_ns_scale_is_exact_for_one_second(void)
{
    assert(ns_from_cycles(72000000ULL) == 1000000000ULL);
}

int main(void)
{
    test_no_wrap_monotonic();
    test_lag_window_compensation();
    test_silent_wrap_then_resume();
    test_reader_during_inactive_write();
    test_generation_change_retries();
    test_ns_scale_is_exact_for_one_second();
    puts("dwt_snapshot_model_test: PASS");
    return 0;
}
