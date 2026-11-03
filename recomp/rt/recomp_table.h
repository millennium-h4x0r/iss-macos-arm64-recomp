#pragma once
#include "x86.h"
typedef struct { uint64_t offset; GFn fn; } RecompEntry;
extern const RecompEntry recomp_table[];
extern const unsigned long recomp_table_count;
