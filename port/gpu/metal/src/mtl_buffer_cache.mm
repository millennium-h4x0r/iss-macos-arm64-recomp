// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: guest memory as MTLBuffers (see buffer_cache.h in metal/shadow).

#include <cstdio>
#include <cstdlib>
#include <unordered_map>
#include <string>
#include <mutex>
#include <map>
#include <chrono>
#include <cstring>

#include "common/alignment.h"
#include "common/assert.h"
#include "mtl_objc.h"
#include "video_core/buffer_cache/buffer_cache.h"
#include "video_core/buffer_cache/unified_memory.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"

namespace VideoCore {

namespace {
// TLG_LOG_WRITE_RACE: guest page -> command buffer tick of the last binding that reads it.
struct ReadPages {
    std::mutex mutex;
    std::unordered_map<u64, u64> last_read;
    std::map<std::pair<u64, u64>, u64> big_reads; // [start, end) -> tick (bindings over 4 MiB)
    u64 writes = 0, raced = 0, big_bindings = 0;
    std::map<std::pair<std::string, u64>, u64> where; // (what, size) -> count
    std::chrono::steady_clock::time_point window = std::chrono::steady_clock::now();
};
ReadPages& Reads() {
    static ReadPages reads;
    return reads;
}
constexpr u64 RacePage = 4096;
} // namespace

bool BufferCache::WriteRaceEnabled() {
    static const bool enabled = std::getenv("TLG_LOG_WRITE_RACE") != nullptr;
    return enabled;
}

void BufferCache::NoteCpuWrite(VAddr addr, u64 size, const char* what) {
    auto& r = Reads();
    std::scoped_lock lock{r.mutex};
    ++r.writes;
    bool raced = false;
    for (u64 page = addr / RacePage; page <= (addr + std::max<u64>(size, 1) - 1) / RacePage; ++page) {
        if (const auto it = r.last_read.find(page); it != r.last_read.end() && !scheduler.IsFree(it->second)) {
            raced = true;
            break;
        }
    }
    for (const auto& [range, tick] : r.big_reads) {
        if (raced) {
            break;
        }
        if (addr < range.second && addr + size > range.first && !scheduler.IsFree(tick)) {
            raced = true;
        }
    }
    if (raced) {
        ++r.raced;
        ++r.where[{what, size}];
    }
    const auto now = std::chrono::steady_clock::now();
    if (now - r.window >= std::chrono::seconds(5)) {
        std::printf("Write race (5 s): %llu CP writes, %llu to pages queued GPU work reads "
                    "(%llu bindings over 4 MiB, as ranges)",
                    (unsigned long long)r.writes, (unsigned long long)r.raced,
                    (unsigned long long)r.big_bindings);
        std::printf(" [%zu big ranges]", r.big_reads.size());
        int shown = 0;
        for (const auto& [key, count] : r.where) {
            if (shown++ < 6) {
                std::printf("; %s %llu bytes x%llu", key.first.c_str(),
                            (unsigned long long)key.second, (unsigned long long)count);
            }
        }
        std::printf("\n");
        r.writes = r.raced = r.big_bindings = 0;
        r.where.clear();
        if (r.last_read.size() > (1u << 22)) {
            r.last_read.clear();
        }
        r.window = now;
    }
}

namespace {
constexpr u64 HostPage = 16_KB;

u64 UnifiedBase() {
    // The recompiled image maps guest memory 0x6000000000 above the PS4 address (run.sh sets
    // TLG_UNIFIED_RANGE accordingly).
    return Unified::GetRange().base;
}
} // namespace

BufferCache::BufferCache(const Vulkan::Instance& instance_, Vulkan::Scheduler& scheduler_,
                         Vulkan::Runtime& runtime_, AmdGpu::Liverpool*)
    : instance{instance_}, scheduler{scheduler_}, runtime{runtime_} {
    stream_buffer = std::make_unique<StreamBuffer>(instance, scheduler, MemoryType::Stream,
                                                   STREAM_BUFFER_SIZE);
    utility_buffer = std::make_unique<StreamBuffer>(instance, scheduler, MemoryType::HostCached,
                                                    UTILITY_BUFFER_SIZE);
    if (Unified::Enabled()) {
        const auto& range = Unified::GetRange();
        unified = Wrap(UnifiedBase(), range.size, "guest direct memory");
        if (unified) {
            unified_base = UnifiedBase();
            unified_end = unified_base + range.size;
        }
    }
    if (!unified) {
        std::printf("GPU: Metal renderer without unified memory (TLG_UNIFIED_MEMORY=1 and "
                    "TLG_UNIFIED_RANGE): guest buffers are imported per mapping\n");
    }
}

BufferCache::~BufferCache() = default;

std::unique_ptr<Buffer> BufferCache::Wrap(VAddr addr, u64 size, const char* what) {
    const VAddr start = Common::AlignDown(addr, HostPage);
    const VAddr end = Common::AlignUp(addr + size, HostPage);
    id<MTLBuffer> mtl = [Metal::Device()
        newBufferWithBytesNoCopy:reinterpret_cast<void*>(start)
                          length:end - start
                         options:MTLResourceStorageModeShared |
                                 MTLResourceHazardTrackingModeUntracked
                     deallocator:nil];
    if (!mtl) {
        std::printf("GPU: could not import %s %#llx-%#llx\n", what, (unsigned long long)start,
                    (unsigned long long)end);
        return {};
    }
    mtl.label = [NSString stringWithUTF8String:what];
    auto buffer = std::make_unique<Buffer>(instance, start, 16, MemoryType::DeviceLocal);
    buffer->buffer.Destroy();
    buffer->buffer.buffer = Metal::MtlOwn<vk::Buffer>(mtl);
    buffer->buffer.bda_addr = mtl.gpuAddress;
    buffer->size_bytes = end - start;
    buffer->mapped_data = std::span<u8>{reinterpret_cast<u8*>(start), end - start};
    static u32 logged = 0;
    if (logged++ < 8) {
        std::printf("GPU: imported %s %#llx-%#llx (%.1f MB) as a Metal buffer\n", what,
                    (unsigned long long)start, (unsigned long long)end,
                    double(end - start) / (1 << 20));
    }
    return buffer;
}

bool BufferCache::IsInPlace(VAddr addr, u64 size) {
    if (addr >= unified_base && addr + size <= unified_end) {
        return true;
    }
    std::scoped_lock lock{imports_mutex};
    auto it = imports.upper_bound(addr);
    if (it == imports.begin()) {
        return false;
    }
    --it;
    return addr + size <= it->second.end;
}

std::pair<const Buffer*, u64> BufferCache::ObtainBuffer(VAddr addr, u64 size, bool is_written) {
    if (WriteRaceEnabled() && addr && size) {
        auto& r = Reads();
        std::scoped_lock lock{r.mutex};
        if (size > (4u << 20)) {
            ++r.big_bindings;
            r.big_reads[{addr, addr + size}] = scheduler.CurrentTick();
        } else {
            const u64 tick = scheduler.CurrentTick();
            for (u64 page = addr / RacePage; page <= (addr + size - 1) / RacePage; ++page) {
                r.last_read[page] = tick;
            }
        }
    }
    if (addr >= unified_base && addr + size <= unified_end) {
        return {unified.get(), addr - unified->CpuAddr()};
    }
    {
        std::scoped_lock lock{imports_mutex};
        auto it = imports.upper_bound(addr);
        if (it != imports.begin()) {
            --it;
            if (addr + size <= it->second.end) {
                return {it->second.buffer.get(), addr - it->second.buffer->CpuAddr()};
            }
        }
    }
    // Not imported yet: wrap the pages of this binding (guest memory the game did not map for
    // the GPU, e.g. flexible memory) without copying.
    if (addr != 0) {
        if (auto buffer = Wrap(addr, std::max<u64>(size, 4), "guest memory (on demand)")) {
            ++copied_bindings;
            std::scoped_lock lock{imports_mutex};
            const VAddr start = buffer->CpuAddr();
            const VAddr end = start + buffer->SizeBytes();
            auto* raw = buffer.get();
            auto& slot = imports[start];
            if (!slot.buffer || slot.end < end) {
                if (slot.buffer) {
                    // A smaller import at the same start: keep it alive until the GPU is done.
                    auto old = std::make_shared<std::unique_ptr<Buffer>>(std::move(slot.buffer));
                    scheduler.DeferOperation([old] {});
                }
                slot = Import{end, std::move(buffer)};
            }
            return {raw, addr - raw->CpuAddr()};
        }
    }
    static u32 logged = 0;
    if (logged++ < 16) {
        std::printf("GPU: binding %#llx+%#llx is not guest memory (zeros bound)\n",
                    (unsigned long long)addr, (unsigned long long)size);
    }
    const u64 bytes = std::min<u64>(std::max<u64>(size, 4), 1_MB);
    const auto [data, offset] = stream_buffer->Map(bytes, 256);
    std::memset(data, 0, bytes);
    stream_buffer->Commit();
    return {stream_buffer.get(), offset};
}

void BufferCache::MapMemory(VAddr addr, u64 size) {
    if (size == 0 || (addr >= unified_base && addr + size <= unified_end)) {
        return;
    }
    auto buffer = Wrap(addr, size, "guest GPU mapping");
    if (!buffer) {
        return;
    }
    std::scoped_lock lock{imports_mutex};
    const VAddr start = buffer->CpuAddr();
    const VAddr end = start + buffer->SizeBytes();
    imports[start] = Import{end, std::move(buffer)};
}

void BufferCache::UnmapMemory(VAddr addr, u64 size) {
    std::vector<std::unique_ptr<Buffer>> released;
    {
        std::scoped_lock lock{imports_mutex};
        for (auto it = imports.begin(); it != imports.end();) {
            if (it->first < addr + size && addr < it->second.end) {
                released.push_back(std::move(it->second.buffer));
                it = imports.erase(it);
            } else {
                ++it;
            }
        }
    }
    if (released.empty()) {
        return;
    }
    // The GPU may still read them: release once the work recorded so far has completed.
    auto shared = std::make_shared<std::vector<std::unique_ptr<Buffer>>>(std::move(released));
    scheduler.DeferOperation([shared] { shared->clear(); });
}

} // namespace VideoCore
