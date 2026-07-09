#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    uint32_t seq;
    int32_t payload;
} control_target_t;

static volatile control_target_t targets[2];
static volatile uint32_t active;

static void expect(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static void read_active(uint32_t *seq, int32_t *payload)
{
    uint32_t idx = active & 1u;
    *seq = targets[idx].seq;
    *payload = targets[idx].payload;
}

static uint32_t begin_update(int32_t payload)
{
    uint32_t next = (active ^ 1u) & 1u;
    targets[next].payload = payload;
    return next;
}

static void finish_update(uint32_t next, uint32_t seq)
{
    targets[next].seq = seq;
    active = next;
}

static void test_reader_during_inactive_write_sees_old_target(void)
{
    uint32_t seq;
    int32_t payload;

    targets[0].seq = 10;
    targets[0].payload = 100;
    targets[1].seq = 0;
    targets[1].payload = 0;
    active = 0;

    uint32_t next = begin_update(200);
    read_active(&seq, &payload);
    expect(seq == 10 && payload == 100,
           "reader saw half-written inactive target");

    finish_update(next, 11);
    read_active(&seq, &payload);
    expect(seq == 11 && payload == 200,
           "reader did not see complete target after active switch");
}

static void test_alternating_updates_keep_pairs_together(void)
{
    uint32_t seq;
    int32_t payload;

    active = 0;
    targets[0].seq = 0;
    targets[0].payload = 0;
    targets[1].seq = 0;
    targets[1].payload = 0;

    for (uint32_t i = 1; i <= 1000; i++) {
        uint32_t next = begin_update((int32_t)(i * -3));
        finish_update(next, i);
        read_active(&seq, &payload);
        expect(seq == i, "seq mismatch after active switch");
        expect(payload == (int32_t)(i * -3),
               "payload mismatch after active switch");
    }
}

int main(void)
{
    test_reader_during_inactive_write_sees_old_target();
    test_alternating_updates_keep_pairs_together();
    puts("control_target_model_test: PASS");
    return 0;
}
