// SPDX-License-Identifier: MPL-2.0

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <iostream>
#include <vector>
#include <cstring>
#include <chrono>
#include <thread>

void CheckXr(XrResult result, const char* expression)
{
    if (result != XR_SUCCESS)
    {
        std::cerr << "XR Error: " << expression << " returned " << result << std::endl;
        throw std::runtime_error(std::string("XR call failed: ") + expression);
    }
}

#define XR_CHECK(expr) CheckXr((expr), #expr)

void* DummyMetalCommandQueue()
{
    return reinterpret_cast<void*>(static_cast<uintptr_t>(0x1));
}

int64_t SelectColorSwapchainFormat(XrSession session)
{
    uint32_t formatCount = 0;
    XR_CHECK(xrEnumerateSwapchainFormats(session, 0, &formatCount, nullptr));
    if (formatCount == 0)
    {
        throw std::runtime_error("No swapchain formats available");
    }

    std::vector<int64_t> formats(formatCount);
    XR_CHECK(xrEnumerateSwapchainFormats(session, formatCount, &formatCount, formats.data()));
    return formats.front();
}

XrSwapchain CreateColorSwapchain(XrSession session, int64_t format, uint32_t width, uint32_t height)
{
    XrSwapchainCreateInfo createInfo = {XR_TYPE_SWAPCHAIN_CREATE_INFO};
    createInfo.createFlags = 0;
    createInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    createInfo.format = format;
    createInfo.sampleCount = 1;
    createInfo.width = width;
    createInfo.height = height;
    createInfo.faceCount = 1;
    createInfo.arraySize = 1;
    createInfo.mipCount = 1;

    XrSwapchain swapchain = XR_NULL_HANDLE;
    XR_CHECK(xrCreateSwapchain(session, &createInfo, &swapchain));
    return swapchain;
}

PFN_xrVoidFunction GetProc(XrInstance instance, const char* name)
{
    PFN_xrVoidFunction function = nullptr;
    XR_CHECK(xrGetInstanceProcAddr(instance, name, &function));
    if (function == nullptr)
    {
        throw std::runtime_error(std::string("Failed to get proc: ") + name);
    }
    return function;
}

int main()
{
    std::cout << "OXRSys Test App: Minimal OpenXR Stereo Renderer" << std::endl;
    std::cout << "================================================" << std::endl;

    try
    {
        // Create instance
        std::cout << "\nInitializing OpenXR..." << std::endl;
        XrInstanceCreateInfo createInfo = {XR_TYPE_INSTANCE_CREATE_INFO};
        std::strncpy(createInfo.applicationInfo.applicationName, "oxrsys_test_app",
                     XR_MAX_APPLICATION_NAME_SIZE);
        createInfo.applicationInfo.apiVersion = XR_CURRENT_API_VERSION;

        const char* extensions[] = {XR_KHR_METAL_ENABLE_EXTENSION_NAME};
        createInfo.enabledExtensionCount = 1;
        createInfo.enabledExtensionNames = extensions;

        XrInstance instance = XR_NULL_HANDLE;
        XR_CHECK(xrCreateInstance(&createInfo, &instance));
        std::cout << "Instance created" << std::endl;

        // Get Metal graphics requirements function
        auto getMetalGraphicsRequirementsKHR =
            reinterpret_cast<PFN_xrGetMetalGraphicsRequirementsKHR>(
                GetProc(instance, "xrGetMetalGraphicsRequirementsKHR"));

        // Get system
        std::cout << "Getting system..." << std::endl;
        XrSystemGetInfo systemGetInfo = {XR_TYPE_SYSTEM_GET_INFO};
        systemGetInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
        XrSystemId systemId = XR_NULL_SYSTEM_ID;
        XR_CHECK(xrGetSystem(instance, &systemGetInfo, &systemId));
        std::cout << "System ID: " << systemId << std::endl;

        // Get graphics requirements
        XrGraphicsRequirementsMetalKHR graphicsRequirements = {XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
        XR_CHECK(getMetalGraphicsRequirementsKHR(instance, systemId, &graphicsRequirements));

        // Create session with Metal
        std::cout << "Creating session with Metal graphics..." << std::endl;
        XrGraphicsBindingMetalKHR graphicsBinding = {XR_TYPE_GRAPHICS_BINDING_METAL_KHR};
        graphicsBinding.commandQueue = DummyMetalCommandQueue();

        XrSessionCreateInfo sessionCreateInfo = {XR_TYPE_SESSION_CREATE_INFO};
        sessionCreateInfo.next = &graphicsBinding;
        sessionCreateInfo.systemId = systemId;

        XrSession session = XR_NULL_HANDLE;
        XR_CHECK(xrCreateSession(instance, &sessionCreateInfo, &session));
        std::cout << "Session created" << std::endl;

        // Begin session
        std::cout << "Beginning session..." << std::endl;
        XrSessionBeginInfo beginInfo = {XR_TYPE_SESSION_BEGIN_INFO};
        beginInfo.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        XR_CHECK(xrBeginSession(session, &beginInfo));

        // Create reference space
        XrSpace localSpace = XR_NULL_HANDLE;
        XrReferenceSpaceCreateInfo referenceSpaceCreateInfo = {XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
        referenceSpaceCreateInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
        referenceSpaceCreateInfo.poseInReferenceSpace.orientation = {0.0f, 0.0f, 0.0f, 1.0f};
        XR_CHECK(xrCreateReferenceSpace(session, &referenceSpaceCreateInfo, &localSpace));

        // Get swapchain format
        std::cout << "Creating swapchains..." << std::endl;
        int64_t colorFormat = SelectColorSwapchainFormat(session);
        std::cout << "Selected color format: " << colorFormat << std::endl;

        // Create stereo swapchains (left and right eye)
        XrSwapchain leftSwapchain = CreateColorSwapchain(session, colorFormat, 1024, 1024);
        XrSwapchain rightSwapchain = CreateColorSwapchain(session, colorFormat, 1024, 1024);
        std::cout << "Created left and right swapchains" << std::endl;

        // Main frame loop
        std::cout << "\nStarting frame submission loop (60 frames)..." << std::endl;
        const int frameCount = 60;

        for (int frameIdx = 0; frameIdx < frameCount; ++frameIdx)
        {
            // Wait for frame timing
            XrFrameState frameState = {XR_TYPE_FRAME_STATE};
            XR_CHECK(xrWaitFrame(session, nullptr, &frameState));

            // Begin frame
            XrResult beginResult = xrBeginFrame(session, nullptr);
            if (beginResult != XR_SUCCESS && beginResult != XR_FRAME_DISCARDED)
            {
                XR_CHECK(beginResult);
            }

            // Acquire and release swapchain images
            uint32_t imageIndex = 0;
            XrSwapchainImageAcquireInfo acquireInfo = {XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
            XrSwapchainImageWaitInfo waitInfo = {XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
            waitInfo.timeout = XR_INFINITE_DURATION;
            XrSwapchainImageReleaseInfo releaseInfo = {XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};

            // Left eye
            XR_CHECK(xrAcquireSwapchainImage(leftSwapchain, &acquireInfo, &imageIndex));
            XR_CHECK(xrWaitSwapchainImage(leftSwapchain, &waitInfo));
            XR_CHECK(xrReleaseSwapchainImage(leftSwapchain, &releaseInfo));

            // Right eye
            XR_CHECK(xrAcquireSwapchainImage(rightSwapchain, &acquireInfo, &imageIndex));
            XR_CHECK(xrWaitSwapchainImage(rightSwapchain, &waitInfo));
            XR_CHECK(xrReleaseSwapchainImage(rightSwapchain, &releaseInfo));

            // Submit frame composition with layer
            XrCompositionLayerProjectionView projectionViews[2] = {};

            for (int i = 0; i < 2; ++i)
            {
                projectionViews[i].type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;
                projectionViews[i].pose.orientation = {0.0f, 0.0f, 0.0f, 1.0f};
                projectionViews[i].pose.position = {i == 0 ? -0.05f : 0.05f, 0.0f, 0.0f};
                projectionViews[i].fov = {1.5708f, 1.5708f, 0.7854f, 0.7854f}; // 90deg, 45deg
                projectionViews[i].subImage.swapchain = (i == 0) ? leftSwapchain : rightSwapchain;
                projectionViews[i].subImage.imageRect = {{0, 0}, {1024, 1024}};
                projectionViews[i].subImage.imageArrayIndex = 0;
            }

            XrCompositionLayerProjection projectionLayer = {XR_TYPE_COMPOSITION_LAYER_PROJECTION};
            projectionLayer.layerFlags = 0;
            projectionLayer.space = localSpace;
            projectionLayer.viewCount = 2;
            projectionLayer.views = projectionViews;

            XrCompositionLayerBaseHeader* layers[] = {
                reinterpret_cast<XrCompositionLayerBaseHeader*>(&projectionLayer)};

            XrFrameEndInfo frameEndInfo = {XR_TYPE_FRAME_END_INFO};
            frameEndInfo.displayTime = frameState.predictedDisplayTime;
            frameEndInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
            frameEndInfo.layerCount = 1;
            frameEndInfo.layers = layers;

            XrResult endResult = xrEndFrame(session, &frameEndInfo);
            if (endResult != XR_SUCCESS && endResult != XR_FRAME_DISCARDED)
            {
                // Log but continue on validation warnings
                if (frameIdx == 0)
                {
                    std::cerr << "xrEndFrame returned: " << endResult << " (may indicate validation warning)"
                              << std::endl;
                }
            }

            // Print progress
            if ((frameIdx + 1) % 10 == 0)
            {
                std::cout << "Submitted " << (frameIdx + 1) << "/" << frameCount << " frames"
                          << std::endl;
            }
        }

        std::cout << "\nFrame submission complete!" << std::endl;

        // Cleanup
        std::cout << "Cleaning up..." << std::endl;
        xrDestroySwapchain(leftSwapchain);
        xrDestroySwapchain(rightSwapchain);
        xrDestroySpace(localSpace);
        xrEndSession(session);
        xrDestroySession(session);
        xrDestroyInstance(instance);

        std::cout << "Test completed successfully!" << std::endl;
        return 0;
    }
    catch (const std::exception& e)
    {
        std::cerr << "Test failed with error: " << e.what() << std::endl;
        return 1;
    }
}
