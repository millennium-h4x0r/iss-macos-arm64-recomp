#include <chrono>
#include "tlg_vsync.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#include <mach/mach_time.h>
#include <xxhash.h>
// SPDX-License-Identifier: GPL-2.0-or-later
// tlg Metal renderer: presentation to the window's CAMetalLayer.

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "common/assert.h"
#include "mtl_draw.h"
#include "mtl_objc.h"
#include "mtl_scheduler_internal.h"
#include "sdl_window.h"
#include "tlg_overlay.h"
#include "tlg_settings.h"
#include "video_core/renderer_vulkan/vk_presenter.h"
#include "video_core/renderer_vulkan/vk_rasterizer.h"

namespace Vulkan {

namespace {

constexpr u32 NumFrames = 3;

const char* kPresentSource = R"(
#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut fs_tri(uint vid [[vertex_id]]) {
    const float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 copy_frag(VOut in [[stage_in]], texture2d<float> t [[texture(0)]],
                          sampler s [[sampler(0)]]) {
    return float4(t.sample(s, in.uv).rgb, 1.0);
}

constant float cutoff = 0.0031308, a = 1.055, b = 0.055, d = 12.92;

// The Vulkan renderer's post_process.frag: sRGB-encoded input, display gamma.
fragment float4 present_frag(VOut in [[stage_in]], texture2d<float> t [[texture(0)]],
                             sampler s [[sampler(0)]], constant float& gamma [[buffer(0)]]) {
    float3 c = t.sample(s, in.uv).rgb;
    if (gamma == 1.0) {
        return float4(c, 1.0);
    }
    const float3 lin = select(pow(max(c + b, 0.0) / a, float3(2.4)), c / d, c < float3(d * cutoff));
    const float3 g = select(a * pow(lin, float3(1.0 / (2.4 + 1.0 - gamma))) - b, d * lin / gamma,
                            lin < float3(cutoff));
    return float4(g, 1.0);
}
)";

id<MTLRenderPipelineState> MakePipeline(id<MTLLibrary> library, NSString* fragment,
                                        MTLPixelFormat format) {
    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"fs_tri"];
    desc.fragmentFunction = [library newFunctionWithName:fragment];
    desc.colorAttachments[0].pixelFormat = format;
    NSError* error = nil;
    id<MTLRenderPipelineState> pso = [Metal::Device() newRenderPipelineStateWithDescriptor:desc
                                                                                     error:&error];
    ASSERT_MSG(pso, "Metal present pipeline: {}", error.localizedDescription.UTF8String);
    return pso;
}

MTLPixelFormat NonSrgb(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatBGRA8Unorm_sRGB:
        return MTLPixelFormatBGRA8Unorm;
    case MTLPixelFormatRGBA8Unorm_sRGB:
        return MTLPixelFormatRGBA8Unorm;
    default:
        return f;
    }
}

// tlg: the display's refresh times for the emulated vblank (tlg_vsync.h). MTLDrawable
// presentedTime stays 0 for this window on macOS, so a CVDisplayLink reports each upcoming
// refresh (host time) instead. Deprecated, still the simplest source without a run loop.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
void StartDisplayLink() {
    if (!TlgVsync::Enabled()) {
        return;
    }
    static CVDisplayLinkRef link = nullptr;
    if (link) {
        return;
    }
    if (CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &link) != kCVReturnSuccess || !link) {
        std::printf("GPU (Metal): no display link; vblank stays on the timer\n");
        return;
    }
    static mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    CVDisplayLinkSetOutputCallback(
        link,
        [](CVDisplayLinkRef, const CVTimeStamp*, const CVTimeStamp* out, CVOptionFlags,
           CVOptionFlags*, void*) -> CVReturn {
            if ((out->flags & kCVTimeStampHostTimeValid) && out->videoRefreshPeriod &&
                out->videoTimeScale) {
                const int64_t ns = int64_t(out->hostTime * timebase.numer / timebase.denom);
                const int64_t period =
                    int64_t(1e9 * double(out->videoRefreshPeriod) / double(out->videoTimeScale));
                TlgVsync::NotePresented(ns, period);
            }
            return kCVReturnSuccess;
        },
        nullptr);
    CVDisplayLinkStart(link);
    const double period = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link);
    std::printf("GPU (Metal): display link on the main display (%.2f Hz)\n",
                period > 0 ? 1.0 / period : 0.0);
}
#pragma clang diagnostic pop

void WriteDump(id<MTLBuffer> buffer, u32 w, u32 h, int index) {
    const char* dir = std::getenv("TLG_DUMP_DIR");
    char path[512];
    std::snprintf(path, sizeof(path), "%s/display_%03d_%ux%u.raw", dir && *dir ? dir : "out/dump",
                  index, w, h);
    if (FILE* f = std::fopen(path, "wb")) {
        std::fwrite(buffer.contents, 1, size_t(w) * h * 4, f);
        std::fclose(f);
    }
}

} // namespace

Presenter::Presenter(Frontend::WindowSDL& window_, AmdGpu::Liverpool* liverpool_)
    : window{window_}, liverpool{liverpool_}, instance{window_, 0}, draw_scheduler{instance, "draw"},
      present_scheduler{instance, "present"}, runtime{instance, draw_scheduler},
      rasterizer{std::make_unique<Rasterizer>(instance, draw_scheduler, runtime, liverpool)},
      texture_cache{rasterizer->GetTextureCache()} {
    CAMetalLayer* metal_layer = (__bridge CAMetalLayer*)window.GetWindowInfo().render_surface;
    ASSERT_MSG(metal_layer, "Metal renderer: the window has no CAMetalLayer");
    metal_layer.device = Metal::Device();
    metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metal_layer.framebufferOnly = YES;
    metal_layer.maximumDrawableCount = 3;
    metal_layer.displaySyncEnabled = TlgSettings::Get().vsync ? YES : NO;
    StartDisplayLink();
    layer = (__bridge void*)metal_layer;

    NSError* error = nil;
    id<MTLLibrary> library =
        [Metal::Device() newLibraryWithSource:[NSString stringWithUTF8String:kPresentSource]
                                      options:nil
                                        error:&error];
    ASSERT_MSG(library, "Metal present shaders: {}", error.localizedDescription.UTF8String);
    blit_pipeline = (__bridge_retained void*)MakePipeline(library, @"present_frag",
                                                         MTLPixelFormatBGRA8Unorm);
    copy_pipeline = (__bridge_retained void*)MakePipeline(library, @"copy_frag",
                                                         MTLPixelFormatBGRA8Unorm);
    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sampler = (__bridge_retained void*)[Metal::Device() newSamplerStateWithDescriptor:sd];

    frames.resize(NumFrames);
    for (u32 i = 0; i < NumFrames; ++i) {
        frames[i].id = static_cast<u8>(i);
        free_queue.push_back(&frames[i]);
    }
    TlgOverlay::Init(instance, vk::Format::eB8G8R8A8Unorm, NumFrames);
    std::printf("GPU: Metal presenter ready (VSync %s)\n", TlgSettings::Get().vsync ? "on" : "off");
}

Presenter::~Presenter() {
    draw_scheduler.Finish();
    present_scheduler.Finish();
    for (auto& frame : frames) {
        if (frame.texture) {
            id t = (__bridge_transfer id)frame.texture;
            (void)t;
        }
    }
    for (void* p : {blit_pipeline, copy_pipeline, sampler}) {
        if (p) {
            id o = (__bridge_transfer id)p;
            (void)o;
        }
    }
}

VideoCore::Image& Presenter::RegisterVideoOutSurface(
    const Libraries::VideoOut::BufferAttributeGroup& attribute, VAddr cpu_address) {
    vo_buffers_addr.emplace_back(cpu_address);
    auto desc = VideoCore::TextureCache::ImageDesc{attribute, cpu_address};
    const auto image_id = texture_cache.FindImage(desc);
    auto& image = texture_cache.GetImage(image_id);
    image.usage.vo_surface = 1u;
    return image;
}

Frame* Presenter::GetRenderFrame() {
    std::unique_lock lock{free_mutex};
    free_cv.wait(lock, [this] { return !free_queue.empty(); });
    Frame* frame = free_queue.front();
    free_queue.pop_front();
    return frame;
}

void Presenter::EnsureFrameSize(Frame* frame, u32 width, u32 height) {
    if (frame->texture && frame->width == width && frame->height == height) {
        return;
    }
    if (frame->texture) {
        id t = (__bridge_transfer id)frame->texture;
        (void)t;
        frame->texture = nullptr;
    }
    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:std::max(width, 1u)
                                                          height:std::max(height, 1u)
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    frame->texture = (__bridge_retained void*)[Metal::Device() newTextureWithDescriptor:desc];
    frame->width = width;
    frame->height = height;
}

Frame* Presenter::PrepareFrame(const Libraries::VideoOut::BufferAttributeGroup& attribute,
                               VAddr cpu_address) {
    static const char* dump_trigger = std::getenv("TLG_FRAME_DUMP_TRIGGER");
    static const int dump_count = [] {
        const char* env = std::getenv("TLG_FRAME_DUMP_COUNT");
        const int n = env ? std::atoi(env) : 1;
        return std::clamp(n, 1, 600);
    }();
    if (dump_trigger && dump_left == 0 && std::remove(dump_trigger) == 0) {
        dump_left = dump_count;
    }
    const bool dump = dump_left > 0;
    if (dump) {
        --dump_left;
    }

    auto desc = VideoCore::TextureCache::ImageDesc{attribute, cpu_address};
    const auto image_id = texture_cache.FindImage(desc);
    const u32 flags_before = u32(texture_cache.GetImage(image_id).flags);
    texture_cache.UpdateImage(image_id);
    auto& image = texture_cache.GetImage(image_id);
    static int flag_logs = 0;
    if (flag_logs < 8) {
        ++flag_logs;
        std::printf("Present: image flags before update %#x after %#x\n", flags_before,
                    u32(image.flags));
    }
    id<MTLTexture> source = Metal::Texture(image.GetImage());
    static int logged = 0;
    if (logged < 6) {
        ++logged;
        std::printf("Present: display %#llx %ux%u %s texture %p (%u) image %u\n",
                    (unsigned long long)cpu_address, image.info.size.width,
                    image.info.size.height, vk::to_string(image.info.pixel_format).c_str(),
                    (__bridge void*)source, source ? u32(source.pixelFormat) : 0,
                    image_id.index);
    }

    Frame* frame = GetRenderFrame();
    frame->blank = false;
    EnsureFrameSize(frame, image.info.size.width, image.info.size.height);
    TlgSettings::Get().image_width = int(image.info.size.width);
    TlgSettings::Get().image_height = int(image.info.size.height);

    id<MTLTexture> target = (__bridge id<MTLTexture>)frame->texture;
    if (source) {
        static const bool debug_red = [] {
            const char* v = std::getenv("TLG_METAL_DEBUG_PRESENT");
            return v && *v == '2';
        }();
        if (debug_red) {
            draw_scheduler.EndEncoding();
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = source;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> e =
                [MetalScheduler::CommandBuffer(draw_scheduler) renderCommandEncoderWithDescriptor:rp];
            [e endEncoding];
        }
        // The display format says how the buffer's bytes are ordered (the Vulkan renderer views
        // it as GetFrameViewFormat does): A8R8G8B8 / A2R10G10B10 are BGRA in memory, so an image
        // the texture cache holds in RGBA order is read with red and blue swapped.
        using PF = Libraries::VideoOut::PixelFormat;
        const auto display = attribute.attrib.pixel_format;
        const bool bgra_display = display == PF::A8R8G8B8Srgb || display == PF::A2R10G10B10 ||
                                  display == PF::A2R10G10B10Srgb ||
                                  display == PF::A2R10G10B10Bt2020Pq;
        const MTLPixelFormat pf = source.pixelFormat;
        const bool rgba_image = pf == MTLPixelFormatRGBA8Unorm || pf == MTLPixelFormatRGBA8Unorm_sRGB ||
                                pf == MTLPixelFormatRGB10A2Unorm;
        const bool swap = bgra_display && rgba_image;
        if (NonSrgb(pf) != pf || swap) {
            source = [source
                newTextureViewWithPixelFormat:NonSrgb(pf)
                                  textureType:source.textureType
                                       levels:NSMakeRange(0, 1)
                                       slices:NSMakeRange(0, 1)
                                      swizzle:swap ? MTLTextureSwizzleChannelsMake(
                                                         MTLTextureSwizzleBlue, MTLTextureSwizzleGreen,
                                                         MTLTextureSwizzleRed, MTLTextureSwizzleAlpha)
                                                   : MTLTextureSwizzleChannelsDefault];
        }
        draw_scheduler.EndEncoding();
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        static const bool debug_green = [] {
            const char* v = std::getenv("TLG_METAL_DEBUG_PRESENT");
            return v && *v == '1';
        }();
        pass.colorAttachments[0].loadAction = debug_green ? MTLLoadActionClear : MTLLoadActionDontCare;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = MetalScheduler::CommandBuffer(draw_scheduler);
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
        enc.label = @"Display copy";
        draw_scheduler.SetRenderEncoder((__bridge void*)enc, ~0ull - 1);
        [enc setRenderPipelineState:(__bridge id<MTLRenderPipelineState>)copy_pipeline];
        [enc setFragmentTexture:source atIndex:0];
        [enc setFragmentSamplerState:(__bridge id<MTLSamplerState>)sampler atIndex:0];
        if (!debug_green) {
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        draw_scheduler.EndEncoding();
        // TLG_METAL_CONTENT_STATS=1: whether each flipped frame shows a new picture (8 rows of
        // the frame are read back and hashed), as runs of repeats every 5 s. Flip timing alone
        // cannot show a game that flips at 60 Hz but updates its picture at 15.
        if (static const bool content_stats = std::getenv("TLG_METAL_CONTENT_STATS") != nullptr;
            content_stats && frame->height >= 16) {
            const u32 w = frame->width, rows = 8;
            id<MTLBuffer> buffer = [Metal::Device() newBufferWithLength:size_t(w) * rows * 4
                                                                options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit = MetalScheduler::Blit(draw_scheduler);
            for (u32 r = 0; r < rows; ++r) {
                [blit copyFromTexture:target
                                 sourceSlice:0
                                 sourceLevel:0
                                sourceOrigin:MTLOriginMake(0, (frame->height * (2 * r + 1)) / (2 * rows), 0)
                                  sourceSize:MTLSizeMake(w, 1, 1)
                                    toBuffer:buffer
                           destinationOffset:size_t(r) * w * 4
                      destinationBytesPerRow:w * 4
                    destinationBytesPerImage:w * 4];
            }
            draw_scheduler.EndEncoding();
            draw_scheduler.SignalOnCompletion([buffer, w, rows] {
                static u64 last_hash = 0;
                static u32 run = 0, frames = 0, fresh = 0, longest = 0;
                static u32 runs[8] = {};
                static auto window = std::chrono::steady_clock::now();
                const u64 hash = XXH3_64bits(buffer.contents, size_t(w) * rows * 4);
                ++frames;
                if (hash != last_hash) {
                    ++fresh;
                    if (run) {
                        ++runs[std::min<u32>(run, 7)];
                    }
                    longest = std::max(longest, run);
                    run = 0;
                    last_hash = hash;
                } else {
                    ++run;
                }
                const auto now = std::chrono::steady_clock::now();
                if (now - window >= std::chrono::seconds(5)) {
                    std::printf("Content stats (5 s): %u flips, %u new pictures; repeat runs "
                                "1:%u 2:%u 3:%u 4+:%u, longest %u\n",
                                frames, fresh, runs[1], runs[2], runs[3],
                                runs[4] + runs[5] + runs[6] + runs[7], longest);
                    frames = fresh = longest = 0;
                    std::fill(std::begin(runs), std::end(runs), 0u);
                    window = now;
                }
            });
        }
        if (dump) {
            id<MTLBuffer> buffer =
                [Metal::Device() newBufferWithLength:size_t(frame->width) * frame->height * 4
                                             options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit = MetalScheduler::Blit(draw_scheduler);
            [blit copyFromTexture:target
                             sourceSlice:0
                             sourceLevel:0
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:MTLSizeMake(frame->width, frame->height, 1)
                                toBuffer:buffer
                       destinationOffset:0
                  destinationBytesPerRow:frame->width * 4
                destinationBytesPerImage:size_t(frame->width) * frame->height * 4];
            draw_scheduler.EndEncoding();
            const u32 w = frame->width, h = frame->height;
            const int index = dump_index++;
            draw_scheduler.SignalOnCompletion([buffer, w, h, index] { WriteDump(buffer, w, h, index); });
        }
    }
    // Debugging: the color targets of the frame after a dump (TLG_METAL_DUMP_TARGETS=1).
    static const bool dump_targets = [] {
        const char* v = std::getenv("TLG_METAL_DUMP_TARGETS");
        return v && *v == '1';
    }();
    if (NanScan::Enabled()) {
        NanScan::EndFrame(draw_scheduler, dump);
    }
    if (dump_targets) {
        auto targets = rasterizer->TakeFrameTargets();
        rasterizer->CollectFrameTargets(dump);
        int n = 0;
        for (auto& target : targets) {
            id<MTLTexture> tex = (__bridge_transfer id<MTLTexture>)target.texture;
            const MTLPixelFormat pf = tex.pixelFormat;
            const bool integer = pf == MTLPixelFormatR32Uint || pf == MTLPixelFormatRG32Uint ||
                                 pf == MTLPixelFormatRGBA32Uint || pf == MTLPixelFormatR16Uint ||
                                 pf == MTLPixelFormatRGBA8Uint || pf == MTLPixelFormatR8Uint ||
                                 pf == MTLPixelFormatRGBA16Uint || pf == MTLPixelFormatRG16Uint;
            if (integer || tex.textureType != MTLTextureType2D) {
                continue;
            }
            const u32 w = u32(tex.width), h = u32(tex.height);
            MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:w
                                                                                         height:h
                                                                                      mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> conv = [Metal::Device() newTextureWithDescriptor:td];
            draw_scheduler.EndEncoding();
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = conv;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> e =
                [MetalScheduler::CommandBuffer(draw_scheduler) renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:(__bridge id<MTLRenderPipelineState>)copy_pipeline];
            [e setFragmentTexture:tex atIndex:0];
            [e setFragmentSamplerState:(__bridge id<MTLSamplerState>)sampler atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            id<MTLBuffer> buffer = [Metal::Device() newBufferWithLength:size_t(w) * h * 4
                                                                options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit = MetalScheduler::Blit(draw_scheduler);
            [blit copyFromTexture:conv sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(w, h, 1) toBuffer:buffer destinationOffset:0
                  destinationBytesPerRow:w * 4 destinationBytesPerImage:size_t(w) * h * 4];
            draw_scheduler.EndEncoding();
            const std::string name = target.label;
            const int index = n++;
            draw_scheduler.SignalOnCompletion([buffer, w, h, index, name] {
                const char* dir = std::getenv("TLG_DUMP_DIR");
                char path[512];
                std::snprintf(path, sizeof(path), "%s/target_%02d_%s_%ux%u.bgra", dir && *dir ? dir : "out/dump",
                              index, name.c_str(), w, h);
                if (FILE* f = std::fopen(path, "wb")) {
                    std::fwrite(buffer.contents, 1, size_t(w) * h * 4, f);
                    std::fclose(f);
                }
            });
        }
    }
    frame->ready_tick = draw_scheduler.CurrentTick();
    draw_scheduler.Flush();
    return frame;
}

Frame* Presenter::PrepareBlankFrame(bool) {
    // Any thread: nothing is encoded, Present clears the drawable.
    Frame* frame = GetRenderFrame();
    frame->blank = true;
    frame->ready_tick = 0;
    return frame;
}

Frame* Presenter::PrepareLastFrame() {
    std::scoped_lock lock{free_mutex};
    return last_submit_frame;
}

void Presenter::PresentLoadingFrame() {
    Present(PrepareBlankFrame(true), false, false);
}

void Presenter::Present(Frame* frame, bool is_reusing_frame, bool) {
    if (!frame) {
        return;
    }
    // TLG_METAL_PRESENT_STATS=1: time spent waiting for the frame's GPU work and the drawable.
    static const bool present_stats = std::getenv("TLG_METAL_PRESENT_STATS") != nullptr;
    static double ready_ms = 0, ready_max = 0, drawable_ms = 0, drawable_max = 0, gap_max = 0;
    static u32 presents = 0;
    static auto window_start = std::chrono::steady_clock::now();
    static auto last_present = window_start;
    const auto t_enter = std::chrono::steady_clock::now();
    if (frame->ready_tick) {
        draw_scheduler.Wait(frame->ready_tick);
    }
    const auto t_ready = std::chrono::steady_clock::now();
    CAMetalLayer* metal_layer = (__bridge CAMetalLayer*)layer;
    const bool vsync = TlgSettings::Get().vsync;
    if (bool(metal_layer.displaySyncEnabled) != vsync) {
        metal_layer.displaySyncEnabled = vsync ? YES : NO;
    }
    const CGSize bounds = metal_layer.bounds.size;
    const CGFloat scale = metal_layer.contentsScale;
    const CGSize wanted = CGSizeMake(std::max(1.0, bounds.width * scale),
                                     std::max(1.0, bounds.height * scale));
    if (!CGSizeEqualToSize(metal_layer.drawableSize, wanted)) {
        metal_layer.drawableSize = wanted;
    }
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [metal_layer nextDrawable];
        if (present_stats) {
            const auto t_drawable = std::chrono::steady_clock::now();
            const auto ms = [](auto a, auto b) {
                return std::chrono::duration<double, std::milli>(b - a).count();
            };
            const double r = ms(t_enter, t_ready), d = ms(t_ready, t_drawable);
            ready_ms += r; drawable_ms += d;
            ready_max = std::max(ready_max, r); drawable_max = std::max(drawable_max, d);
            gap_max = std::max(gap_max, ms(last_present, t_enter));
            last_present = t_enter;
            ++presents;
            if (ms(window_start, t_drawable) >= 5000.0) {
                std::printf("Present stats (5 s): %u presents, GPU-ready wait avg %.1f max %.1f ms, "
                            "drawable wait avg %.1f max %.1f ms, longest gap %.1f ms\n",
                            presents, ready_ms / presents, ready_max, drawable_ms / presents,
                            drawable_max, gap_max);
                presents = 0; ready_ms = ready_max = drawable_ms = drawable_max = gap_max = 0;
                window_start = t_drawable;
            }
        }
        if (!drawable) {
            if (!is_reusing_frame) {
                std::scoped_lock lock{free_mutex};
                free_queue.push_back(frame);
                free_cv.notify_one();
            }
            return;
        }
        id<MTLTexture> target = drawable.texture;
        const u32 dw = static_cast<u32>(target.width);
        const u32 dh = static_cast<u32>(target.height);
        TlgSettings::Get().window_width = int(dw);
        TlgSettings::Get().window_height = int(dh);

        Scheduler& scheduler = present_scheduler;
        id<MTLCommandBuffer> cb = MetalScheduler::CommandBuffer(scheduler);
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
        enc.label = @"Present";
        scheduler.SetRenderEncoder((__bridge void*)enc, ~0ull - 3);
        if (frame->texture && !frame->blank) {
            // Aspect-preserving fit.
            const double fa = double(frame->width) / frame->height;
            const double da = double(dw) / dh;
            double vw = dw, vh = dh;
            if (da > fa) {
                vw = dh * fa;
            } else {
                vh = dw / fa;
            }
            [enc setViewport:MTLViewport{(dw - vw) / 2, (dh - vh) / 2, vw, vh, 0, 1}];
            [enc setRenderPipelineState:(__bridge id<MTLRenderPipelineState>)blit_pipeline];
            [enc setFragmentTexture:(__bridge id<MTLTexture>)frame->texture atIndex:0];
            [enc setFragmentSamplerState:(__bridge id<MTLSamplerState>)sampler atIndex:0];
            const float gamma = pp_settings.gamma;
            [enc setFragmentBytes:&gamma length:sizeof(gamma) atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        scheduler.EndEncoding();
        TlgOverlay::Render((__bridge void*)cb, (__bridge void*)target, dw, dh);
        [cb presentDrawable:drawable];
    }
    if (is_reusing_frame) {
        present_scheduler.Flush();
        return;
    }
    Frame* const previous = [&] {
        std::scoped_lock lock{free_mutex};
        return std::exchange(last_submit_frame, frame);
    }();
    // The previous frame is free once this one is on screen (it may be shown again meanwhile).
    present_scheduler.SignalOnCompletion([this, previous] {
        if (!previous) {
            return;
        }
        std::scoped_lock lock{free_mutex};
        free_queue.push_back(previous);
        free_cv.notify_one();
    });
}

} // namespace Vulkan
