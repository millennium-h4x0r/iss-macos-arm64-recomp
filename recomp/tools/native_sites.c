/* Writes lifter/iss_native_sites.json from port/src/iss_native_resolution.h: the native
 * resolution patch sites (US/EU 01.07 executables are identical there). Sites whose bytes do
 * not depend on the chosen resolution are patched into the image before lifting ("fixed");
 * the others are 32-bit immediates the lifter reads from guest memory at run time ("dynamic"),
 * where rt/main.c writes the values for the player's settings.
 *   cc -I../port/src tools/native_sites.c -o work/native_sites && work/native_sites > lifter/iss_native_sites.json
 */
#include <stdio.h>
#include <string.h>
#include "iss_native_resolution.h"

static void changes(int output, int percent, IssNativeSite sites[ISS_NATIVE_SITE_COUNT]) {
    IssNativeConfig c = {.output = output, .percent = percent, .ui_16_9 = 1};
    IssNativePlan p;
    if (!iss_native_plan(c, &p)) {
        fprintf(stderr, "plan %d/%d refused\n", output, percent);
        exit(1);
    }
    iss_native_changes(&p, sites);
}

int main(void) {
    static const int probes[][2] = {{1, 75}, {1, 50}, {2, 100}, {4, 67}, {1, 133}};
    IssNativeSite base[ISS_NATIVE_SITE_COUNT];
    changes(1, 100, base);
    int dynamic[ISS_NATIVE_SITE_COUNT] = {0};
    for (unsigned k = 0; k < sizeof(probes) / sizeof(probes[0]); k++) {
        IssNativeSite s[ISS_NATIVE_SITE_COUNT];
        changes(probes[k][0], probes[k][1], s);
        for (unsigned i = 0; i < ISS_NATIVE_SITE_COUNT; i++)
            if (memcmp(base[i].after, s[i].after, s[i].length)) dynamic[i] = 1;
    }
    printf("{\n  \"fixed\": [");
    int first = 1;
    for (unsigned i = 0; i < ISS_NATIVE_SITE_COUNT; i++) {
        if (dynamic[i]) continue;
        printf("%s\n    {\"offset\": %u, \"before\": \"", first ? "" : ",", base[i].offset);
        for (unsigned j = 0; j < base[i].length; j++) printf("%02x", base[i].before[j]);
        printf("\", \"after\": \"");
        for (unsigned j = 0; j < base[i].length; j++) printf("%02x", base[i].after[j]);
        printf("\"}");
        first = 0;
    }
    printf("\n  ],\n  \"dynamic\": [");
    first = 1;
    for (unsigned i = 0; i < ISS_NATIVE_SITE_COUNT; i++) {
        if (!dynamic[i]) continue;
        /* The immediate is the instruction's last 4 bytes (mov r32/m32, imm32). */
        printf("%s\n    {\"offset\": %u, \"length\": %u, \"before\": \"", first ? "" : ",",
               base[i].offset, base[i].length);
        for (unsigned j = 0; j < base[i].length; j++) printf("%02x", base[i].before[j]);
        printf("\"}");
        first = 0;
    }
    printf("\n  ]\n}\n");
    return 0;
}
