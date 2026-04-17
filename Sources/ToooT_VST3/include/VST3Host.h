//
//  VST3Host.h
//  ToooT_VST3
//
//  Obj-C++ host that links directly against Steinberg's VST3 SDK.
//  No JUCE dependency — JUCE's GPL/commercial dual-license is incompatible
//  with ToooT's MIT license. Steinberg's SDK is dual-licensed GPLv3 or
//  proprietary; the proprietary ("VST3 SDK License Agreement") is available
//  free to registered VST developers, and that's the path we take.
//
//  Audio path is gated behind TOOOT_VST3_SDK_AVAILABLE — builds and runs
//  safely without the SDK vendored (reports "not loaded" for every plugin).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VST3Host : NSObject

@property (nonatomic, copy, readonly) NSString *pluginName;
@property (nonatomic, copy, readonly) NSString *manufacturer;
@property (nonatomic, assign, readonly) BOOL isLoaded;

/// YES when the Steinberg VST3 SDK is compiled in. When NO, `loadPluginAtPath:`
/// always fails and callers must not install render blocks from this host
/// (doing so would replace a working AUv3 instrument with an inert passthrough).
@property (class, nonatomic, readonly) BOOL sdkAvailable;

/// Discovers VST3 bundles in the default system directories:
///   /Library/Audio/Plug-Ins/VST3  and  ~/Library/Audio/Plug-Ins/VST3
+ (NSArray<NSString *> *)discoverPlugins;

/// Attempts to load a VST3 bundle. Returns NO (and populates `error`) when the
/// SDK is not compiled in — see `sdkAvailable`.
- (BOOL)loadPluginAtPath:(NSString *)path error:(NSError **)error;

/// Process a block of audio. On the real SDK path this wraps
/// `Steinberg::Vst::IAudioProcessor::process`. Stub is a passthrough.
- (void)processAudioBufferL:(float *)bufferL bufferR:(float *)bufferR frames:(int)frames;

/// Deliver a MIDI event. SDK path: wraps `Steinberg::Vst::IEventList::addEvent`.
- (void)sendMidiNoteOn:(uint8_t)channel note:(uint8_t)note velocity:(float)velocity;
- (void)sendMidiNoteOff:(uint8_t)channel note:(uint8_t)note;

/// Returns an NSView hosting the plugin's editor (`IPlugView::attached`).
/// Stub returns a placeholder view.
- (id)getPluginEditorView;

@end

NS_ASSUME_NONNULL_END
