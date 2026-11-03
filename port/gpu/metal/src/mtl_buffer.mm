// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: VideoCore::Buffer and StreamBuffer (buffer_cache/buffer.h) over
// MTLBuffers. Apple GPUs share memory with the CPU: every buffer is shared storage, mapped.
// The stream buffer's ring logic is buffer.cpp's.

#include <numeric>
#include <string_view>

#include "common/alignment.h"
#include "common/assert.h"
#include "mtl_objc.h"
#include "video_core/buffer_cache/buffer.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"

namespace VideoCore {

std::string_view BufferTypeName(MemoryType type) {
    switch (type) {
    case MemoryType::HostUncached:
        return "HostUncached";
    case MemoryType::HostCached:
        return "HostCached";
    case MemoryType::Stream:
        return "Stream";
    case MemoryType::DeviceLocal:
        return "DeviceLocal";
    case MemoryType::Sparse:
        return "Sparse";
    default:
        return "Invalid";
    }
}

UniqueBuffer::UniqueBuffer(vk::Device device_, VmaAllocator allocator_)
    : device{device_}, allocator{allocator_} {}

UniqueBuffer::~UniqueBuffer() {
    Destroy();
}

void UniqueBuffer::Destroy() {
    Metal::MtlFree(buffer);
    bda_addr = 0;
}

void UniqueBuffer::Create(vk::BufferCreateInfo& buffer_ci, MemoryType mem_type,
                          VmaAllocationInfo*) {
    ASSERT_MSG(mem_type != MemoryType::Sparse, "Metal renderer: no sparse buffers");
    const MTLResourceOptions options = MTLResourceStorageModeShared |
                                       (mem_type == MemoryType::HostCached
                                            ? MTLResourceCPUCacheModeDefaultCache
                                            : MTLResourceCPUCacheModeWriteCombined);
    id<MTLBuffer> mtl = [Metal::Device() newBufferWithLength:std::max<u64>(buffer_ci.size, 16)
                                                     options:options];
    ASSERT_MSG(mtl, "Metal renderer: failed allocating a buffer of {:#x} bytes", buffer_ci.size);
    buffer = Metal::MtlOwn<vk::Buffer>(mtl);
    bda_addr = mtl.gpuAddress;
}

Buffer::Buffer(const Vulkan::Instance&, VAddr cpu_addr_, u64 size_bytes_, MemoryType mem_type_,
               std::string_view debug_name)
    : cpu_addr{cpu_addr_}, size_bytes{size_bytes_}, mem_type{mem_type_}, buffer{{}, {}} {
    vk::BufferCreateInfo buffer_ci = {.size = size_bytes};
    buffer.Create(buffer_ci, mem_type, nullptr);
    id<MTLBuffer> mtl = Metal::Buffer(Handle());
    mapped_data = std::span<u8>{static_cast<u8*>(mtl.contents), size_bytes};
    is_coherent = true;
    if (!debug_name.empty()) {
        mtl.label = [[NSString alloc] initWithBytes:debug_name.data()
                                             length:debug_name.size()
                                           encoding:NSUTF8StringEncoding];
    }
}

void Buffer::Flush(u64, u64) {}

void Buffer::Invalidate(u64, u64) {}

constexpr u64 WATCHES_INITIAL_RESERVE = 0x100;
constexpr u64 WATCHES_RESERVE_CHUNK = 0x100;

StreamBuffer::StreamBuffer(const Vulkan::Instance& instance, Vulkan::Scheduler& scheduler_,
                           MemoryType mem_type, u64 size_bytes)
    : Buffer{instance, 0, size_bytes, mem_type}, scheduler{scheduler_},
      non_coherent_atom_size{1} {
    ReserveWatches(current_watches, WATCHES_INITIAL_RESERVE);
    ReserveWatches(previous_watches, WATCHES_INITIAL_RESERVE);
}

bool StreamBuffer::PrepareMap(u64 size, u64 alignment, bool allow_wait) {
    if (size > this->size_bytes) {
        return false;
    }
    if (alignment > 0) {
        offset = Common::AlignUp(offset, alignment);
    }
    if (offset + size > this->size_bytes) {
        invalidation_mark = current_watch_cursor;
        current_watch_cursor = 0;
        offset = 0;
        std::swap(previous_watches, current_watches);
        wait_cursor = 0;
        wait_bound = 0;
    }
    if (!WaitPendingOperations(offset + size, allow_wait)) {
        return false;
    }
    mapped_size = size;
    return true;
}

std::pair<u8*, u64> StreamBuffer::Map(u64 size, u64 alignment, bool allow_wait) {
    if (!PrepareMap(size, alignment, allow_wait)) {
        return {nullptr, 0};
    }
    u8* const data = mapped_data.empty() ? nullptr : mapped_data.data() + offset;
    return {data, offset};
}

void StreamBuffer::Commit() {
    AdvanceAndWatch();
}

std::optional<u64> StreamBuffer::Reserve(u64 size, u64 alignment, bool allow_wait) {
    if (!PrepareMap(size, alignment, allow_wait)) {
        return std::nullopt;
    }
    const u64 reserved_offset = offset;
    AdvanceAndWatch();
    return reserved_offset;
}

void StreamBuffer::AdvanceAndWatch() {
    offset += mapped_size;
    const u64 tick = scheduler.CurrentTick();
    last_tick = tick;
    if (current_watch_cursor != 0 && current_watches[current_watch_cursor - 1].tick == tick) {
        current_watches[current_watch_cursor - 1].upper_bound = offset;
        return;
    }
    if (current_watch_cursor + 1 >= current_watches.size()) {
        ReserveWatches(current_watches, WATCHES_RESERVE_CHUNK);
    }
    auto& watch = current_watches[current_watch_cursor++];
    watch.upper_bound = offset;
    watch.tick = tick;
}

void StreamBuffer::ReserveWatches(std::vector<Watch>& watches, std::size_t grow_size) {
    watches.resize(watches.size() + grow_size);
}

bool StreamBuffer::WaitPendingOperations(u64 requested_upper_bound, bool allow_wait) {
    if (!invalidation_mark) {
        return true;
    }
    while (requested_upper_bound > wait_bound && wait_cursor < *invalidation_mark) {
        auto& watch = previous_watches[wait_cursor];
        if (!scheduler.IsFree(watch.tick) && !allow_wait) {
            return false;
        }
        scheduler.Wait(watch.tick);
        wait_bound = watch.upper_bound;
        ++wait_cursor;
    }
    return true;
}

} // namespace VideoCore
