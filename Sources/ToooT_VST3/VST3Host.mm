//
//  VST3Host.mm
//  ToooT_VST3
//
//  Obj-C++ host for Steinberg VST3 plugins. Direct SDK integration — no JUCE.
//
//  Build modes:
//    • TOOOT_VST3_SDK_AVAILABLE=1 — SDK headers on search path
//      (Package.swift: cxxSettings: [.headerSearchPath("VST3_SDK")]).
//      Real VST3::Hosting path compiled in.
//    • Default — SDK not vendored. All load calls fail with a clear error;
//      callers can check +sdkAvailable before wiring render blocks to avoid
//      silently replacing working AUv3 instruments with an inert passthrough.
//

#import "VST3Host.h"

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

#if defined(TOOOT_VST3_SDK_AVAILABLE) && TOOOT_VST3_SDK_AVAILABLE
// Real Steinberg VST3 SDK — only compiled when vendored.
// #import "public.sdk/source/vst/hosting/module.h"
// #import "public.sdk/source/vst/hosting/plugprovider.h"
// #import "pluginterfaces/vst/ivstaudioprocessor.h"
// #import "pluginterfaces/vst/ivsteditcontroller.h"
#define TOOOT_VST3_SDK_ACTIVE 1
#else
#define TOOOT_VST3_SDK_ACTIVE 0
#endif

static NSString * const kToooTVST3ErrorDomain = @"com.apple.ProjectToooT.VST3";

@implementation VST3Host {
#if TOOOT_VST3_SDK_ACTIVE
    // VST3::Hosting::Module::Ptr module;
    // Steinberg::IPtr<Steinberg::Vst::IAudioProcessor> processor;
    // Steinberg::IPtr<Steinberg::Vst::IEditController>  controller;
#endif
}

+ (BOOL)sdkAvailable {
    return TOOOT_VST3_SDK_ACTIVE ? YES : NO;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pluginName   = @"<No Plugin Loaded>";
        _manufacturer = @"";
        _isLoaded     = NO;
    }
    return self;
}

+ (NSArray<NSString *> *)discoverPlugins {
    // Filesystem discovery works without the SDK — just listing .vst3 bundles.
    NSMutableArray<NSString *> *vst3Files = [NSMutableArray array];
    NSArray *paths = @[
        @"/Library/Audio/Plug-Ins/VST3",
        [@"~/Library/Audio/Plug-Ins/VST3" stringByExpandingTildeInPath]
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
            NSArray *contents = [fm contentsOfDirectoryAtPath:path error:nil];
            for (NSString *item in contents) {
                if ([item.pathExtension.lowercaseString isEqualToString:@"vst3"]) {
                    [vst3Files addObject:[path stringByAppendingPathComponent:item]];
                }
            }
        }
    }
    return [vst3Files copy];
}

- (BOOL)loadPluginAtPath:(NSString *)path error:(NSError **)error {
#if TOOOT_VST3_SDK_ACTIVE
    // Real path: VST3::Hosting::Module::create + PlugProvider + IAudioProcessor::setupProcessing
    if (error) {
        *error = [NSError errorWithDomain:kToooTVST3ErrorDomain
                                     code:-2
                                 userInfo:@{NSLocalizedDescriptionKey: @"VST3 SDK compiled in but host integration not wired yet."}];
    }
    return NO;
#else
    if (error) {
        *error = [NSError errorWithDomain:kToooTVST3ErrorDomain
                                     code:-1
                                 userInfo:@{NSLocalizedDescriptionKey: @"Steinberg VST3 SDK not vendored. Vendor into Sources/ToooT_VST3/VST3_SDK/ and set TOOOT_VST3_SDK_AVAILABLE=1."}];
    }
    _pluginName   = @"<No Plugin Loaded>";
    _manufacturer = @"";
    _isLoaded     = NO;
    return NO;
#endif
}

- (void)processAudioBufferL:(float *)bufferL bufferR:(float *)bufferR frames:(int)frames {
    if (!_isLoaded) return;
#if TOOOT_VST3_SDK_ACTIVE
    // Real path:
    // Vst::ProcessData data;
    // Vst::AudioBusBuffers outBus;
    // float *channels[2] = { bufferL, bufferR };
    // outBus.channelBuffers32 = channels;
    // outBus.numChannels = 2;
    // data.numSamples = frames;
    // data.outputs   = &outBus;
    // data.numOutputs = 1;
    // processor->process(data);
#endif
}

- (void)sendMidiNoteOn:(uint8_t)channel note:(uint8_t)note velocity:(float)velocity {
    if (!_isLoaded) return;
}

- (void)sendMidiNoteOff:(uint8_t)channel note:(uint8_t)note {
    if (!_isLoaded) return;
}

- (id)getPluginEditorView {
#if TARGET_OS_OSX
    NSView *stubView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    stubView.wantsLayer = YES;
    stubView.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.25 alpha:1.0] CGColor];

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 130, 400, 40)];
#if TOOOT_VST3_SDK_ACTIVE
    label.stringValue = [NSString stringWithFormat:@"%@ (VST3)", _pluginName];
#else
    label.stringValue = @"VST3 SDK not vendored — use AUv3 or CLAP";
#endif
    label.alignment       = NSTextAlignmentCenter;
    label.textColor       = [NSColor whiteColor];
    label.drawsBackground = NO;
    label.bordered        = NO;
    [stubView addSubview:label];

    return stubView;
#else
    return nil;
#endif
}

@end
