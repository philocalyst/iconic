#include <metal_stdlib>
using namespace metal;

// Here we define a structure to hold the coordinates of the bounding box
// Unsigned integers as no dimension is negative.
// We're using atomic types to prevent race conditions and avoid locks
struct BoundingBox {
    atomic_uint minX;
    atomic_uint minY;
    atomic_uint maxX;
    atomic_uint maxY;
};

// Kernel processes multiple elements in parallel
kernel void findBoundingBox(
    // Taking read-only access to the input texture (Making the assumption it is of colorspace RGBA)
    texture2d<float, access::read> inputTexture [[texture(0)]],

    // Taking read-write access to the bounding box struct
    device BoundingBox *boundingBox [[buffer(0)]],

    // Grid position: The unique 2D index (x, y) of the current thread in the grid.
	// This *should* be the pixel position.
    uint2 gid [[thread_position_in_grid]])
{
    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();

	// We need bound checks here in case the created grid is larger than the actual texture size.
    if (gid.x >= width || gid.y >= height) {
        return; // This thread is outside the image bounds, do nothing.
    }

    // Get the RGBA value of the thread responsible for the current position
    // Each of the four values(R-G-B-A) are typically normalized the [0.0, 1.0]
    float4 color = inputTexture.read(gid);

	// We need to declare an alpha threshold to pick up on pixels that might not have a true transparent value (0 Alpha), but most human eyes would register as invisible anyways.
	// This threshold is 1.0/255.0 (approx 0.0039), the smallest possible non-zero alpha. (Assuming 8-bit RGBA)
    constexpr float alphaThreshold = .303f;

	// We create the bounding box through perhaps counter-intuitively marking the non-alpha values.
	// Since the GPU will work through the texture from different positions at different rates, it is generally slower to force a shrinking frame, as might be common in CPU implementations.
	// This method is thread-safe and marks the dimensions of visible cutout after splattering through the values.
    if (color.a > alphaThreshold) {
        // Update and store minimum X coordinate
        atomic_fetch_min_explicit(&boundingBox->minX, gid.x, memory_order_relaxed);

        // Update and store minimum Y coordinate
        atomic_fetch_min_explicit(&boundingBox->minY, gid.y, memory_order_relaxed);

        // We tell atomic fetch to use relaxed memory order because when min/max values are updated doesn't affect the final correct result. 

        // Update and store maximum X coordinate
        atomic_fetch_max_explicit(&boundingBox->maxX, gid.x, memory_order_relaxed);

        // Update maximum Y coordinate
        atomic_fetch_max_explicit(&boundingBox->maxY, gid.y, memory_order_relaxed);

        // NOTE: maxX and maxY store the coordinate of the *last* non-transparent pixel
		// To avoid clipping, add one to your dimensions for both width and height
    }
}
