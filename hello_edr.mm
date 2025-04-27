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

#ifdef HELLOIMGUI_HAS_METAL
#include "hello_imgui/hello_imgui.h"
#include "hello_imgui/internal/image_metal.h"
#include <memory>

#include <cstdint>

// Use extern "C" because avif.h is C code
extern "C" {
#include "avif/avif.h"
}

// Then you can start decoding/loading AVIF images


namespace Float16_Emulation
{
uint16_t float32_to_float16(float value)
{
    uint32_t floatInt = *((uint32_t*)&value);
    uint16_t sign = (floatInt & 0x80000000) >> 16;
    uint16_t exponent = ((floatInt & 0x7F800000) >> 23) - 127 + 15;
    uint16_t mantissa = (floatInt & 0x007FFFFF) >> 13;
    return sign | (exponent << 10) | mantissa;
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

void LoadAvifImage(ImageEdr* imageEdr, const char* filePath)
{
    // Initialize AVIF decoder
    avifDecoder* decoder = avifDecoderCreate();
    avifResult result = avifDecoderSetIOFile(decoder, filePath);
    if (result != AVIF_RESULT_OK) {
        printf("Failed to open AVIF file: %s\n", avifResultToString(result));
        avifDecoderDestroy(decoder);
        return;
    }

    // Set strictness flags (optional, adjust as needed)
    decoder->strictFlags = AVIF_STRICT_DISABLED;

    // printf(filePath);

    // Decode the AVIF image
    result = avifDecoderParse(decoder);
    if (result != AVIF_RESULT_OK) {
        printf("Failed to decode AVIF image: %s\n", avifResultToString(result));
        avifDecoderDestroy(decoder);
        return;
    }

    printf("Decoded AVIF image: %ux%u\n", decoder->image->width, decoder->image->height);

    avifImage* avifImg = decoder->image;

    // Convert YUV to RGB
    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, avifImg);
    rgb.format = AVIF_RGB_FORMAT_RGBA; // Use RGBA format
    rgb.depth = 16; // Use 16-bit depth for high precision
    avifRGBImageAllocatePixels(&rgb);

    result = avifImageYUVToRGB(avifImg, &rgb);
    if (result != AVIF_RESULT_OK) {
        printf("Failed to convert YUV to RGB: %s\n", avifResultToString(result));
        avifRGBImageFreePixels(&rgb);
        avifDecoderDestroy(decoder);
        return;
    }

    // Resize ImageEdr to match AVIF dimensions
    imageEdr->Width = avifImg->width;
    imageEdr->Height = avifImg->height;
    imageEdr->ImageData.resize(imageEdr->Width * imageEdr->Height * 4);

    // Convert RGB data to float (0.0 to 1.0)
    uint16_t* rgbData = (uint16_t*)rgb.pixels;
    float maxValue = (1 << rgb.depth) - 1;
    for (uint32_t y = 0; y < avifImg->height; y++) {
        for (uint32_t x = 0; x < avifImg->width; x++) {
            int index = (y * avifImg->width + x) * 4;

            // Extract pixel values
            uint16_t r = rgbData[index + 0];
            uint16_t g = rgbData[index + 1];
            uint16_t b = rgbData[index + 2];

            // Normalize to 0.0 - 1.0 range
            float rf = (float)r / maxValue;
            float gf = (float)g / maxValue;
            float bf = (float)b / maxValue;

            // Store in ImageData as float16
            imageEdr->ImageData[index + 0] = Float16_Emulation::float32_to_float16(rf);
            imageEdr->ImageData[index + 1] = Float16_Emulation::float32_to_float16(gf);
            imageEdr->ImageData[index + 2] = Float16_Emulation::float32_to_float16(bf);
            imageEdr->ImageData[index + 3] = Float16_Emulation::float32_to_float16(1.0f); // Alpha channel
        }
    }

    // Cleanup
    avifRGBImageFreePixels(&rgb);
    avifDecoderDestroy(decoder);
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
        LoadAvifImage(&imageEdr, "../Resources/assets/sample.avif");
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
