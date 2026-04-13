//
//  JUCEVST3Host.mm
//  ToooT_VST3
//
//  Objective-C++ Wrapper Implementation for JUCE / Steinberg VST3 SDK
//

#import "JUCEVST3Host.h"

// If we had JUCE, we would include <JuceHeader.h> here and use
// juce::AudioPluginFormatManager and juce::VST3PluginFormat to load the plugin.

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

@implementation JUCEVST3Host {
    // juce::AudioPluginInstance* pluginInstance;
    // juce::MidiBuffer midiBuffer;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pluginName = @"<No Plugin Loaded>";
        _manufacturer = @"";
        _isLoaded = NO;
    }
    return self;
}

+ (NSArray<NSString *> *)discoverPlugins {
    NSMutableArray<NSString *> *vst3Files = [NSMutableArray array];
    
    // Simulate juce::VST3PluginFormat::getDefaultLocationsToSearch()
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
    // In a real implementation:
    // juce::VST3PluginFormat format;
    // juce::PluginDescription desc;
    // format.findAllTypesForFile(juce::String(path.UTF8String), results);
    // pluginInstance = format.createInstanceFromDescription(desc, sampleRate, blockSize).release();
    
    _pluginName = [path lastPathComponent];
    _manufacturer = @"Steinberg (VST3)";
    _isLoaded = YES;
    
    return YES;
}

- (void)processAudioBufferL:(float *)bufferL bufferR:(float *)bufferR frames:(int)frames {
    if (!_isLoaded) return;
    
    // In a real implementation:
    // juce::AudioBuffer<float> buffer(const_cast<float**>(&[bufferL, bufferR]), 2, frames);
    // pluginInstance->processBlock(buffer, midiBuffer);
    // midiBuffer.clear();
}

- (void)sendMidiNoteOn:(uint8_t)channel note:(uint8_t)note velocity:(float)velocity {
    if (!_isLoaded) return;
    // midiBuffer.addEvent(juce::MidiMessage::noteOn(channel, note, velocity), 0);
}

- (void)sendMidiNoteOff:(uint8_t)channel note:(uint8_t)note {
    if (!_isLoaded) return;
    // midiBuffer.addEvent(juce::MidiMessage::noteOff(channel, note, 0.0f), 0);
}

- (id)getPluginEditorView {
#if TARGET_OS_OSX
    // In a real implementation:
    // auto* editor = pluginInstance->createEditorIfNeeded();
    // return (__bridge id) editor->getPeer()->getNativeHandle();
    
    NSView *stubView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    stubView.wantsLayer = YES;
    stubView.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.25 alpha:1.0] CGColor];
    
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 130, 400, 40)];
    label.stringValue = [NSString stringWithFormat:@"%@ (VST3 via JUCE Stub)", _pluginName];
    label.alignment = NSTextAlignmentCenter;
    label.textColor = [NSColor whiteColor];
    label.drawsBackground = NO;
    label.bordered = NO;
    [stubView addSubview:label];
    
    return stubView;
#else
    return nil;
#endif
}

@end
