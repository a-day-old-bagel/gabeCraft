/**********************************************************************
Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/
#pragma once

uint FFX_DNSR_Shadows_RoundedDivide(uint value, uint divisor) {
    return (value + divisor - 1) / divisor;
}

uvec2 FFX_DNSR_Shadows_GetTileIndexFromPixelPosition(uvec2 pixel_pos) {
    return uvec2(pixel_pos.x / 8, pixel_pos.y / 4);
}

uint FFX_DNSR_Shadows_LinearTileIndex(uvec2 tile_index, uint screen_width) {
    return tile_index.y * FFX_DNSR_Shadows_RoundedDivide(screen_width, 8) + tile_index.x;
}

uint FFX_DNSR_Shadows_GetBitMaskFromPixelPosition(uvec2 pixel_pos) {
    uint lane_index = (pixel_pos.y % 4) * 8 + (pixel_pos.x % 8);
    return (1u << lane_index);
}

#define TILE_META_DATA_CLEAR_MASK 1u
#define TILE_META_DATA_LIGHT_MASK 2u

// From ffx_a.h

uint FFX_DNSR_Shadows_BitfieldExtract(uint src, uint off, uint bits) {
    uint mask = (1u << bits) - 1u;
    return (src >> off) & mask;
} // ABfe
uint FFX_DNSR_Shadows_BitfieldInsert(uint src, uint ins, uint bits) {
    uint mask = (1u << bits) - 1u;
    return (ins & mask) | (src & (~mask));
} // ABfiM

//  LANE TO 8x8 MAPPING
//  ===================
//  00 01 08 09 10 11 18 19
//  02 03 0a 0b 12 13 1a 1b
//  04 05 0c 0d 14 15 1c 1d
//  06 07 0e 0f 16 17 1e 1f
//  20 21 28 29 30 31 38 39
//  22 23 2a 2b 32 33 3a 3b
//  24 25 2c 2d 34 35 3c 3d
//  26 27 2e 2f 36 37 3e 3f
uvec2 FFX_DNSR_Shadows_RemapLane8x8(uint lane) {
    return uvec2(FFX_DNSR_Shadows_BitfieldInsert(FFX_DNSR_Shadows_BitfieldExtract(lane, 2u, 3u), lane, 1u), FFX_DNSR_Shadows_BitfieldInsert(FFX_DNSR_Shadows_BitfieldExtract(lane, 3u, 3u), FFX_DNSR_Shadows_BitfieldExtract(lane, 1u, 2u), 2u));
}

#define select(cond, a, b) ((cond) ? (a) : (b))
#define rcp(x) (1.0 / x)
