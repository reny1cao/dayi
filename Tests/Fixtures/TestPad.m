#import <Cocoa/Cocoa.h>

static NSTextView *a;
static NSTextView *b;
static NSWindow *window;

static void emit(NSString *event) {
    NSDictionary *state = @{
        @"event": event, @"pid": @(getpid()),
        @"a": a.string, @"b": b.string,
        @"aLocation": @(a.selectedRange.location), @"aLength": @(a.selectedRange.length),
        @"bLocation": @(b.selectedRange.location), @"bLength": @(b.selectedRange.length),
        @"firstResponder": window.firstResponder == a ? @"a" : window.firstResponder == b ? @"b" : @"other",
        @"aCanUndo": @(a.undoManager.canUndo), @"appActive": @(NSApp.active)
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 480, 260)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.title = @"TextPolish TestPad — Synthetic Text Only";
        window.releasedWhenClosed = NO;
        a = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 135, 440, 100)];
        b = [[NSTextView alloc] initWithFrame:NSMakeRect(20, 20, 440, 100)];
        a.richText = NO; b.richText = NO; a.allowsUndo = YES; b.allowsUndo = YES;
        a.accessibilityIdentifier = @"research-a";
        b.accessibilityIdentifier = @"research-b";
        a.string = @"前缀🙂 请解释这段代码 后缀"; b.string = @"B remains unchanged";
        [window.contentView addSubview:a]; [window.contentView addSubview:b];
        [a setSelectedRange:[a.string rangeOfString:@"请解释这段代码"]];
        [window makeFirstResponder:a];
        [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        [NSApp finishLaunching];
        emit(@"ready");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char line[256];
            while (fgets(line, sizeof(line), stdin)) {
                NSString *command = [[NSString stringWithUTF8String:line] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([command isEqual:@"focus-b"]) {
                        [window makeFirstResponder:b]; [b setSelectedRange:NSMakeRange(2, 0)];
                    } else if ([command isEqual:@"focus-a"]) {
                        [window makeFirstResponder:a];
                    } else if ([command isEqual:@"undo-a"]) {
                        if (a.undoManager.canUndo) [a.undoManager undo];
                    } else if ([command isEqual:@"reset"]) {
                        a.string = @"前缀🙂 请解释这段代码 后缀"; b.string = @"B remains unchanged";
                        [a.undoManager removeAllActions]; [b.undoManager removeAllActions];
                        [a setSelectedRange:[a.string rangeOfString:@"请解释这段代码"]];
                        [window makeFirstResponder:a];
                    } else if ([command isEqual:@"edit-a"]) {
                        a.string = @"前缀🙂 用户的新修改 后缀";
                    } else if ([command isEqual:@"quit"]) {
                        [window close]; [NSApp terminate:nil]; return;
                    }
                    emit(command);
                });
            }
        });
        [NSApp run];
    }
}
