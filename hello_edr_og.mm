// Demo of EDR (Extended Dynamic Range) support in Hello ImGui.

#ifdef HELLOIMGUI_HAS_METAL
#include "hello_imgui/hello_imgui.h"
#include "hello_imgui/internal/image_metal.h"
#include <memory>

#include <cstdint>

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

void CreateGrayscaleVerticalBars(ImageEdr* imageEdr, float maxR, float maxG, float maxB)
{
    
    int numBars = 9; // Number of vertical bars


    // Print grayscale values for each bar once
    std::cout << "Grayscale values for " << numBars << " bars:\n";
    for (int barIndex = 0; barIndex < numBars; barIndex++)
    {
        float gray = (float)barIndex / (float)(numBars - 1);
        std::cout << "Bar " << barIndex << ": (" << gray << ", " << gray << ", " << gray << ")\n";
    }

    for (int y = 0; y < imageEdr->Height; y++)
    {
        for (int x = 0; x < imageEdr->Width; x++)
        {
            // Calculate which bar this pixel belongs to
            int barIndex = (x * numBars) / imageEdr->Width; // integer from 0 to numBars-1

            // Map bar index to grayscale value (0 to 1)
            float gray = (float)barIndex / (float)(numBars - 1);

            int index = (y * imageEdr->Width + x) * 4;
            imageEdr->ImageData[index + 0] = Float16_Emulation::float32_to_float16(gray); // R
            imageEdr->ImageData[index + 1] = Float16_Emulation::float32_to_float16(gray); // G
            imageEdr->ImageData[index + 2] = Float16_Emulation::float32_to_float16(gray); // B
            imageEdr->ImageData[index + 3] = Float16_Emulation::float32_to_float16(1.0f); // Alpha
        }
    }
}


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
        CreateGrayscaleVerticalBars(&imageEdr, maxR, maxG, maxB);
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
