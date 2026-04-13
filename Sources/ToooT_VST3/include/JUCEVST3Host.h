//
//  JUCEVST3Host.h
//  ToooT_VST3
//
//  Objective-C++ Wrapper for JUCE / Steinberg VST3 SDK
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JUCEVST3Host : NSObject

@property (nonatomic, copy, readonly) NSString *pluginName;
@property (nonatomic, copy, readonly) NSString *manufacturer;
@property (nonatomic, assign, readonly) BOOL isLoaded;

/// Discovers VST3 plugins in the default system directories.
/// Typically: /Library/Audio/Plug-Ins/VST3 and ~/Library/Audio/Plug-Ins/VST3
+ (NSArray<NSString *> *)discoverPlugins;

/// Attempts to load a VST3 plugin given its file path.
- (BOOL)loadPluginAtPath:(NSString *)path error:(NSError **)error;

/// Process a block of audio data (interleaved or non-interleaved).
/// In a real JUCE environment, this wraps juce::AudioProcessor::processBlock().
- (void)processAudioBufferL:(float *)bufferL bufferR:(float *)bufferR frames:(int)frames;

/// Deliver a MIDI event (Note On/Off) to the plugin.
/// Wraps juce::MidiBuffer and delivers to processBlock.
- (void)sendMidiNoteOn:(uint8_t)channel note:(uint8_t)note velocity:(float)velocity;
- (void)sendMidiNoteOff:(uint8_t)channel note:(uint8_t)note;

/// Returns an NSView/UIView representing the plugin's UI editor, wrapping juce::AudioProcessorEditor.
/// Currently returns a generic NSView for testing.
- (id)getPluginEditorView;

@end

NS_ASSUME_NONNULL_END
