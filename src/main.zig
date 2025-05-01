const std = @import("std");
const stb_image = @import("stb_image.zig");
const stb_image_write = @import("stb_image_write.zig");

const Error = error{ImageLoadFailed};

pub fn main() !void {
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

    var img = image.?;
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

    //Downscaler
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
    //Upscaler
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

    const gauss = try gaussian(imgW, imgH, imgC, linear, allocator);
    rimg.pixels = if (gauss.len != 0) &gauss[0] else null;
    return rimg;
}
fn gaussian(w: usize, h:usize, c: usize, p: []u8, allocator: std.mem.Allocator) ![]u8 {
    const size = w * h * c;
    var gauss: []u8 = try allocator.alloc(u8, size);
    const sigma: f32 = 2;
    const K = try kernal(sigma); 
    var conv: f32 = undefined;

    for (0..h) |y| {
        for (0..w) |x| {
            const index = ((y * w + x) * c);

            //Calculate convolution
            for (0..c) |channel| {

                conv = 0.0;
                for (K, 0..) |row, i| {
                    for (row, 0..) |value, j| {
                        const si: i32 = @intCast(i);
                        const sj: i32 = @intCast(j);
                        const sx: i32 = @intCast(x);
                        const sy: i32 = @intCast(y);

                        const sw: i32 = @intCast(w);
                        const sc: i32 = @intCast(c);

                        const x2: i32 = si - 3;
                        const y2: i32 = sj - 3;

                        const nx: i32 = sx + x2;
                        const ny: i32 = sy + y2;
                        
                        const schannel: i32 = @intCast(channel);
                        //std.debug.print("si = {}\n",.{si});
                        //std.debug.print("sj = {}\n",.{sj});
                        if (nx >= 0 and ny >= 0 and nx < w and ny < h) {

                            const gi: usize = @intCast((ny * sw + nx) * sc + schannel);
                            const pv: f32 = @floatFromInt(p[gi]);

                            //std.debug.print("nx = {}\n",.{nx});
                            //std.debug.print("ny = {}\n",.{ny});
                            //std.debug.print("gi = {}\n",.{gi});
                            //std.debug.print("pv = {}\n",.{pv});
                            conv += pv * value; 
                            //std.debug.print("conv = {}\n",.{conv});

                        }

                    }
                }
                const clamp_conv = std.math.clamp(conv,0.0, 255.0);
                gauss[index + channel] = @intFromFloat(clamp_conv);
            }

        }
    }
    for (0..20) |i| {
        std.debug.print("in[{}]={} out = {}\n",.{i, p[i],gauss[i]});
    }
    return gauss;
}
fn luminize(w: usize, h: usize, c: usize, p: []u8, allocator: std.mem.Allocator) ![]u8 {
    const pc = w * h * c;
    const luminized: []u8 = try allocator.alloc(u8, pc);
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
            //const constrained = @floor(lum * 10) / 10;

            for (0..c) |i| {
                //Use lum, or constrained for banding
                luminized[indexL + i] = @intFromFloat(std.math.clamp( lum * 255, 0, 255));
            }
        }
    }
    return luminized;
}
fn kernal(sigma: f32) ![7][7]f32 {
    
    var K: [7][7]f32 = undefined;
    var constraint: f32 = undefined;
    for (K, 0..) |row, i| {
        for (row, 0..) |_, j| {
            const x: i32 = @intCast(i);
            const y: i32 = @intCast(j);
            const nx: i32 = x - 3;
            const ny: i32 = y - 3;
            const pvalue = 1/(2 * std.math.pi * sigma * sigma) * std.math.exp(-(std.math.pow(f32,@floatFromInt(nx),2) + std.math.pow(f32,@floatFromInt(ny),2))/2 * sigma);

            K[i][j] = pvalue;
            constraint += pvalue;
            //std.debug.print("row is {}\n",.{row});
            std.debug.print("pvalue is {}\n",.{pvalue});
        }
    }
    for (K, 0..) |row, i| {
        for (row, 0..) |value, j| {
            K[i][j] = value / constraint;
            std.debug.print("v/c = {}\n",.{value/constraint});
        }
    }
    
return K;

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
