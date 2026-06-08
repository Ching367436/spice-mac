// swift-tools-version:5.9
import PackageDescription

// SpiceMac — a native macOS SPICE client that opens Proxmox VE `.vv` consoles by
// wrapping (a forked) CocoaSpice.
//
// BUILD REQUIREMENTS:
//  * Full Xcode (not just Command Line Tools): CocoaSpice's renderer compiles a
//    .metal shader, which needs the Metal toolchain that only ships with Xcode.
//  * The native SPICE frameworks must be staged under ./Frameworks first:
//        ./scripts/fetch-sysroot.sh
//  * Build & bundle into SpiceMac.app with:  ./scripts/build-app.sh
//
// The pure-Swift libraries (VVConfig, SpiceInputMap) build and test on their own
// with just the toolchain — see their packages under Packages/.

// The native SPICE stack is linked as @rpath-relocatable *.framework bundles from
// the UTM sysroot (staged into ./Frameworks by scripts/fetch-sysroot.sh). UTM's
// lib/*.dylib are NOT relocatable (absolute CI install names), so we link the
// frameworks and embed them with @rpath. The version suffixes below track the
// sysroot's framework versions — update them if you fetch a different sysroot.
// Transitive deps (intl, pixman, openssl, opus, json-glib, …) load at runtime via
// @rpath from the embedded frameworks, so only the directly-referenced ones are
// listed here.
let spiceFrameworks = [
    "glib-2.0.0", "gobject-2.0.0", "gio-2.0.0", "gmodule-2.0.0",
    "spice-client-glib-2.0.8",
    "gstreamer-1.0.0", "gstbase-1.0.0", "gstapp-1.0.0", "gstaudio-1.0.0", "gstvideo-1.0.0",
    "gstpbutils-1.0.0",
    "usb-1.0.0",
    "jpeg.62",
    "intl.8",
]
// CocoaSpice's gst_ios_init.m statically registers these GStreamer plugins, so
// their static archives (staged into Frameworks/gstreamer-1.0/) must be linked.
let gstPlugins = [
    "adder", "app", "audioconvert", "audiorate", "audioresample", "audiotestsrc",
    "autodetect", "coreelements", "gio", "jpeg", "osxaudio", "playback",
    "typefindfunctions", "videoconvert", "videofilter", "videorate", "videoscale",
    "videotestsrc", "volume",
]
// macOS system frameworks the plugins/codecs need (osxaudio → CoreAudio/AudioToolbox/…).
let systemFrameworks = ["CoreAudio", "AudioToolbox", "AudioUnit", "CoreMedia", "CoreVideo", "VideoToolbox"]

// Build the linker flags imperatively — a single large `+`/flatMap expression
// makes the manifest type-checker time out.
var spiceLinkFlags: [String] = ["-F", "Frameworks"]
for framework in spiceFrameworks { spiceLinkFlags += ["-framework", framework] }
for framework in systemFrameworks { spiceLinkFlags += ["-framework", framework] }
for plugin in gstPlugins { spiceLinkFlags += ["-Xlinker", "Frameworks/gstreamer-1.0/libgst\(plugin).a"] }
spiceLinkFlags += ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]
spiceLinkFlags += ["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"]

let nativeSpiceLinkerSettings: [LinkerSetting] = [.unsafeFlags(spiceLinkFlags)]

let package = Package(
    name: "SpiceMac",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "SpiceMac", targets: ["SpiceMac"]),
    ],
    dependencies: [
        .package(path: "Packages/VVConfig"),
        .package(path: "Packages/SpiceInputMap"),
        .package(path: "ThirdParty/CocoaSpice"),
    ],
    targets: [
        // Swift glue: connection lifecycle, CSConnectionDelegate, NSEvent→CSInput,
        // pasteboard bridge. Depends on the (forked) CocoaSpice ObjC layer.
        .target(
            name: "SpiceController",
            dependencies: [
                .product(name: "VVConfig", package: "VVConfig"),
                .product(name: "SpiceInputMap", package: "SpiceInputMap"),
                .product(name: "CocoaSpice", package: "CocoaSpice"),
                .product(name: "CocoaSpiceRenderer", package: "CocoaSpice"),
            ],
            path: "Packages/SpiceController/Sources/SpiceController"
        ),
        // The AppKit/SwiftUI application.
        .executableTarget(
            name: "SpiceMac",
            dependencies: [
                "SpiceController",
                .product(name: "VVConfig", package: "VVConfig"),
                .product(name: "SpiceInputMap", package: "SpiceInputMap"),
                .product(name: "CocoaSpice", package: "CocoaSpice"),
                .product(name: "CocoaSpiceRenderer", package: "CocoaSpice"),
            ],
            path: "Sources/SpiceMac",
            linkerSettings: nativeSpiceLinkerSettings
        ),
    ]
)
