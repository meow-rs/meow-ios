#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

// Entry point of the macOS system extension. NetworkExtension takes over the
// process and instantiates `PacketTunnelProvider` (Info.plist
// NetworkExtension › NEProviderClasses) whenever the app's tunnel starts.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NEProvider startSystemExtensionMode];
    }
    dispatch_main();
}
