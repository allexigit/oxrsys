add_executable(oxrsys_test_app
    main.cpp
)

target_include_directories(oxrsys_test_app PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../runtime/include
)

target_link_libraries(oxrsys_test_app PRIVATE
    openxr_loader
)

target_compile_features(oxrsys_test_app PRIVATE cxx_std_20)

target_compile_definitions(oxrsys_test_app PRIVATE
    XR_USE_GRAPHICS_API_METAL
)

if(APPLE)
    target_link_libraries(oxrsys_test_app PRIVATE
        "-framework Metal"
        "-framework Foundation"
        "-framework CoreGraphics"
    )

    set_target_properties(oxrsys_test_app PROPERTIES
        XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET "13.0"
    )
endif()
