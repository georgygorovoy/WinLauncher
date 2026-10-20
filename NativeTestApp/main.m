#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const WLAppName = @"WinLauncher Test";

@protocol WLDropViewDelegate <NSObject>
- (void)dropViewReceivedURL:(NSURL *)url;
@end

@interface WLDropView : NSView
@property(nonatomic, weak) id<WLDropViewDelegate> delegate;
@end

@implementation WLDropView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        self.wantsLayer = YES;
        self.layer.cornerRadius = 18.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = NSColor.separatorColor.CGColor;
        self.layer.backgroundColor = [NSColor.controlBackgroundColor colorWithAlphaComponent:0.45].CGColor;
    }
    return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSURL *url = [NSURL URLFromPasteboard:sender.draggingPasteboard];
    BOOL accepted = url.isFileURL && [@[@"exe", @"msi"] containsObject:url.pathExtension.lowercaseString];
    if (accepted) {
        self.layer.borderWidth = 2.0;
        self.layer.borderColor = NSColor.controlAccentColor.CGColor;
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = NSColor.separatorColor.CGColor;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    [self draggingExited:sender];
    NSURL *url = [NSURL URLFromPasteboard:sender.draggingPasteboard];
    if (!url) return NO;
    [self.delegate dropViewReceivedURL:url];
    return YES;
}

@end

@interface WLAppDelegate : NSObject <NSApplicationDelegate, WLDropViewDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *openButton;
@property(nonatomic, strong) NSButton *installerButton;
@property(nonatomic, strong) NSMutableSet<NSTask *> *runningTasks;
@end

@implementation WLAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.runningTasks = [NSMutableSet set];
    [self buildWindow];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 700, 470);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                               backing:NSBackingStoreBuffered defer:NO];
    self.window.title = WLAppName;
    self.window.titlebarAppearsTransparent = YES;
    self.window.movableByWindowBackground = YES;
    [self.window center];

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:frame];
    background.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    background.material = NSVisualEffectMaterialUnderWindowBackground;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;
    self.window.contentView = background;

    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:stack];

    NSTextField *title = [NSTextField labelWithString:@"Run Windows apps on your Mac."];
    title.font = [NSFont systemFontOfSize:30 weight:NSFontWeightSemibold];
    title.alignment = NSTextAlignmentCenter;

    NSTextField *subtitle = [NSTextField wrappingLabelWithString:@"Open an application or installer. Everything uses the same Windows Environment by default."];
    subtitle.font = [NSFont systemFontOfSize:15];
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.alignment = NSTextAlignmentCenter;
    [subtitle.widthAnchor constraintEqualToConstant:520].active = YES;

    WLDropView *dropView = [[WLDropView alloc] initWithFrame:NSZeroRect];
    dropView.delegate = self;
    dropView.translatesAutoresizingMaskIntoConstraints = NO;
    [dropView.widthAnchor constraintEqualToConstant:540].active = YES;
    [dropView.heightAnchor constraintEqualToConstant:155].active = YES;

    NSStackView *dropContent = [NSStackView stackViewWithViews:@[]];
    dropContent.orientation = NSUserInterfaceLayoutOrientationVertical;
    dropContent.alignment = NSLayoutAttributeCenterX;
    dropContent.spacing = 8;
    dropContent.translatesAutoresizingMaskIntoConstraints = NO;
    [dropView addSubview:dropContent];
    NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"arrow.down.app" accessibilityDescription:nil]];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:30 weight:NSFontWeightRegular];
    NSTextField *dropTitle = [NSTextField labelWithString:@"Drop an .exe or .msi here"];
    dropTitle.font = [NSFont systemFontOfSize:17 weight:NSFontWeightMedium];
    NSTextField *dropHint = [NSTextField labelWithString:@"The first launch prepares the shared environment"];
    dropHint.textColor = NSColor.secondaryLabelColor;
    [dropContent addArrangedSubview:icon];
    [dropContent addArrangedSubview:dropTitle];
    [dropContent addArrangedSubview:dropHint];
    [NSLayoutConstraint activateConstraints:@[
        [dropContent.centerXAnchor constraintEqualToAnchor:dropView.centerXAnchor],
        [dropContent.centerYAnchor constraintEqualToAnchor:dropView.centerYAnchor]
    ]];

    NSStackView *buttons = [NSStackView stackViewWithViews:@[]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 10;
    self.openButton = [NSButton buttonWithTitle:@"Open Windows App" target:self action:@selector(openWindowsApp:)];
    self.openButton.bezelStyle = NSBezelStyleRounded;
    self.openButton.keyEquivalent = @"\r";
    self.installerButton = [NSButton buttonWithTitle:@"Choose Installer" target:self action:@selector(chooseInstaller:)];
    self.installerButton.bezelStyle = NSBezelStyleRounded;
    [buttons addArrangedSubview:self.openButton];
    [buttons addArrangedSubview:self.installerButton];

    self.statusLabel = [NSTextField labelWithString:@"Ready"];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.alignment = NSTextAlignmentCenter;

    [stack addArrangedSubview:title];
    [stack addArrangedSubview:subtitle];
    [stack setCustomSpacing:24 afterView:subtitle];
    [stack addArrangedSubview:dropView];
    [stack setCustomSpacing:18 afterView:dropView];
    [stack addArrangedSubview:buttons];
    [stack addArrangedSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:background.centerYAnchor constant:10]
    ]];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)openWindowsApp:(id)sender { [self showOpenPanelWithPrompt:@"Open"]; }
- (void)chooseInstaller:(id)sender { [self showOpenPanelWithPrompt:@"Install"]; }

- (void)showOpenPanelWithPrompt:(NSString *)prompt {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"exe"],
                                  [UTType typeWithFilenameExtension:@"msi"]];
    panel.prompt = prompt;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK && panel.URL) [self launchURL:panel.URL];
    }];
}

- (void)dropViewReceivedURL:(NSURL *)url { [self launchURL:url]; }

- (NSURL *)supportRoot {
    NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                       inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    return [base URLByAppendingPathComponent:@"WinLauncher Test" isDirectory:YES];
}

- (NSURL *)engineURL {
    return [[[[self supportRoot] URLByAppendingPathComponent:@"Engines" isDirectory:YES]
             URLByAppendingPathComponent:@"Sikarugir10" isDirectory:YES]
            URLByAppendingPathComponent:@"wswine.bundle" isDirectory:YES];
}

- (NSURL *)prefixURL {
    return [[[[self supportRoot] URLByAppendingPathComponent:@"Environments" isDirectory:YES]
             URLByAppendingPathComponent:@"Default" isDirectory:YES]
            URLByAppendingPathComponent:@"prefix" isDirectory:YES];
}

- (NSURL *)logsURL { return [[self supportRoot] URLByAppendingPathComponent:@"Logs" isDirectory:YES]; }

- (void)setBusy:(BOOL)busy status:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.openButton.enabled = !busy;
        self.installerButton.enabled = !busy;
        self.statusLabel.stringValue = status;
    });
}

- (void)launchURL:(NSURL *)url {
    [self setBusy:YES status:@"Preparing Windows Environment…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        if (![self prepareEnvironment:&error]) {
            [self presentError:error ?: [NSError errorWithDomain:@"WinLauncherTest" code:1
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Environment preparation failed."}]];
            return;
        }
        [self runWindowsURL:url];
    });
}

- (BOOL)prepareEnvironment:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *engine = [self engineURL];
    NSURL *prefix = [self prefixURL];
    NSURL *logs = [self logsURL];
    for (NSURL *directory in @[[engine URLByDeletingLastPathComponent], prefix, logs]) {
        if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES
                           attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;
    }

    NSURL *wine = [engine URLByAppendingPathComponent:@"bin/wine"];
    if (![fm isExecutableFileAtPath:wine.path]) {
        NSURL *archive = [NSBundle.mainBundle URLForResource:@"WS12WineSikarugir10.0_6" withExtension:@"tar.xz"];
        if (!archive) {
            if (error) *error = [NSError errorWithDomain:@"WinLauncherTest" code:2
                                                userInfo:@{NSLocalizedDescriptionKey: @"Bundled Wine engine is missing."}];
            return NO;
        }
        int status = [self runTool:@"/usr/bin/tar"
                         arguments:@[@"-xf", archive.path, @"-C", engine.URLByDeletingLastPathComponent.path]
                       environment:@{@"LC_ALL": @"C"} logName:@"engine-install.log" error:error];
        if (status != 0) return NO;
    }

    NSURL *systemRegistry = [prefix URLByAppendingPathComponent:@"system.reg"];
    if (![fm fileExistsAtPath:systemRegistry.path]) {
        NSMutableDictionary *environment = [self wineEnvironment];
        environment[@"WINEARCH"] = @"wow64";
        int status = [self runTool:wine.path arguments:@[@"wineboot", @"--init"]
                       environment:environment logName:@"environment-init.log" error:error];
        if (status != 0) return NO;
        NSURL *zDrive = [prefix URLByAppendingPathComponent:@"dosdevices/z:"];
        [fm removeItemAtURL:zDrive error:nil];
    }
    return YES;
}

- (NSMutableDictionary<NSString *, NSString *> *)wineEnvironment {
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"WINEPREFIX"] = self.prefixURL.path;
    environment[@"WINEDEBUG"] = @"-all";
    environment[@"LC_ALL"] = @"C";
    NSString *engineBin = [[self engineURL] URLByAppendingPathComponent:@"bin"].path;
    environment[@"PATH"] = [NSString stringWithFormat:@"%@:/usr/bin:/bin:/usr/sbin:/sbin", engineBin];
    return environment;
}

- (void)runWindowsURL:(NSURL *)url {
    NSURL *wine = [[self engineURL] URLByAppendingPathComponent:@"bin/wine"];
    NSURL *log = [[self logsURL] URLByAppendingPathComponent:
                  [NSString stringWithFormat:@"run-%@.log", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createFileAtPath:log.path contents:nil
                                        attributes:@{NSFilePosixPermissions: @0600}];
    NSError *error = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:log error:&error];
    if (!handle) { [self presentError:error]; return; }
    NSTask *task = [NSTask new];
    task.executableURL = wine;
    task.arguments = @[url.path];
    task.environment = [self wineEnvironment];
    task.standardOutput = handle;
    task.standardError = handle;
    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        [handle closeFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.runningTasks removeObject:finished];
            weakSelf.openButton.enabled = YES;
            weakSelf.installerButton.enabled = YES;
            weakSelf.statusLabel.stringValue = finished.terminationStatus == 0
                ? @"Windows app finished" : [NSString stringWithFormat:@"Windows app couldn't start. Log: %@", log.lastPathComponent];
        });
    };
    [self.runningTasks addObject:task];
    if (![task launchAndReturnError:&error]) {
        [self.runningTasks removeObject:task];
        [handle closeFile];
        [self presentError:error];
        return;
    }
    [self setBusy:YES status:[NSString stringWithFormat:@"Running %@…", url.lastPathComponent]];
}

- (int)runTool:(NSString *)tool arguments:(NSArray<NSString *> *)arguments
   environment:(NSDictionary<NSString *, NSString *> *)environment logName:(NSString *)logName error:(NSError **)error {
    NSURL *log = [[self logsURL] URLByAppendingPathComponent:logName];
    [NSFileManager.defaultManager createFileAtPath:log.path contents:nil attributes:@{NSFilePosixPermissions: @0600}];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:log error:error];
    if (!handle) return -1;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = arguments;
    NSMutableDictionary *merged = [NSProcessInfo.processInfo.environment mutableCopy];
    [merged addEntriesFromDictionary:environment];
    task.environment = merged;
    task.standardOutput = handle;
    task.standardError = handle;
    if (![task launchAndReturnError:error]) { [handle closeFile]; return -1; }
    [task waitUntilExit];
    [handle closeFile];
    if (task.terminationStatus != 0 && error) {
        *error = [NSError errorWithDomain:@"WinLauncherTest" code:task.terminationStatus
                                userInfo:@{NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:@"A preparation step failed. See %@", log.path]}];
    }
    return task.terminationStatus;
}

- (void)presentError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.openButton.enabled = YES;
        self.installerButton.enabled = YES;
        self.statusLabel.stringValue = @"Windows app couldn't start.";
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Windows app couldn't start.";
        alert.informativeText = error.localizedDescription ?: @"Unknown error";
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    });
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        WLAppDelegate *delegate = [WLAppDelegate new];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
