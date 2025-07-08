const std = @import("std");
const stb_image = @import("stb_image.zig");
const stb_image_write = @import("stb_image_write.zig");
const shader_wgsl = @embedFile("shader.wgsl");

const Error = error{ImageLoadFailed};
const wgpu = @cImport({
    @cInclude("wgpu.h");
});

const State = struct {
    //testing
    adapter: ?*wgpu.struct_WGPUAdapterImpl = null,
    device: ?*wgpu.struct_WGPUDeviceImpl = null,
    queue: ?*wgpu.struct_WGPUQueueImpl = null,
    instance: ?*wgpu.struct_WGPUInstanceImpl = null,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    adapter_ready: bool = false,
    device_ready: bool = false,
    bmap_ready: bool = false,
};

var state = State{};

pub fn main() !void {
    wgpuInit();
    defer wgpu.wgpuAdapterRelease(state.adapter);
    defer wgpu.wgpuDeviceRelease(state.device);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const filename = "test.jpeg";
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");

    std.debug.print("cwd: {s}\n", .{cwd});
    const image = stb_image.loadImage(filename, 0);

    if (image == null) {
        return Error.ImageLoadFailed;
    }

    std.debug.print("shader contents:\n{s}\n", .{shader_wgsl});

    var img = image.?;

    if (img.pixels) |p| {
        const h: usize = @intCast(img.height);
        const w: usize = @intCast(img.width);
        const c: usize = @intCast(img.channels);
        const size: usize = h * w * c;
        const buf: [*]u8 = @ptrCast(p);
        const bufp: []u8 = buf[0..size];

        const dispatch_x: u32 = @intCast(@divTrunc(img.width + @as(u32, 15), 16));
        const dispatch_y: u32 = @intCast(@divTrunc(img.height + @as(u32, 15), 16));
        const input_buffer = initTexture(bufp, @intCast(w), @intCast(h));
        const storage_text = initSTexture(@intCast(w), @intCast(h));
        const storage_textB = initSTextureB(@intCast(w), @intCast(h));
        const text2ping = inittext2ping(@intCast(w), @intCast(h));
        const output_buffer = rbufferinit(size);
        const copy_buffer = cbufferinit(size);

        const buffer_callback: wgpu.WGPUBufferMapCallbackInfo = .{
            .nextInChain = null,
            .callback = callback.bufferCall,
            .userdata1 = &state,
            .userdata2 = null,
        };

        //Bind Group Layout
        const bind_group_layout = wgpu.wgpuDeviceCreateBindGroupLayout(state.device, &.{
            .entryCount = 2,
            .entries = &[_]wgpu.WGPUBindGroupLayoutEntry{
                .{
                    .nextInChain = null,
                    .binding = 0,
                    .visibility = wgpu.WGPUShaderStage_Compute,
                    .texture = .{
                        .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                        .sampleType = wgpu.WGPUTextureSampleType_UnfilterableFloat,
                        .multisampled = wgpu.WGPUOptionalBool_False,
                        .nextInChain = null,
                    },
                },
                .{ .nextInChain = null, .binding = 1, .visibility = wgpu.WGPUShaderStage_Compute, .storageTexture = .{
                    .access = wgpu.WGPUStorageTextureAccess_ReadWrite,
                    .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .nextInChain = null,
                } },
            },
            .nextInChain = null,
        });
        const bind_group_layout2 = wgpu.wgpuDeviceCreateBindGroupLayout(state.device, &.{
            .entryCount = 4,
            .entries = &[_]wgpu.WGPUBindGroupLayoutEntry{
                .{ .nextInChain = null, .binding = 0, .visibility = wgpu.WGPUShaderStage_Compute, .texture = .{
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .sampleType = wgpu.WGPUTextureSampleType_UnfilterableFloat,
                    .multisampled = wgpu.WGPUOptionalBool_False,
                    .nextInChain = null,
                } },
                .{ .nextInChain = null, .binding = 2, .visibility = wgpu.WGPUShaderStage_Compute, .texture = .{
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .sampleType = wgpu.WGPUTextureSampleType_UnfilterableFloat,
                    .multisampled = wgpu.WGPUOptionalBool_False,
                    .nextInChain = null,
                } },
                .{ .nextInChain = null, .binding = 1, .visibility = wgpu.WGPUShaderStage_Compute, .storageTexture = .{
                    .access = wgpu.WGPUStorageTextureAccess_ReadWrite,
                    .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .nextInChain = null,
                } },
                .{ .nextInChain = null, .binding = 3, .visibility = wgpu.WGPUShaderStage_Compute, .storageTexture = .{
                    .access = wgpu.WGPUStorageTextureAccess_WriteOnly,
                    .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .nextInChain = null,
                } },

                //                .{ .nextInChain = null, .binding = 3, .visibility = wgpu.WGPUShaderStage_Compute, .buffer = .{
                //                    .type = wgpu.WGPUBufferBindingType_Storage,
                //                    .hasDynamicOffset = wgpu.WGPUOptionalBool_False,
                //                    .minBindingSize = 0,
                //                    .nextInChain = null,
                //                } },
            },
            .nextInChain = null,
        });
        const bind_group_layout3 = wgpu.wgpuDeviceCreateBindGroupLayout(state.device, &.{
            .entryCount = 4,
            .entries = &[_]wgpu.WGPUBindGroupLayoutEntry{
                .{ .nextInChain = null, .binding = 0, .visibility = wgpu.WGPUShaderStage_Compute, .texture = .{
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .sampleType = wgpu.WGPUTextureSampleType_UnfilterableFloat,
                    .multisampled = wgpu.WGPUOptionalBool_False,
                    .nextInChain = null,
                } },

                .{ .nextInChain = null, .binding = 2, .visibility = wgpu.WGPUShaderStage_Compute, .texture = .{
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .sampleType = wgpu.WGPUTextureSampleType_UnfilterableFloat,
                    .multisampled = wgpu.WGPUOptionalBool_False,
                    .nextInChain = null,
                } },
                .{ .nextInChain = null, .binding = 4, .visibility = wgpu.WGPUShaderStage_Compute, .texture = .{
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .sampleType = wgpu.WGPUTextureSampleType_UnfilterableFloat,
                    .multisampled = wgpu.WGPUOptionalBool_False,
                    .nextInChain = null,
                } },
                .{ .nextInChain = null, .binding = 1, .visibility = wgpu.WGPUShaderStage_Compute, .storageTexture = .{
                    .access = wgpu.WGPUStorageTextureAccess_ReadWrite,
                    .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .nextInChain = null,
                } },
            },
            .nextInChain = null,
        });
        const bind_group_layout4 = wgpu.wgpuDeviceCreateBindGroupLayout(state.device, &.{
            .entryCount = 4,
            .entries = &[_]wgpu.WGPUBindGroupLayoutEntry{
                .{ .nextInChain = null, .binding = 0, .visibility = wgpu.WGPUShaderStage_Compute, .texture = .{
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .sampleType = wgpu.WGPUTextureSampleType_UnfilterableFloat,
                    .multisampled = wgpu.WGPUOptionalBool_False,
                    .nextInChain = null,
                } },

                .{ .nextInChain = null, .binding = 2, .visibility = wgpu.WGPUShaderStage_Compute, .texture = .{
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .sampleType = wgpu.WGPUTextureSampleType_UnfilterableFloat,
                    .multisampled = wgpu.WGPUOptionalBool_False,
                    .nextInChain = null,
                } },
                .{ .nextInChain = null, .binding = 1, .visibility = wgpu.WGPUShaderStage_Compute, .storageTexture = .{
                    .access = wgpu.WGPUStorageTextureAccess_ReadWrite,
                    .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .nextInChain = null,
                } },
                .{ .nextInChain = null, .binding = 3, .visibility = wgpu.WGPUShaderStage_Compute, .storageTexture = .{
                    .access = wgpu.WGPUStorageTextureAccess_WriteOnly,
                    .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .nextInChain = null,
                } },
            },
            .nextInChain = null,
        });
        const bind_group_layout5 = wgpu.wgpuDeviceCreateBindGroupLayout(state.device, &.{
            .entryCount = 4,
            .entries = &[_]wgpu.WGPUBindGroupLayoutEntry{
                .{ .nextInChain = null, .binding = 0, .visibility = wgpu.WGPUShaderStage_Compute, .texture = .{
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .sampleType = wgpu.WGPUTextureSampleType_UnfilterableFloat,
                    .multisampled = wgpu.WGPUOptionalBool_False,
                    .nextInChain = null,
                } },

                .{ .nextInChain = null, .binding = 2, .visibility = wgpu.WGPUShaderStage_Compute, .texture = .{
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .sampleType = wgpu.WGPUTextureSampleType_UnfilterableFloat,
                    .multisampled = wgpu.WGPUOptionalBool_False,
                    .nextInChain = null,
                } },
                .{ .nextInChain = null, .binding = 4, .visibility = wgpu.WGPUShaderStage_Compute, .texture = .{
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .sampleType = wgpu.WGPUTextureSampleType_UnfilterableFloat,
                    .multisampled = wgpu.WGPUOptionalBool_False,
                    .nextInChain = null,
                } },
                .{ .nextInChain = null, .binding = 5, .visibility = wgpu.WGPUShaderStage_Compute, .buffer = .{
                    .type = wgpu.WGPUBufferBindingType_Storage,
                    .hasDynamicOffset = wgpu.WGPUOptionalBool_False,
                    .minBindingSize = 0,
                    .nextInChain = null,
                } },
            },
            .nextInChain = null,
        });

        const shader_module = createShadderModule(state.device);
        if (shader_module == null) {
            return error.ShaderCompilationFailed;
        }
        const pipeline_desc: wgpu.WGPUPipelineLayoutDescriptor = .{
            .nextInChain = null,
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = @ptrCast(&bind_group_layout),
        };
        const pipeline_desc2: wgpu.WGPUPipelineLayoutDescriptor = .{
            .nextInChain = null,
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = @ptrCast(&bind_group_layout2),
        };
        const pipeline_desc3: wgpu.WGPUPipelineLayoutDescriptor = .{
            .nextInChain = null,
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = @ptrCast(&bind_group_layout3),
        };
        const pipeline_desc4: wgpu.WGPUPipelineLayoutDescriptor = .{
            .nextInChain = null,
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = @ptrCast(&bind_group_layout4),
        };
        const pipeline_desc5: wgpu.WGPUPipelineLayoutDescriptor = .{
            .nextInChain = null,
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = @ptrCast(&bind_group_layout5),
        };

        const pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(state.device, &pipeline_desc);
        const pipeline_layout2 = wgpu.wgpuDeviceCreatePipelineLayout(state.device, &pipeline_desc2);
        const pipeline_layout3 = wgpu.wgpuDeviceCreatePipelineLayout(state.device, &pipeline_desc3);
        const pipeline_layout4 = wgpu.wgpuDeviceCreatePipelineLayout(state.device, &pipeline_desc4);
        const pipeline_layout5 = wgpu.wgpuDeviceCreatePipelineLayout(state.device, &pipeline_desc5);

        const compute_pipleline_desc: wgpu.WGPUComputePipelineDescriptor = .{
            .layout = pipeline_layout,
            .compute = .{ .module = shader_module, .entryPoint = wgpu.struct_WGPUStringView{
                .data = "main",
                .length = 4,
            }, .nextInChain = null },
            .nextInChain = null,
        };
        const compute_pipeline_desc2: wgpu.WGPUComputePipelineDescriptor = .{
            .layout = pipeline_layout2,
            .compute = .{ .module = shader_module, .entryPoint = wgpu.struct_WGPUStringView{
                .data = "main2",
                .length = 5,
            }, .nextInChain = null },
            .nextInChain = null,
        };
        const compute_pipeline_desc3: wgpu.WGPUComputePipelineDescriptor = .{
            .layout = pipeline_layout3,
            .compute = .{ .module = shader_module, .entryPoint = wgpu.struct_WGPUStringView{
                .data = "main3",
                .length = 5,
            }, .nextInChain = null },
            .nextInChain = null,
        };
        const compute_pipeline_desc4: wgpu.WGPUComputePipelineDescriptor = .{
            .layout = pipeline_layout4,
            .compute = .{ .module = shader_module, .entryPoint = wgpu.struct_WGPUStringView{
                .data = "main4",
                .length = 5,
            }, .nextInChain = null },
            .nextInChain = null,
        };
        const compute_pipeline_desc5: wgpu.WGPUComputePipelineDescriptor = .{
            .layout = pipeline_layout5,
            .compute = .{ .module = shader_module, .entryPoint = wgpu.struct_WGPUStringView{
                .data = "main5",
                .length = 5,
            }, .nextInChain = null },
            .nextInChain = null,
        };

        const pipeline = wgpu.wgpuDeviceCreateComputePipeline(state.device, &compute_pipleline_desc);
        const pipeline2 = wgpu.wgpuDeviceCreateComputePipeline(state.device, &compute_pipeline_desc2);
        const pipeline3 = wgpu.wgpuDeviceCreateComputePipeline(state.device, &compute_pipeline_desc3);
        const pipeline4 = wgpu.wgpuDeviceCreateComputePipeline(state.device, &compute_pipeline_desc4);
        const pipeline5 = wgpu.wgpuDeviceCreateComputePipeline(state.device, &compute_pipeline_desc5);

        const iTextureViewDesc: wgpu.WGPUTextureViewDescriptor = .{
            .nextInChain = null,
            .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
            .dimension = wgpu.WGPUTextureViewDimension_2D,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
            .aspect = wgpu.WGPUTextureAspect_All,
        };
        const iTextureView = wgpu.wgpuTextureCreateView(input_buffer, &iTextureViewDesc);
        const sTextureViewDesc: wgpu.WGPUTextureViewDescriptor = .{
            .nextInChain = null,
            .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
            .dimension = wgpu.WGPUTextureViewDimension_2D,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
            .aspect = wgpu.WGPUTextureAspect_All,
        };
        const sTextureView = wgpu.wgpuTextureCreateView(storage_text, &sTextureViewDesc);
        const sTextureViewDescB: wgpu.WGPUTextureViewDescriptor = .{
            .nextInChain = null,
            .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
            .dimension = wgpu.WGPUTextureViewDimension_2D,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
            .aspect = wgpu.WGPUTextureAspect_All,
        };
        const sTextureViewB = wgpu.wgpuTextureCreateView(storage_textB, &sTextureViewDescB);
        const text2ViewDesc: wgpu.WGPUTextureViewDescriptor = .{
            .nextInChain = null,
            .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
            .dimension = wgpu.WGPUTextureViewDimension_2D,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
            .aspect = wgpu.WGPUTextureAspect_All,
        };
        const text2View = wgpu.wgpuTextureCreateView(text2ping, &text2ViewDesc);

        const bind_group = wgpu.wgpuDeviceCreateBindGroup(state.device, &.{ .nextInChain = null, .layout = bind_group_layout, .entryCount = 2, .entries = &[_]wgpu.WGPUBindGroupEntry{
            .{
                .nextInChain = null,
                .binding = 0,
                .textureView = iTextureView,
            },
            .{
                .nextInChain = null,
                .binding = 1,
                .textureView = sTextureView,
            },
        } });
        const bind_group2 = wgpu.wgpuDeviceCreateBindGroup(state.device, &.{ .nextInChain = null, .layout = bind_group_layout2, .entryCount = 4, .entries = &[_]wgpu.WGPUBindGroupEntry{
            .{
                .nextInChain = null,
                .binding = 0,
                .textureView = iTextureView,
            },
            .{
                .nextInChain = null,
                .binding = 2,
                .textureView = sTextureView,
            },
            .{
                .nextInChain = null,
                .binding = 1,
                .textureView = sTextureViewB,
            },
            .{
                .nextInChain = null,
                .binding = 3,
                .textureView = text2View,
            },
        } });
        const bind_group3 = wgpu.wgpuDeviceCreateBindGroup(state.device, &.{ .nextInChain = null, .layout = bind_group_layout3, .entryCount = 4, .entries = &[_]wgpu.WGPUBindGroupEntry{
            .{
                .nextInChain = null,
                .binding = 0,
                .textureView = iTextureView,
            },
            .{
                .nextInChain = null,
                .binding = 2,
                .textureView = sTextureViewB,
            },
            .{
                .nextInChain = null,
                .binding = 4,
                .textureView = text2View,
            },
            .{
                .nextInChain = null,
                .binding = 1,
                .textureView = sTextureView,
            },
        } });
        const bind_group4 = wgpu.wgpuDeviceCreateBindGroup(state.device, &.{ .nextInChain = null, .layout = bind_group_layout4, .entryCount = 4, .entries = &[_]wgpu.WGPUBindGroupEntry{
            .{
                .nextInChain = null,
                .binding = 0,
                .textureView = iTextureView,
            },
            .{
                .nextInChain = null,
                .binding = 2,
                .textureView = sTextureView,
            },
            .{
                .nextInChain = null,
                .binding = 1,
                .textureView = sTextureViewB,
            },
            .{
                .nextInChain = null,
                .binding = 3,
                .textureView = text2View,
            },
        } });
        const bind_group5 = wgpu.wgpuDeviceCreateBindGroup(state.device, &.{ .nextInChain = null, .layout = bind_group_layout5, .entryCount = 4, .entries = &[_]wgpu.WGPUBindGroupEntry{
            .{
                .nextInChain = null,
                .binding = 0,
                .textureView = iTextureView,
            },
            .{
                .nextInChain = null,
                .binding = 2,
                .textureView = sTextureViewB,
            },
            .{
                .nextInChain = null,
                .binding = 4,
                .textureView = text2View,
            },
            .{
                .nextInChain = null,
                .binding = 5,
                .buffer = output_buffer,
                .offset = 0,
                .size = size,
            },
        } });

        const encoder_desc: wgpu.WGPUCommandEncoderDescriptor = .{
            .nextInChain = null,
        };
        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(state.device, &encoder_desc);

        const pass_desc: wgpu.WGPUComputePassDescriptor = .{
            .nextInChain = null,
        };
        const compute_pass = wgpu.wgpuCommandEncoderBeginComputePass(encoder, &pass_desc);
        _ = wgpu.wgpuComputePassEncoderSetPipeline(compute_pass, pipeline);
        _ = wgpu.wgpuComputePassEncoderSetBindGroup(compute_pass, 0, bind_group, 0, null);
        _ = wgpu.wgpuComputePassEncoderDispatchWorkgroups(compute_pass, dispatch_x, dispatch_y, 1);
        _ = wgpu.wgpuComputePassEncoderEnd(compute_pass);

        const compute_pass2 = wgpu.wgpuCommandEncoderBeginComputePass(encoder, &pass_desc);
        _ = wgpu.wgpuComputePassEncoderSetPipeline(compute_pass2, pipeline2);
        _ = wgpu.wgpuComputePassEncoderSetBindGroup(compute_pass2, 0, bind_group2, 0, null);
        _ = wgpu.wgpuComputePassEncoderDispatchWorkgroups(compute_pass2, dispatch_x, dispatch_y, 1);
        _ = wgpu.wgpuComputePassEncoderEnd(compute_pass2);

        const compute_pass3 = wgpu.wgpuCommandEncoderBeginComputePass(encoder, &pass_desc);
        _ = wgpu.wgpuComputePassEncoderSetPipeline(compute_pass3, pipeline3);
        _ = wgpu.wgpuComputePassEncoderSetBindGroup(compute_pass3, 0, bind_group3, 0, null);
        _ = wgpu.wgpuComputePassEncoderDispatchWorkgroups(compute_pass3, dispatch_x, dispatch_y, 1);
        _ = wgpu.wgpuComputePassEncoderEnd(compute_pass3);

        const compute_pass4 = wgpu.wgpuCommandEncoderBeginComputePass(encoder, &pass_desc);
        _ = wgpu.wgpuComputePassEncoderSetPipeline(compute_pass4, pipeline4);
        _ = wgpu.wgpuComputePassEncoderSetBindGroup(compute_pass4, 0, bind_group4, 0, null);
        _ = wgpu.wgpuComputePassEncoderDispatchWorkgroups(compute_pass4, dispatch_x, dispatch_y, 1);
        _ = wgpu.wgpuComputePassEncoderEnd(compute_pass4);

        const compute_pass5 = wgpu.wgpuCommandEncoderBeginComputePass(encoder, &pass_desc);
        _ = wgpu.wgpuComputePassEncoderSetPipeline(compute_pass5, pipeline5);
        _ = wgpu.wgpuComputePassEncoderSetBindGroup(compute_pass5, 0, bind_group5, 0, null);
        _ = wgpu.wgpuComputePassEncoderDispatchWorkgroups(compute_pass5, dispatch_x, dispatch_y, 1);
        _ = wgpu.wgpuComputePassEncoderEnd(compute_pass5);

        _ = wgpu.wgpuCommandEncoderCopyBufferToBuffer(encoder, output_buffer, 0, copy_buffer, 0, size);

        const command = wgpu.wgpuCommandEncoderFinish(encoder, null);
        const queue = wgpu.wgpuDeviceGetQueue(state.device);
        _ = wgpu.wgpuQueueSubmit(queue, 1, @ptrCast(&command));
        std.debug.print("queue submitted\n", .{});

        _ = wgpu.wgpuBufferMapAsync(copy_buffer, wgpu.WGPUMapMode_Read, 0, size, buffer_callback);
        _ = wgpu.wgpuDevicePoll(state.device, wgpu.WGPUOptionalBool_True, null);

        state.mutex.lock();
        while (!state.bmap_ready) {
            state.cond.wait(&state.mutex);
        }
        state.mutex.unlock();
        std.debug.print("async done\n", .{});

        const mapped_ptr = wgpu.wgpuBufferGetMappedRange(copy_buffer, 0, size);
        const mapped_bytes: [*]u8 = @ptrCast(mapped_ptr);
        const output_data = mapped_bytes[0..size];

        var final_image = stb_image.Image{
            .width = img.width,
            .height = img.height,
            .channels = img.channels,
            .pixels = undefined,
        };

        final_image.pixels = if (output_data.len != 0) &output_data[0] else null;

        const ofilename = "wgpu.png";

        stb_image_write.writeImage(ofilename, &final_image);

        wgpu.wgpuBufferUnmap(copy_buffer);
    }

    var rimg = try resize(alloc, img);

    defer if (img.pixels != null) {
        stb_image.freeImage(&img);
    };

    std.debug.print("loaded image size: {?}x{?} with {?} channels\n", .{ img.width, img.height, img.channels });

    if (img.pixels) |pixels| {
        std.debug.print("image pixel data: {*}\n", .{pixels});
    } else {
        std.debug.print("image pixel data: (null)\n", .{});
    }
    const rfilename = "test2.png";
    const wfilename = "test.png";
    std.debug.print("attempting to write image", .{});

    stb_image_write.writeImage(wfilename, &img);
    stb_image_write.writeImage(rfilename, &rimg);
}
fn createShadderModule(device: ?*wgpu.struct_WGPUDeviceImpl) ?*wgpu.struct_WGPUShaderModuleImpl {
    std.debug.print("Shader content: {any}\n", .{shader_wgsl});
    std.debug.print("Shader length: {any}\n", .{shader_wgsl.len});
    std.debug.print("device ptr: {*}\n", .{device});

    const wgsl_stype = @as(wgpu.WGPUSType, wgpu.WGPUSType_ShaderSourceWGSL);
    std.debug.print("wgsl_stype: {any}\n", .{wgsl_stype});
    const wgsl_chain: wgpu.WGPUChainedStruct = .{
        .sType = wgsl_stype,
        .next = null,
    };
    const wgsl_desc: wgpu.WGPUShaderSourceWGSL = .{
        .chain = wgsl_chain,
        .code = .{
            .data = shader_wgsl.ptr,
            .length = shader_wgsl.len,
        },
    };
    const shader_desc: wgpu.WGPUShaderModuleDescriptor = .{
        .nextInChain = @ptrCast(&wgsl_desc),
    };
    std.debug.print("Shader ptr: {*}\n", .{shader_desc.nextInChain});

    std.debug.print("creating shader module\n", .{});
    const module = wgpu.wgpuDeviceCreateShaderModule(device, &shader_desc);

    if (module == null) {
        std.debug.print("failed to create shader module", .{});
    } else {
        std.debug.print("shader module created\n", .{});
    }
    return module;
}
fn wgpuInit() void {
    const required_features = [_]wgpu.WGPUFeatureName{
        wgpu.WGPUNativeFeature_TextureAdapterSpecificFormatFeatures,
    };
    const options: wgpu.WGPURequestAdapterOptions = .{
        .powerPreference = wgpu.WGPUPowerPreference_HighPerformance,
        .compatibleSurface = null,
        .forceFallbackAdapter = wgpu.WGPUOptionalBool_False,
    };
    const adapter_callback: wgpu.WGPURequestAdapterCallbackInfo = .{
        .nextInChain = null,
        .callback = callback.adapterCall,
        .userdata1 = &state,
        .userdata2 = null,
    };
    const device_desc: wgpu.WGPUDeviceDescriptor = .{
        .nextInChain = null,
        .requiredFeatures = &required_features,
        .requiredFeatureCount = required_features.len,
        .requiredLimits = null,
        .defaultQueue = .{
            .nextInChain = null,
        },
    };
    const device_callback: wgpu.WGPURequestDeviceCallbackInfo = .{
        .nextInChain = null,
        .callback = callback.deviceCall,
        .userdata1 = &state,
        .userdata2 = null,
    };

    state.instance = wgpu.wgpuCreateInstance(null);

    if (state.instance == null) {
        std.debug.print("Failed to initilize WGPU\n", .{});
    } else {
        std.debug.print("WGPU Instance: {any}\n", .{state.instance});
    }
    std.debug.print("Requesting Adapter\n", .{});
    _ = wgpu.wgpuInstanceRequestAdapter(state.instance, &options, adapter_callback);
    //Release WgpuInstance
    wgpu.wgpuInstanceRelease(state.instance);

    state.mutex.lock();
    while (!state.adapter_ready) {
        state.cond.wait(&state.mutex);
    }
    state.mutex.unlock();



    std.debug.print("Adapter received {any}\n", .{state.adapter});

    //Request Device
    _ = wgpu.wgpuAdapterRequestDevice(state.adapter.?, &device_desc, device_callback);
    state.mutex.lock();
    while (!state.device_ready) {
        state.cond.wait(&state.mutex);
    }
    state.mutex.unlock();

    std.debug.print("Device recieved: {any}\n", .{state.device});
}
const callback = struct {
    pub fn adapterCall(
        status: wgpu.WGPURequestAdapterStatus,
        adapter: ?*wgpu.struct_WGPUAdapterImpl,
        message: wgpu.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.C) void {
        _ = message;
        _ = userdata2;

        const state_ptr: *State = @alignCast(@ptrCast(userdata1.?));

        state_ptr.mutex.lock();
        defer state_ptr.mutex.unlock();

        state_ptr.adapter = adapter;
        state_ptr.adapter_ready = (status == wgpu.WGPURequestAdapterStatus_Success);
        state_ptr.cond.signal();
    }
    pub fn deviceCall(
        status: wgpu.WGPURequestDeviceStatus,
        device: ?*wgpu.struct_WGPUDeviceImpl,
        message: wgpu.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.C) void {
        _ = message;
        _ = userdata2;

        const state_ptr: *State = @alignCast(@ptrCast(userdata1.?));

        state_ptr.mutex.lock();
        defer state_ptr.mutex.unlock();

        state_ptr.device = device;
        state_ptr.queue = wgpu.wgpuDeviceGetQueue(device.?);
        state_ptr.device_ready = (status == wgpu.WGPURequestDeviceStatus_Success);
        state_ptr.cond.signal();
    }
    pub fn bufferCall(
        status: wgpu.WGPUMapAsyncStatus,
        message: wgpu.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.C) void {
        std.debug.print("buffercall status {}\n", .{status});
        _ = userdata2;
        _ = message;
        const state_ptr: *State = @alignCast(@ptrCast(userdata1.?));
        state_ptr.mutex.lock();
        defer state_ptr.mutex.unlock();

        state_ptr.bmap_ready = (status == wgpu.WGPUMapAsyncStatus_Success);

        state_ptr.cond.signal();
    }
};
fn initSTexture(w: u32, h: u32) wgpu.WGPUTexture {
    const desc: wgpu.WGPUTextureDescriptor = .{
        .size = .{ .width = w, .height = h, .depthOrArrayLayers = 1 },
        .mipLevelCount = 1,
        .sampleCount = 1,
        .dimension = wgpu.WGPUTextureDimension_2D,
        .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
        .usage = wgpu.WGPUTextureUsage_StorageBinding | wgpu.WGPUTextureUsage_TextureBinding,
    };
    return wgpu.wgpuDeviceCreateTexture(state.device, &desc);
}
fn initSTextureB(w: u32, h: u32) wgpu.WGPUTexture {
    const desc: wgpu.WGPUTextureDescriptor = .{
        .size = .{ .width = w, .height = h, .depthOrArrayLayers = 1 },
        .mipLevelCount = 1,
        .sampleCount = 1,
        .dimension = wgpu.WGPUTextureDimension_2D,
        .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
        .usage = wgpu.WGPUTextureUsage_StorageBinding | wgpu.WGPUTextureUsage_TextureBinding,
    };
    return wgpu.wgpuDeviceCreateTexture(state.device, &desc);
}
fn inittext2ping(w: u32, h: u32) wgpu.WGPUTexture {
    const desc: wgpu.WGPUTextureDescriptor = .{
        .size = .{ .width = w, .height = h, .depthOrArrayLayers = 1 },
        .mipLevelCount = 1,
        .sampleCount = 1,
        .dimension = wgpu.WGPUTextureDimension_2D,
        .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
        .usage = wgpu.WGPUTextureUsage_StorageBinding | wgpu.WGPUTextureUsage_TextureBinding,
    };
    return wgpu.wgpuDeviceCreateTexture(state.device, &desc);
}

fn initTexture(data: []const u8, w: u32, h: u32) wgpu.WGPUTexture {
    const desc: wgpu.WGPUTextureDescriptor = .{
        .size = .{ .width = w, .height = h, .depthOrArrayLayers = 1 },
        .mipLevelCount = 1,
        .sampleCount = 1,
        .dimension = wgpu.WGPUTextureDimension_2D,
        .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
        .usage = wgpu.WGPUTextureUsage_CopyDst | wgpu.WGPUTextureUsage_TextureBinding,
    };
    const texture = wgpu.wgpuDeviceCreateTexture(state.device, &desc);
    const tdestination: wgpu.WGPUTexelCopyTextureInfo = .{
        .texture = texture,
        .aspect = wgpu.WGPUTextureAspect_All,
        .mipLevel = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
    };
    const tlayout: wgpu.WGPUTexelCopyBufferLayout = .{
        .bytesPerRow = 4 * w,
        .offset = 0,
        .rowsPerImage = h,
    };
    const tsize: wgpu.WGPUExtent3D = .{
        .depthOrArrayLayers = 1,
        .width = w,
        .height = h,
    };

    _ = wgpu.wgpuQueueWriteTexture(wgpu.wgpuDeviceGetQueue(state.device), &tdestination, data.ptr, data.len, &tlayout, &tsize);
    return texture;
}

fn rbufferinit(size: usize) wgpu.WGPUBuffer {
    const desc: wgpu.WGPUBufferDescriptor = .{
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopySrc,
        .size = @as(u64, size),
        .mappedAtCreation = wgpu.WGPUOptionalBool_False,
    };
    return wgpu.wgpuDeviceCreateBuffer(state.device, &desc);
}
fn cbufferinit(size: usize) wgpu.WGPUBuffer {
    const desc: wgpu.WGPUBufferDescriptor = .{
        .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_MapRead,
        .size = @as(u64, size),
        .mappedAtCreation = wgpu.WGPUOptionalBool_False,
    };
    return wgpu.wgpuDeviceCreateBuffer(state.device, &desc);
}

fn resize(allocator: std.mem.Allocator, img: stb_image.Image) !stb_image.Image {
    const imgW: usize = @intCast(img.width);
    const imgH: usize = @intCast(img.height);
    const imgC: usize = @intCast(img.channels);
    const bufP: [*]u8 = @ptrCast(img.pixels.?);
    const imgP: []u8 = bufP[0..(imgW * imgH * imgC)];

    const new_w = @divFloor(imgW, 8);
    const new_h = @divFloor(imgH, 8);
    const new_c = imgC;
    const new_pixel_count = new_w * new_h * new_c;
    const pixel_count = imgW * imgH * imgC;

    var rimg: stb_image.Image = .{
        //        .width = @intCast(new_w),
        //        .height = @intCast(new_h),
        //        .channels = @intCast(new_c),
        .width = img.width,
        .height = img.height,
        .channels = img.channels,
        .pixels = undefined,
    };

    const slice: []u8 = try allocator.alloc(u8, new_pixel_count);
    const upscale: []u8 = try allocator.alloc(u8, pixel_count);

    const linear = try luminize(imgW, imgH, imgC, imgP, allocator);

    for (0..new_w) |x| {
        for (0..new_h) |y| {
            const originX = @divFloor(x * imgW, new_w);
            const originY = @divFloor(y * imgH, new_h);
            const indexN = ((y * new_w + x) * new_c);
            const indexO = ((originY * imgW + originX) * imgC);

            for (0..new_c) |c| {
                slice[indexN + c] = linear[indexO + c];
            }
        }
    }
    for (0..new_w) |x| {
        for (0..new_h) |y| {
            const oX = @divFloor(x * imgW, new_w);
            const oY = @divFloor(y * imgH, new_h);
            const index = ((y * new_w + x) * new_c);

            for (0..8) |w| {
                for (0..8) |h| {
                    const uX = oX + w;
                    const uY = oY + h;
                    const indexO = ((uY * imgW + uX) * imgC);

                    for (0..new_c) |c| {
                        upscale[indexO + c] = slice[index + c];
                    }
                }
            }
        }
    }

    rimg.pixels = if (upscale.len != 0) &upscale[0] else null;
    return rimg;
}

fn luminize(w: usize, h: usize, c: usize, p: []u8, alloc: std.mem.Allocator) ![]u8 {
    const pc = w * h * c;
    const linearized: []u8 = try alloc.alloc(u8, pc);
    for (0..w) |x| {
        for (0..h) |y| {
            const indexL = ((y * w + x) * c);

            const r: f32 = @floatFromInt(p[indexL + 0]);
            const g: f32 = @floatFromInt(p[indexL + 1]);
            const b: f32 = @floatFromInt(p[indexL + 2]);
            const vR: f32 = linearize(r / 255.0);
            const vG: f32 = linearize(g / 255.0);
            const vB: f32 = linearize(b / 255.0);
            const lum = vR * 0.2126 + vG * 0.7152 + vB * 0.0722;
            const constrained = @floor(lum * 10) / 10;

            for (0..c) |i| {
                linearized[indexL + i] = @intFromFloat(std.math.clamp(constrained * 255, 0, 255));
            }
        }
    }
    return linearized;
}

fn srgbize(c: f32) f32 {
    if (c <= 0.0031308) {
        return c * 12.92;
    } else {
        return std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    }
}
fn linearize(c: f32) f32 {
    if (c <= 0.04045) {
        return c / 12.92;
    } else {
        return std.math.pow(f32, ((c + 0.055) / 1.055), 2.4);
    }
}
