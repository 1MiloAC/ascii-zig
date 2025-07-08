@group(0) @binding(0) var input_buffer: texture_2d<f32>;
@group(0) @binding(1) var text_store_w: texture_storage_2d<rgba8unorm, read_write>;
@group(0) @binding(2) var text_store_r: texture_2d<f32>;
@group(0) @binding(3) var text2_w: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(4) var text2_r: texture_2d<f32>;
@group(0) @binding(5) var<storage, read_write> output_buffer: array<u32>;

override SIZE: u32 = 19;


@compute @workgroup_size(16,16)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(global_id.xy);
    let dims = textureDimensions(input_buffer);

    if coords.x >= i32(dims.x) || coords.y >= i32(dims.y) {
        return;
    }

    let pixel = textureLoad(input_buffer, coords, 0);

    let linear_r = linearize(pixel.r);
    let linear_g = linearize(pixel.g);
    let linear_b = linearize(pixel.b);

    let pixel_l = vec3<f32>(linear_r, linear_g, linear_b);
    let lum_weight = vec3<f32>(0.2126, 0.7152, 0.0722);

    let linear = dot(pixel_l, lum_weight);
//    let srgb = srgbize(linear);

    let srgb_packed = vec4<f32>(
        linear,
        linear,
        linear,
        pixel.a
    );
    textureStore(text_store_w, coords, srgb_packed);
}
@compute @workgroup_size(16, 16)
fn main2(@builtin(global_invocation_id) global_id: vec3<u32>) {

    let coords = vec2<i32>(global_id.xy);
    let dims = textureDimensions(input_buffer);

    if coords.x >= i32(dims.x) || coords.y >= i32(dims.y) {
        return;
    }

    let sigma = 2f;
    let convolve = gauss(coords, sigma, vec2<i32>(1, 0), text_store_r);
    let sigma2 = sigma * sqrt(2f);
    let convolve2 = gauss(coords, sigma2, vec2<i32>(1, 0), text_store_r);
    textureStore(text_store_w, coords, convolve);
    textureStore(text2_w, coords, convolve2);
}
@compute @workgroup_size(16,16)
fn main3(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(global_id.xy);
    let dims = textureDimensions(input_buffer);

    if coords.x >= i32(dims.x) || coords.y >= i32(dims.y) {
        return;
    }

    let sigma = 2f;
    let convolve = gauss(coords, sigma, vec2<i32>(0, 1), text_store_r);
    let sigma2 = sigma * sqrt(2f);
    let convolve2 = gauss(coords, sigma2, vec2<i32>(0, 1), text2_r);

    let p = 30f;
    let e = 0.4f;
    let phi = 3f;
    let xdog = ((1f + p) * convolve.r - p * convolve2.r);
    var txdog: f32;
    if xdog >= e {
        txdog = 1f;
    } else {
        txdog = 1f + tanh(phi * (xdog - e));
    };

    let test = vec4<f32>(
        txdog,
        txdog,
        txdog,
        convolve.a
    );

    textureStore(text_store_w,coords,test);

    //let packed = pack4x8unorm(abs(test));
    //let index = u32(coords.y) * dims.x + u32(coords.x);
    //output_buffer[index] = packed;
} 
@compute @workgroup_size(16,16)
fn main4(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(global_id.xy);
    let dims = textureDimensions(input_buffer);

    if coords.x >= i32(dims.x) || coords.y >= i32(dims.y) {
        return;
    }
    let convolve = sobel(coords, true, vec2<i32>(1,0), text_store_r);
    let convolve2 = sobel(coords, false, vec2<i32>(1,0), text_store_r);
    textureStore(text_store_w, coords, convolve);
    textureStore(text2_w, coords, convolve2);
}
@compute @workgroup_size(16,16)
fn main5(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let coords = vec2<i32>(global_id.xy);
    let dims = textureDimensions(input_buffer);

    if coords.x >= i32(dims.x) || coords.y >= i32(dims.y) {
        return;
    }
    let convolve = sobel(coords, false, vec2<i32>(0,1), text_store_r);
    let convolve2 = sobel(coords, true, vec2<i32>(0,1), text2_r);

    let g = sqrt(convolve.r * convolve.r + convolve2.r * convolve2.r);
    let g_packed = vec4<f32>(
        g,
        g,
        g,
        convolve.a,
    );
    let packed = pack4x8unorm(g_packed);
    let index = u32(coords.y) * dims.x + u32(coords.x);
    output_buffer[index] = packed;
}
fn gauss(coords: vec2<i32>, sigma: f32, direction: vec2<i32>, texture: texture_2d<f32>) -> vec4<f32> {
    let k_size = sigma * 6f + 1f;
    let k_middle = ceil((k_size - 1) / 2.0);
    let arr = kernal(k_size, k_middle, sigma);
    var convolve: vec3<f32> = vec3<f32>(0.0);
    var alpha = 0f;

    for (var i: i32; i < i32(k_size); i = i + 1) {
        let offset = i - i32(k_middle);
        let input_coords = coords + direction * offset;
        let pix = textureLoad(texture, input_coords, 0);
        alpha = pix.a;
        convolve += vec3<f32>(pix.rgb * arr[i]);
    }
    return vec4<f32>(convolve, alpha);
} 
fn sobel(coords: vec2<i32>, axis: bool, direction: vec2<i32>, texture: texture_2d<f32>) -> vec4<f32> {
    let p1 = array<f32,3>(1, 2, 1);
    let p2 = array<f32,3>(-1, 0, 1);
    var kernal = array<f32,3>();
    var alpha = 0f;
    var convolve: vec3<f32> = vec3<f32>(0.0);

    if axis == true {
        kernal = p1;
    } else {
        kernal = p2;
    }

    for (var i: i32; i < i32(3); i = i + 1) {
        let offset = i - 1;
        let input_coords = coords + direction * offset;
        let pix = textureLoad(texture, input_coords, 0);
        alpha = pix.a;
        convolve += vec3<f32>(pix.rgb * kernal[i]);
    }
    return vec4<f32>(convolve, alpha);
}
fn kernal(k: f32, m: f32, s: f32) -> array<f32, 32> {
    let pi = radians(180f);
    var constraint = 0f;
    var arr: array<f32, 32>;

    for (var i: f32 = 0.0f; i < f32(k); i = i + 1.0f) {
        let x2: f32 = pow((i - m), 2f);
        let gvalue = 1f / sqrt(2f * pi * s) * exp(-x2 / (2f * pow(s, 2f)));
        arr[u32(i)] = gvalue;
        constraint += gvalue;
    }
    for (var i = 0u; i < u32(k); i = i + 1u) {
        arr[i] = arr[i] / constraint;
    }
    return arr;
}

fn srgbize(c: f32) -> f32 {
    if c <= 0.0031308 {
        return c * 12.92;
    } else {
        return pow(c, 1.0 / 2.4) - 0.055;
    }
}
fn linearize(c: f32) -> f32 {
    if c <= 0.04045 {
        return c / 12.92;
    } else {
        return pow(((c + 0.055) / 1.055), 2.4);
    }
}
