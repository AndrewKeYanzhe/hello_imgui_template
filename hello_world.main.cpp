#include "hello_imgui/hello_imgui.h"

int main(int , char *[])
{
#ifdef ASSETS_LOCATION
    HelloImGui::SetAssetsFolder(ASSETS_LOCATION);
#endif
    auto guiFunction = []() {
        ImGui::Text("Hello, ");                    // Display a simple label
        HelloImGui::ImageFromAsset("world.jpg");   // Display a static image
        if (ImGui::Button("Bye!"))                 // Display a button
            // and immediately handle its action if it is clicked!
            HelloImGui::GetRunnerParams()->appShallExit = true;
     };
    HelloImGui::Run(guiFunction, "Hello, globe", true);
    return 0;
}
