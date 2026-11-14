cmake_minimum_required(VERSION 3.24)

# Predown: a Preview-style markdown reader for macOS, plus a Quick Look extension.
#
#   cmake -G Xcode -B build [-DPREDOWN_TEAM_ID=XXXXXXXXXX]
#   open build/Predown.xcodeproj
#
# The Quick Look extension has to be an embedded .appex, which only the Xcode
# generator can produce, so other generators are rejected.

project(Predown VERSION 1.0.0 LANGUAGES C Swift)

if(NOT CMAKE_GENERATOR STREQUAL "Xcode")
  message(FATAL_ERROR "Predown must be generated with the Xcode generator: cmake -G Xcode -B build")
endif()

set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")
set(CMAKE_Swift_LANGUAGE_VERSION 5)
set(CMAKE_XCODE_GENERATE_SCHEME ON)

set(PREDOWN_BUNDLE_ID "com.therohans.predown" CACHE STRING "App bundle identifier")
# Your Apple Developer Team ID. Pass it once (-DPREDOWN_TEAM_ID=...) or export
# PREDOWN_TEAM_ID in your shell; it's remembered in the build cache after that.
set(PREDOWN_TEAM_ID "$ENV{PREDOWN_TEAM_ID}" CACHE STRING "Apple Developer Team ID")
if(NOT PREDOWN_TEAM_ID)
  message(WARNING "PREDOWN_TEAM_ID is not set. Pick a team for both targets in Xcode "
                  "(Signing & Capabilities) before archiving, or re-run with -DPREDOWN_TEAM_ID=XXXXXXXXXX.")
endif()
set(PREDOWN_BUILD_NUMBER "1" CACHE STRING "CFBundleVersion")

# ---------------------------------------------------------------------------
# md4c (vendored) + the tiny C shim Swift calls into
# ---------------------------------------------------------------------------
add_library(md4c STATIC
  third_party/md4c/md4c.c
  third_party/md4c/md4c-html.c
  third_party/md4c/entity.c
  Shared/predown_md.c
)
target_include_directories(md4c PUBLIC third_party/md4c Shared)
set_target_properties(md4c PROPERTIES
  XCODE_ATTRIBUTE_SKIP_INSTALL YES
  XCODE_ATTRIBUTE_APPLICATION_EXTENSION_API_ONLY YES
  XCODE_ATTRIBUTE_GCC_WARN_INHIBIT_ALL_WARNINGS YES
)

set(SHARED_SOURCES
  Shared/Markdown.swift
  Shared/Stylesheet.swift
  Shared/Paginator.swift
)

# Settings common to the app and the extension.
function(predown_common target)
  target_link_libraries(${target} PRIVATE md4c)
  set_target_properties(${target} PROPERTIES
    XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/Shared/Predown-Bridging-Header.h"
    XCODE_ATTRIBUTE_MARKETING_VERSION "${PROJECT_VERSION}"
    XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION "${PREDOWN_BUILD_NUMBER}"
    XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET "${CMAKE_OSX_DEPLOYMENT_TARGET}"
    XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME YES
    XCODE_ATTRIBUTE_GENERATE_INFOPLIST_FILE NO
    XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT[variant=Release] "dwarf-with-dsym"
    XCODE_ATTRIBUTE_SWIFT_OPTIMIZATION_LEVEL[variant=Debug] "-Onone"
    XCODE_ATTRIBUTE_SWIFT_OPTIMIZATION_LEVEL[variant=Release] "-O"
    # Normal automatic signing. Never bake in "-" (Sign to Run Locally): choosing
    # a team in Xcode doesn't clear it, and the archive ends up with no team.
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE Automatic
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "Apple Development"
  )
  if(PREDOWN_TEAM_ID)
    set_target_properties(${target} PROPERTIES XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${PREDOWN_TEAM_ID}")
  endif()
endfunction()

# ---------------------------------------------------------------------------
# Quick Look preview extension (.appex)
# ---------------------------------------------------------------------------
add_executable(PredownQuickLook MACOSX_BUNDLE
  QuickLook/PreviewProvider.swift
  ${SHARED_SOURCES}
)
predown_common(PredownQuickLook)
target_link_libraries(PredownQuickLook PRIVATE "-framework QuickLookUI" "-framework UniformTypeIdentifiers")
set_target_properties(PredownQuickLook PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/QuickLook/Info.plist"
  BUNDLE_EXTENSION appex
  XCODE_PRODUCT_TYPE "com.apple.product-type.app-extension"
  XCODE_EXPLICIT_FILE_TYPE "wrapper.app-extension"
  XCODE_ATTRIBUTE_WRAPPER_EXTENSION appex
  XCODE_ATTRIBUTE_PRODUCT_NAME "PredownQuickLook"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${PREDOWN_BUNDLE_ID}.quicklook"
  XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/QuickLook/QuickLook.entitlements"
  XCODE_ATTRIBUTE_ENABLE_APP_SANDBOX YES
  XCODE_ATTRIBUTE_APPLICATION_EXTENSION_API_ONLY YES
  XCODE_ATTRIBUTE_SKIP_INSTALL YES
  XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/../Frameworks @executable_path/../../../../Frameworks"
)

# ---------------------------------------------------------------------------
# The app
# ---------------------------------------------------------------------------
add_executable(Predown MACOSX_BUNDLE
  App/PredownApp.swift
  App/ContentView.swift
  App/DocumentModel.swift
  App/MarkdownFile.swift
  App/PagedRenderer.swift
  App/FileWatcher.swift
  App/Assets.xcassets
  ${SHARED_SOURCES}
)
predown_common(Predown)
target_link_libraries(Predown PRIVATE
  "-framework AppKit" "-framework SwiftUI" "-framework PDFKit"
  "-framework WebKit" "-framework UniformTypeIdentifiers")
add_dependencies(Predown PredownQuickLook)
set_target_properties(Predown PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/App/Info.plist"
  XCODE_ATTRIBUTE_PRODUCT_NAME "Predown"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${PREDOWN_BUNDLE_ID}"
  XCODE_ATTRIBUTE_INSTALL_PATH "/Applications"
  XCODE_ATTRIBUTE_SKIP_INSTALL NO
  XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/../Frameworks"
  RESOURCE App/Assets.xcassets
  XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME AppIcon
  XCODE_ATTRIBUTE_COMBINE_HIDPI_IMAGES YES
  XCODE_EMBED_APP_EXTENSIONS PredownQuickLook
  XCODE_EMBED_APP_EXTENSIONS_CODE_SIGN_ON_COPY ON
  XCODE_EMBED_APP_EXTENSIONS_REMOVE_HEADERS_ON_COPY ON
)
