# OXRSys Minimal Test App

A minimal C++ OpenXR application that connects to the OXRSys runtime and submits stereo frames for end-to-end testing.

## What It Does

- Initializes OpenXR instance/session with Metal graphics binding
- Creates stereo swapchains for left and right eyes
- Submits 60 frames through the complete OpenXR frame loop
- Uses dummy Metal command queue (frame submission validation only)
- Demonstrates: `xrWaitFrame` → `xrBeginFrame` → acquire/wait/release swapchain → composition layer → `xrEndFrame`

## Building

Built as part of the main build (macOS only):

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build build --target oxrsys_test_app
```

Output: `build/tests/test-app/oxrsys_test_app`

## Testing Workflow

**Step 1: Build runtime and test app**

```bash
cd /Users/alexi/Documents/Coding/oxrsys
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build build
```

**Step 2: Run test app (simplest case)**

```bash
export XR_RUNTIME_JSON=$(pwd)/build/runtime/oxrsys-runtime.json
./build/tests/test-app/oxrsys_test_app
```

✅ **Expected output:**

```
OXRSys Test App: Minimal OpenXR Stereo Renderer
================================================

Initializing OpenXR...
Instance created
Getting system...
System ID: 1
Creating session with Metal graphics...
Session created
Beginning session...
Creating swapchains...
Selected color format: 81
Created left and right swapchains

Starting frame submission loop (60 frames)...
Submitted 10/60 frames
Submitted 20/60 frames
Submitted 30/60 frames
Submitted 40/60 frames
Submitted 50/60 frames
Submitted 60/60 frames
Frame submission complete!
Cleaning up...
Test completed successfully!
```

**Step 3: Test with simulator (visual feedback)**

In separate terminals:

```bash
# Terminal 1: test app with runtime
export XR_RUNTIME_JSON=/Users/alexi/Documents/Coding/oxrsys/build/runtime/oxrsys-runtime.json
/Users/alexi/Documents/Coding/oxrsys/build/tests/test-app/oxrsys_test_app

# Terminal 2: simulator (Qt, shows video stream from runtime)
export XR_RUNTIME_JSON=/Users/alexi/Documents/Coding/oxrsys/build/runtime/oxrsys-runtime.json
cmake -B build-qt -G Ninja -DCMAKE_BUILD_TYPE=Debug -DOXRSYS_BUILD_QT_FRONTENDS=ON
cmake --build build-qt
./build-qt/clients/Qt/oxrsys-simulator/oxrsys-simulator
```

Simulator will show "Waiting for video" → then display encoded stereo stream from the runtime.

## What Gets Tested

✅ OpenXR loader integration  
✅ Instance and system creation  
✅ Session with Metal graphics binding  
✅ Swapchain creation and format enumeration  
✅ Frame loop semantics (WaitFrame/BeginFrame/EndFrame)  
✅ Swapchain image acquire/wait/release  
✅ Composition layer submission  
✅ Runtime streaming pipeline  

❌ Actual Metal rendering (uses dummy buffer)  
❌ Input/tracking (test app doesn't read pose)  
❌ Hand tracking (test app is stateless)  

## Code Structure

- `main.cpp`: Single file, ~300 lines
  - `CheckXr()`: simple error wrapper
  - `DummyMetalCommandQueue()`: sufficient for testing
  - `SelectColorSwapchainFormat()`: enumerates runtime-supported formats
  - `CreateColorSwapchain()`: creates stereo swapchains
  - `main()`: full OpenXR lifecycle

## Notes

- Frame size: 1024×1024 per eye
- Frame count: 60 (edit `main.cpp` to change)
- Composition layer: uses `XR_ENVIRONMENT_BLEND_MODE_OPAQUE`
- No actual rendering: just acquire/release swapchain images
- Streaming is automatic: runtime encodes and sends to connected clients

## Architecture Diagram

```
Test App (oxrsys_test_app)
    ↓
OpenXR Loader
    ↓
OXRSys Runtime
    ├── Metal Path (local debug rendering)
    ├── Streaming Encoder (H.265)
    └── UDP Server (for simulator/headsets)
         ↓
    Qt Simulator (displays video stream)
    or
    Quest/Pico headset (via Android VR client)
```

## Next Steps

1. **Verify end-to-end**: Run test app + simulator side-by-side
2. **Add real rendering**: Replace acquire/release with Metal drawing
3. **Test with Unity/UE**: Use actual game engines with OpenXR plugin
4. **Hardware testing**: Connect Meta Quest 3 via USB
