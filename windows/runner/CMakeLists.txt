cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "pdf_renderer.cpp"
  "utils.cpp"
  "webview_host.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# C++/WinRT needs C++20 (<coroutine>) with current MSVC; the rest of the
# runner stays on the standard settings.
set_source_files_properties("pdf_renderer.cpp" PROPERTIES COMPILE_OPTIONS "/std:c++20")

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# C++/WinRT (Windows.Data.Pdf renders PDF pages; ships with Windows).
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")

# Microsoft Edge WebView2 SDK (headers + static loader) for Safari's
# Windows engine, fetched once from Microsoft's official NuGet package at
# configure time (no Flutter plugin, so no symlinks / Developer Mode).
# The WebView2 Runtime itself ships with Windows 10/11 and Edge.
set(WEBVIEW2_VERSION "1.0.2849.39")
set(WEBVIEW2_DIR "${CMAKE_BINARY_DIR}/webview2-${WEBVIEW2_VERSION}")
if(NOT EXISTS "${WEBVIEW2_DIR}/build/native/include/WebView2.h")
  file(DOWNLOAD
    "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/${WEBVIEW2_VERSION}"
    "${CMAKE_BINARY_DIR}/webview2-${WEBVIEW2_VERSION}.nupkg"
    TLS_VERIFY ON
    STATUS WEBVIEW2_STATUS)
  list(GET WEBVIEW2_STATUS 0 WEBVIEW2_CODE)
  if(NOT WEBVIEW2_CODE EQUAL 0)
    message(FATAL_ERROR "Could not download the WebView2 SDK: ${WEBVIEW2_STATUS}")
  endif()
  file(ARCHIVE_EXTRACT
    INPUT "${CMAKE_BINARY_DIR}/webview2-${WEBVIEW2_VERSION}.nupkg"
    DESTINATION "${WEBVIEW2_DIR}")
endif()
target_include_directories(${BINARY_NAME} PRIVATE "${WEBVIEW2_DIR}/build/native/include")
target_link_libraries(${BINARY_NAME} PRIVATE
  "${WEBVIEW2_DIR}/build/native/x64/WebView2LoaderStatic.lib"
  "version.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
