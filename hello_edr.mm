// Demo of EDR (Extended Dynamic Range) support in Hello ImGui.

//from https://github.com/pthom/hello_imgui/blob/master/src/hello_imgui_demos/hello_edr/hello_edr.mm

/*

Run in this order:
mkdir build && cd build

Fetch hello_imgui source
/Users/ayk27/Desktop/Programs/CMake.app/Contents/bin/cmake ..

use metal, so hello_edr can be successfully built
/Users/ayk27/Desktop/Programs/CMake.app/Contents/bin/cmake -DHELLOIMGUI_HAS_METAL=ON -DHELLOIMGUI_HAS_OPENGL3=OFF ..

make -j 8

to see console logs, run
/Users/ayk27/Desktop/hello_imgui_template/build/hello_edr.app/Contents/MacOS/hello_edr 
*/

/*
TODO
color gamut mismatch, rendered as bt2020 but shown on ~p3 display. best to match mac exactly


/*

#ifdef HELLOIMGUI_HAS_METAL
#include "hello_imgui/hello_imgui.h"
#include "hello_imgui/internal/image_metal.h"
#include <memory>

#include <cstdint>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

// Use extern "C" because avif.h is C code
extern "C" {
#include "avif/avif.h"
}

// Then you can start decoding/loading AVIF images


namespace Float16_Emulation
{
#include <cstdint>
#include <cmath>
#include <limits>

// Function to convert a 32-bit float (float) to a 16-bit float (uint16_t)
// This implementation follows the IEEE 754 half-precision floating-point format (binary16).
// It handles signs, exponents, and mantissas, including special cases like
// infinities, NaNs, and denormalized numbers.
uint16_t float32_to_float16(float value) {
    // Use a union to access the bit representation of the float
    union {
        float f;
        uint32_t u;
    } f32;
    f32.f = value;

    uint32_t f32_bits = f32.u;

    // Extract sign, exponent, and mantissa from float32
    uint32_t sign = (f32_bits >> 31) & 0x01;
    uint32_t exponent = (f32_bits >> 23) & 0xFF;
    uint32_t mantissa = f32_bits & 0x7FFFFF;

    uint16_t f16_bits = 0;

    // Handle special cases
    if (exponent == 0xFF) { // Infinity or NaN
        f16_bits = (sign << 15) | 0x7C00; // Set sign and exponent to max for infinity/NaN
        if (mantissa != 0) {
            f16_bits |= 0x0200; // Set a bit in mantissa for NaN (non-signaling NaN)
        }
    } else if (exponent == 0) { // Zero or denormalized
        f16_bits = (sign << 15); // Set sign
        // Denormalized float32 becomes zero in float16 (flush to zero)
        // This is a common behavior, though not strictly required by IEEE 754 for conversion.
        // For strict adherence, one would need to handle denormalized conversion.
    } else { // Normalized numbers
        // Adjust exponent bias: float32 bias is 127, float16 bias is 15
        int16_t new_exponent = exponent - 127 + 15;

        if (new_exponent >= 31) { // Overflow (becomes infinity)
            f16_bits = (sign << 15) | 0x7C00; // Set sign and max exponent
        } else if (new_exponent <= 0) { // Underflow (becomes denormalized or zero)
            // Convert to denormalized float16 or zero
            // The mantissa needs to be shifted right based on the negative exponent.
            // If new_exponent is -1, shift mantissa right by 1 (11 bits + 1 hidden bit + 1)
            // If new_exponent is -10, shift mantissa right by 10 (11 bits + 1 hidden bit + 10)
            // The shift amount is 11 (mantissa bits) + 1 (hidden bit) - new_exponent
            // Or simply: 12 - new_exponent
            uint32_t denormalized_mantissa = (mantissa | 0x800000) >> (12 - new_exponent);

            if (denormalized_mantissa == 0) { // Becomes zero
                f16_bits = (sign << 15);
            } else { // Becomes denormalized float16
                f16_bits = (sign << 15) | (denormalized_mantissa & 0x03FF); // Set sign and denormalized mantissa
            }
        } else { // Normalized float16
            // Rounding: Simple round-to-nearest, ties-to-even is typically used.
            // This implementation uses round-to-nearest, ties-away-from-zero for simplicity.
            // To implement ties-to-even, you'd need to check the least significant bit
            // of the target mantissa and the bit just below the truncation point.

            // Shift mantissa to fit in 10 bits for float16
            uint32_t shifted_mantissa = mantissa >> 13;

            // Rounding: Check the 13th bit (the first bit to be truncated)
            uint32_t round_bit = (mantissa >> 12) & 0x01;
            // Check if there are any non-zero bits below the round bit
            uint32_t sticky_bits = mantissa & 0xFFF; // Bits 0 through 11

            if (round_bit == 1 && (sticky_bits != 0 || (shifted_mantissa & 0x01) == 1)) {
                 // Round up if the round bit is 1 and either there are non-zero sticky bits
                 // or the least significant bit of the shifted mantissa is 1 (ties to even)
                 // For simplicity, this rounds up if the round bit is 1 and any of the lower bits are non-zero (round half up)
                 // A more accurate ties-to-even would check the LSB of the *result* mantissa.
                 shifted_mantissa++;
            }


            // Check for mantissa overflow after rounding (can happen if mantissa was 0x7FFFFF and rounded up)
            if (shifted_mantissa > 0x3FF) {
                 new_exponent++; // Increment exponent
                 shifted_mantissa = 0; // Mantissa becomes zero
                 if (new_exponent >= 31) { // Check for exponent overflow after rounding
                     f16_bits = (sign << 15) | 0x7C00; // Infinity
                 }
            }

            f16_bits = (sign << 15) | (new_exponent << 10) | shifted_mantissa;
        }
    }

    return f16_bits;
}


float float16_to_float32(uint16_t value)
{
    uint32_t sign = (value & 0x8000) << 16;
    uint32_t exponent = ((value & 0x7C00) >> 10) + 127 - 15;
    uint32_t mantissa = (value & 0x03FF) << 13;
    uint32_t floatInt = sign | (exponent << 23) | mantissa;
    return *((float*)&floatInt);
}
} // namespace Float16_Emulation


struct ImageEdr
{
    ImageEdr(int width, int height)
    {
        Width = width;
        Height = height;
        ImageData.resize(Width * Height * 4);
        for (int i = 0; i < Width * Height * 4; i++)
        {
            ImageData[i] = Float16_Emulation::float32_to_float16(0.0f);
        }
    }

    // Buffer to store the image data, in format MTLPixelFormatRGBA16Float
    // i.e. RGBA 16 bits per channel, float
    // However, since C++ does not have a float16 type, we store the data as uint16_t
    std::vector<uint16_t> ImageData;
    int Width, Height;
};


void CreateFloatPattern(ImageEdr* imageEdr, float maxR, float maxG, float maxB)
{
    // TopLeft color will be (0, 0, 0)
    // TopRight color will be (maxR, 0, 0)
    // BottomLeft color will be (0, maxG, 0)
    // BottomRight color will be (0, 0, maxB)
    for (int y = 0; y < imageEdr->Height; y++)
    {
        float yf = (float)y / (float)imageEdr->Height;
        for (int x = 0; x < imageEdr->Width; x++)
        {
            float xf = (float)x / (float)imageEdr->Width;
            float r = xf * maxR;
            float g = yf * maxG;
            float b = (1.0f - xf) * maxB;
            int index = (y * imageEdr->Width + x) * 4;
            imageEdr->ImageData[index + 0] = Float16_Emulation::float32_to_float16(r);
            imageEdr->ImageData[index + 1] = Float16_Emulation::float32_to_float16(g);
            imageEdr->ImageData[index + 2] = Float16_Emulation::float32_to_float16(b);
            imageEdr->ImageData[index + 3] = Float16_Emulation::float32_to_float16(1.0f);
        }
    }
}


// this function using libavif doesnt work, it fails to convert YUV to RGB
// void LoadAvifImage(ImageEdr* imageEdr, const char* filePath)
// {
//     // Initialize AVIF decoder
//     avifDecoder* decoder = avifDecoderCreate();
//     avifResult result = avifDecoderSetIOFile(decoder, filePath);
//     if (result != AVIF_RESULT_OK) {
//         printf("Failed to open AVIF file: %s\n", avifResultToString(result));
//         avifDecoderDestroy(decoder);
//         return;
//     }

//     // Set strictness flags (optional, adjust as needed)
//     decoder->strictFlags = AVIF_STRICT_DISABLED;

//     // printf(filePath);

//     // Decode the AVIF image
//     result = avifDecoderParse(decoder);
//     if (result != AVIF_RESULT_OK) {
//         printf("Failed to decode AVIF image: %s\n", avifResultToString(result));
//         avifDecoderDestroy(decoder);
//         return;
//     }

//     printf("Decoded AVIF image: %ux%u\n", decoder->image->width, decoder->image->height);

//     avifImage* avifImg = decoder->image;

//     printf("AVIF Image Properties:\n");
//     printf("  Width: %u, Height: %u\n", avifImg->width, avifImg->height);
//     printf("  Depth: %u\n", avifImg->depth);
//     printf("  YUV Format: %d\n", avifImg->yuvFormat); // AVIF_PIXEL_FORMAT_... enum value
//     printf("  Color Primaries: %d\n", avifImg->colorPrimaries); // AVIF_COLOR_PRIMARIES_... enum value
//     printf("  Transfer Characteristics: %d\n", avifImg->transferCharacteristics); // AVIF_TRANSFER_CHARACTERISTICS_... enum value
//     printf("  Matrix Coefficients: %d\n", avifImg->matrixCoefficients); // AVIF_MATRIX_COEFFICIENTS_... enum value

//     // Print YUV format
//     printf("  YUV Format: %d (", avifImg->yuvFormat);
//     switch (avifImg->yuvFormat) {
//         case AVIF_PIXEL_FORMAT_YUV444:
//             printf("YUV444");
//             break;
//         case AVIF_PIXEL_FORMAT_YUV422:
//             printf("YUV422");
//             break;
//         case AVIF_PIXEL_FORMAT_YUV420:
//             printf("YUV420");
//             break;
//         case AVIF_PIXEL_FORMAT_YUV400:
//             printf("YUV400 (Monochrome)");
//             break;
//         default:
//             printf("Unknown");
//             break;
//     }
//     printf(")\n");


//     // 9-16-9 PQ gives YUV to RGB error. 1-13-9 also
//     // Convert YUV to RGB
//     avifRGBImage rgb;
//     avifRGBImageSetDefaults(&rgb, avifImg);
//     rgb.format = AVIF_RGB_FORMAT_RGBA; // Use RGBA format
//     rgb.depth = 16; // Use 16-bit depth for high precision
//     avifRGBImageAllocatePixels(&rgb);

//     result = avifImageYUVToRGB(avifImg, &rgb);
//     if (result != AVIF_RESULT_OK) {
//         printf("Failed to convert YUV to RGB: %s\n", avifResultToString(result));
//         avifRGBImageFreePixels(&rgb);
//         avifDecoderDestroy(decoder);
//         return;
//     }

//     // Resize ImageEdr to match AVIF dimensions
//     imageEdr->Width = avifImg->width;
//     imageEdr->Height = avifImg->height;
//     imageEdr->ImageData.resize(imageEdr->Width * imageEdr->Height * 4);

//     // Convert RGB data to float (0.0 to 1.0)
//     uint16_t* rgbData = (uint16_t*)rgb.pixels;
//     float maxValue = (1 << rgb.depth) - 1;
//     for (uint32_t y = 0; y < avifImg->height; y++) {
//         for (uint32_t x = 0; x < avifImg->width; x++) {
//             int index = (y * avifImg->width + x) * 4;

//             // Extract pixel values
//             uint16_t r = rgbData[index + 0];
//             uint16_t g = rgbData[index + 1];
//             uint16_t b = rgbData[index + 2];

//             // Normalize to 0.0 - 1.0 range
//             float rf = (float)r / maxValue;
//             float gf = (float)g / maxValue;
//             float bf = (float)b / maxValue;

//             // Store in ImageData as float16
//             imageEdr->ImageData[index + 0] = Float16_Emulation::float32_to_float16(rf);
//             imageEdr->ImageData[index + 1] = Float16_Emulation::float32_to_float16(gf);
//             imageEdr->ImageData[index + 2] = Float16_Emulation::float32_to_float16(bf);
//             imageEdr->ImageData[index + 3] = Float16_Emulation::float32_to_float16(1.0f); // Alpha channel
//         }
//     }

//     // Cleanup
//     avifRGBImageFreePixels(&rgb);
//     avifDecoderDestroy(decoder);
// }

// Function to convert PQ EOTF to linear light
float pqEotfToLinear(float pqValue) {
    // Constants defined in ITU-R BT.2100
    const float m1 = 0.1593017578125;  // 2610 / 16384
    const float m2 = 78.84375;         // 2523 / 32
    const float c1 = 0.8359375;        // 3424 / 4096
    const float c2 = 18.8515625;       // 2413 / 128
    const float c3 = 18.6875;          // 2392 / 128

    // Convert PQ value to linear light
    float linearValue = powf(fmaxf(powf(pqValue, 1.0f / m2) - c1, 0.0f) / (c2 - c3 * powf(pqValue, 1.0f / m2)), 1.0f / m1);

    // hacky  inverse gamma correction, shouldnt need this if working properly
    linearValue = powf(linearValue, 1.0f / 2.2f); // 
    return linearValue * 5.0f;
    

    // Scale linear light to 1.0 = 100 nits
    // return linearValue * 100.0f;
    
}

void LoadAvifImageApple(ImageEdr* imageEdr, const char* filePath)
{
    CFStringRef path = CFStringCreateWithCString(NULL, filePath, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false);
    CFRelease(path);

    if (!url) {
        std::cerr << "Failed to create URL from file path\n";
        return;
    }

    // Create CGImageSource for AVIF file
    CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
    CFRelease(url);
    if (!source) {
        std::cerr << "Failed to create CGImageSource from file\n";
        return;
    }

    

    // Create CGImage from source (first image)
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) {
        std::cerr << "Failed to create CGImage from source\n";
        return;
    }

    // size_t width = CGImageGetWidth(image);
    // size_t height = CGImageGetHeight(image);

    // downsample 8x
    size_t width = CGImageGetWidth(image)/8;
    size_t height = CGImageGetHeight(image)/8;

    // We will create a 16-bit per channel RGBA bitmap context
    size_t bytesPerPixel = 8; // 4 channels * 2 bytes (16-bit)
    size_t bytesPerRow = bytesPerPixel * width;
    size_t bufferSize = bytesPerRow * height;

    std::vector<uint16_t> pixelBuffer(bufferSize / 2); // uint16_t buffer

    // Create color space (Device RGB)
    // CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    // CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    // const CFStringRef name = kCGColorSpaceExtendedLinearSRGB;
    // const CFStringRef name = kCGColorSpaceExtendedLinearITUR_2020;
    // CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(name);

    // this will display pq encoded, grayish
    CGColorSpaceRef colorSpace = CGImageGetColorSpace(image);

    // print colorspace of layer
    if (colorSpace != nullptr) {
        CFStringRef colorSpaceName = CGColorSpaceCopyName(colorSpace);
        if (colorSpaceName != nullptr) {
            // Convert CFStringRef to C-string and print
            const char *colorSpaceCString = CFStringGetCStringPtr(colorSpaceName, kCFStringEncodingUTF8);
            if (colorSpaceCString != nullptr) {
                printf("Color Space: %s\n", colorSpaceCString);
            } else {
                // Fallback if CFStringGetCStringPtr returns nullptr
                char buffer[256];
                if (CFStringGetCString(colorSpaceName, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
                    printf("Color Space: %s\n", buffer);
                } else {
                    printf("Color Space: Unable to determine\n");
                }
            }
            CFRelease(colorSpaceName);
        } else {
            printf("Color Space: Unknown\n");
        }
    } else {
        printf("The image does not have a color space.\n");
    }

    // Bitmap info:
    // 16-bit per channel, RGBA, big endian, no alpha premultiplied
    CGBitmapInfo bitmapInfo =
        kCGImageAlphaPremultipliedLast | // RGBA
        kCGBitmapByteOrder16Host;         // 16-bit per component

    CGContextRef context = CGBitmapContextCreate(
        pixelBuffer.data(),
        width,
        height,
        16,             // bits per component
        bytesPerRow,
        colorSpace,
        bitmapInfo
    );

    CGColorSpaceRelease(colorSpace);

    if (!context) {
        std::cerr << "Failed to create bitmap context\n";
        CGImageRelease(image);
        return;
    }

    // Draw the image into the context (this converts it to 16-bit RGBA)
    CGRect rect = CGRectMake(0, 0, width, height);

    // this does color space conversion
    CGContextDrawImage(context, rect, image);

    CGImageRelease(image);
    CGContextRelease(context);

    // Copy pixels into imageEdr->ImageData as float16 normalized [0.0..1.0]
    imageEdr->Width = static_cast<uint32_t>(width);
    imageEdr->Height = static_cast<uint32_t>(height);
    imageEdr->ImageData.resize(imageEdr->Width * imageEdr->Height * 4);

    float maxValue = 65535.0f; // max for 16-bit unsigned

    for (uint32_t y = 0; y < imageEdr->Height; y++) {
        for (uint32_t x = 0; x < imageEdr->Width; x++) {
            size_t pixelIndex = (y * imageEdr->Width + x) * 4;
            size_t bufferIndex = pixelIndex;

            // Each channel is 16-bit unsigned integer
            uint16_t r = pixelBuffer[bufferIndex + 0];
            uint16_t g = pixelBuffer[bufferIndex + 1];
            uint16_t b = pixelBuffer[bufferIndex + 2];
            uint16_t a = pixelBuffer[bufferIndex + 3];

            // Normalize to 0.0 - 1.0 float and convert to float16
            // float rf = static_cast<float>(r) / maxValue;
            // float gf = static_cast<float>(g) / maxValue;
            // float bf = static_cast<float>(b) / maxValue;
            // float af = static_cast<float>(a) / maxValue;
            float rf = pqEotfToLinear(static_cast<float>(r) / maxValue);
            float gf = pqEotfToLinear(static_cast<float>(g) / maxValue);
            float bf = pqEotfToLinear(static_cast<float>(b) / maxValue);
            float af = static_cast<float>(a) / maxValue;


            imageEdr->ImageData[pixelIndex + 0] = Float16_Emulation::float32_to_float16(rf);
            imageEdr->ImageData[pixelIndex + 1] = Float16_Emulation::float32_to_float16(gf);
            imageEdr->ImageData[pixelIndex + 2] = Float16_Emulation::float32_to_float16(bf);
            imageEdr->ImageData[pixelIndex + 3] = Float16_Emulation::float32_to_float16(af);
        }
    }
}

#import <Foundation/Foundation.h>


struct AppState
{
    float maxR = 1.0f, maxG = 1.0f, maxB = 1.0f;

    ImageEdr imageEdr = ImageEdr(512, 512);
    HelloImGui::ImageMetal imageMetal;

    AppState()
    {
        Update();
    }

    void Update()
    {
        // CreateFloatPattern(&imageEdr, maxR, maxG, maxB);
        // LoadAvifImage(&imageEdr, "../Resources/assets/sample.avif");

        //debug path, run binary within .app folder using terminal
        // hello_edr.app/Contents/MacOS/hello_edr
        // LoadAvifImageApple(&imageEdr, "../Resources/assets/sample.avif");

        NSString *p = [[NSBundle mainBundle] pathForResource:@"sample" ofType:@"avif" inDirectory:@"assets"];
        if (p) LoadAvifImageApple(&imageEdr, [p UTF8String]);

        // LoadAvifImageApple(imageEdr, "Resources/assets/sample.avif");
        imageMetal.StoreTextureFloat16Rgba(imageEdr.Width, imageEdr.Height, imageEdr.ImageData.data());
    }


    ImTextureID TextureID()
    {
        return imageMetal.TextureID();
    }
};


void Gui(AppState& appState)
{

    ImGui::TextWrapped(
        "The image below is of format MTLPixelFormatRGBA16Float, i.e. RGBA 16 bits per channel, float\n"
        "If your screen support EDR(Extended Dynamic Range), you can experience with setting\n"
        "the maxR, maxG, maxB values to values > 1.0f\n");
    bool changed = false;
    changed |= ImGui::SliderFloat("maxR", &appState.maxR, 0.0f, 2.5f);
    changed |= ImGui::SliderFloat("maxG", &appState.maxG, 0.0f, 2.5f);
    changed |= ImGui::SliderFloat("maxB", &appState.maxB, 0.0f, 2.5f);

    if (changed)
        appState.Update();

    ImGui::Image(appState.TextureID(), ImVec2(appState.imageEdr.Width, appState.imageEdr.Height));
}


int main()
{
    HelloImGui::RunnerParams runnerParams;

    if (HelloImGui::hasEdrSupport())
    {
        runnerParams.rendererBackendOptions.requestFloatBuffer = true;
        printf("EDR support detected, enabling it.\n");
    }
    else
    {
        printf("EDR support not detected, exit.\n");
        return -1;
    }

    // AppState can be instantiated only after Metal is initialized, and must be destroyed before Metal is destroyed
    std::unique_ptr<AppState> appState;
    runnerParams.callbacks.EnqueuePostInit([&]() { appState = std::make_unique<AppState>(); });
    runnerParams.callbacks.EnqueueBeforeExit([&]() { appState.reset(); });

    runnerParams.callbacks.ShowGui= [&]() { Gui(*appState); };
    HelloImGui::Run(runnerParams);
    return 0;
}

#endif
