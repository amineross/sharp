#import <Cocoa/Cocoa.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "../app/SharpAudio.h"
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <math.h>
#include "sharp/hybrid.h"
#include "sharp/tile.h"

// The app owns discovery/control only. The unmodified shared helper owns pixels.
@interface ReceiverApp : NSObject <NSApplicationDelegate, NSStreamDelegate, NSNetServiceDelegate>
@property NSWindow *window;
@property NSTextField *titleLabel, *detailLabel;
@property NSNetService *service;
@property NSInputStream *input;
@property NSOutputStream *output;
@property NSMutableData *incoming, *outgoing, *engineLines;
@property dispatch_source_t listenerSource;
@property NSTask *engine;
@property NSButton *resumeButton;
@property NSTask *retiringEngine;
@property NSUInteger generation;
@property NSPipe *engineInput, *engineOutput;
@property SharpAudio *audio;
@property NSString *peerID, *peerName, *localIP, *audioToken, *benchmarkScene;
@property NSString *logPath;
@property NSFileHandle *log;
@property NSTimer *timer;
@property NSTimeInterval lastReceived;
@property BOOL sleeping, peerSleeping, starting, terminating, peerDisplayAsleep;
@property id<NSObject> sessionActivity, displayActivity;
@property double cursorScale, cursorHue;
@end

static BOOL wiredAddress(NSString *ip) {
    if ([NSProcessInfo.processInfo.environment[@"SHARP_RECEIVER_TEST_LOOPBACK"] isEqual:@"1"] &&
        [ip isEqual:@"127.0.0.1"]) return YES;
    NSMutableSet *names = [NSMutableSet new];
    NSArray *interfaces = CFBridgingRelease(SCNetworkInterfaceCopyAll());
    for (id item in interfaces) {
        SCNetworkInterfaceRef iface = (__bridge SCNetworkInterfaceRef)item;
        NSString *type = (__bridge NSString *)SCNetworkInterfaceGetInterfaceType(iface);
        NSString *label = (__bridge NSString *)SCNetworkInterfaceGetLocalizedDisplayName(iface) ?: @"";
        // Ethernet adapters and Thunderbolt Bridge ("Bridge" is not a public constant).
        // iPhone and iPad tethering also report as Ethernet.
        BOOL ethernet = [type isEqual:(__bridge NSString *)kSCNetworkInterfaceTypeEthernet] &&
                        ![label hasPrefix:@"iPhone"] && ![label hasPrefix:@"iPad"];
        if (ethernet || [type isEqual:@"Bridge"]) {
            NSString *name = (__bridge NSString *)SCNetworkInterfaceGetBSDName(iface);
            if (name) [names addObject:name];
        }
    }
    struct ifaddrs *addresses = NULL;
    BOOL found = NO;
    if (getifaddrs(&addresses) == 0) {
        for (struct ifaddrs *a = addresses; a; a = a->ifa_next) {
            if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET || !(a->ifa_flags & IFF_UP) ||
                ![names containsObject:@(a->ifa_name)]) continue;
            char address[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, address, sizeof(address));
            if ([ip isEqual:@(address)]) { found = YES; break; }
        }
        freeifaddrs(addresses);
    }
    return found;
}

@implementation ReceiverApp
- (void)status:(NSString *)title detail:(NSString *)detail {
    self.titleLabel.stringValue = title;
    self.resumeButton.hidden = YES;
    self.detailLabel.stringValue = detail ?: @"";
}
- (void)record:(NSString *)text {
    if (self.log.offsetInFile > 8 * 1024 * 1024) {
        [self.log truncateFileAtOffset:0]; [self.log seekToFileOffset:0];
    }
    [self.log writeData:[[NSString stringWithFormat:@"%@ %@\n", NSDate.date, text] dataUsingEncoding:NSUTF8StringEncoding]];
}
- (void)showWindow:(id)sender { (void)sender; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
- (void)showReport:(id)sender { (void)sender; [self.log synchronizeFile]; [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:self.logPath]]]; }
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    signal(SIGPIPE, SIG_IGN);
    NSString *support = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Sharp Receiver"];
    [[NSFileManager defaultManager] createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:nil];
    self.logPath = [support stringByAppendingPathComponent:@"Receiver.log"];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:[support stringByAppendingPathComponent:@"Receiver-previous.log"] error:nil];
    [fm moveItemAtPath:self.logPath toPath:[support stringByAppendingPathComponent:@"Receiver-previous.log"] error:nil];
    [fm createFileAtPath:self.logPath contents:nil attributes:nil];
    self.log = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"development";
    [self record:[NSString stringWithFormat:@"Sharp Receiver %@; %@", version, NSProcessInfo.processInfo.operatingSystemVersionString]];
    self.peerID = [NSUserDefaults.standardUserDefaults stringForKey:@"peerID"] ?: NSUUID.UUID.UUIDString;
    [NSUserDefaults.standardUserDefaults setObject:self.peerID forKey:@"peerID"];
    self.cursorScale = 1; self.cursorHue = 0.9;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,420,290)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Sharp Receiver"; self.window.releasedWhenClosed = NO;
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(170,166,80,80)];
    icon.image = [NSImage imageNamed:NSImageNameApplicationIcon];
    [self.window.contentView addSubview:icon];
    self.titleLabel = [NSTextField labelWithString:@"Waiting for your Mac…"];
    self.titleLabel.frame = NSMakeRect(20,119,380,30);
    self.titleLabel.font = [NSFont systemFontOfSize:21 weight:NSFontWeightMedium];
    self.titleLabel.alignment = NSTextAlignmentCenter;
    [self.window.contentView addSubview:self.titleLabel];
    self.detailLabel = [NSTextField wrappingLabelWithString:@"Connect Ethernet or Thunderbolt and open Sharp on your other Mac."];
    self.detailLabel.frame = NSMakeRect(32,73,356,44);
    self.detailLabel.font = [NSFont systemFontOfSize:13];
    self.detailLabel.textColor = NSColor.secondaryLabelColor;
    self.detailLabel.alignment = NSTextAlignmentCenter;
    [self.window.contentView addSubview:self.detailLabel];
    NSTextField *credit = [NSTextField labelWithString:[NSString stringWithFormat:@"Sharp %@ by Amine Rostane", version]];
    self.resumeButton = [NSButton buttonWithTitle:@"Resume" target:self action:@selector(resume:)];
    self.resumeButton.frame = NSMakeRect(160,36,100,30); self.resumeButton.hidden = YES;
    [self.window.contentView addSubview:self.resumeButton];
    credit.frame = NSMakeRect(20,10,380,20); credit.alignment = NSTextAlignmentCenter;
    credit.font = [NSFont systemFontOfSize:11]; credit.textColor = NSColor.secondaryLabelColor;
    [self.window.contentView addSubview:credit];
    NSMenu *menu = [NSMenu new]; NSMenuItem *root = [NSMenuItem new]; [menu addItem:root];
    NSMenu *appMenu = [NSMenu new]; root.submenu = appMenu;
    for (NSArray *entry in @[@[@"Show Sharp Receiver", NSStringFromSelector(@selector(showWindow:)), @"0"],
                            @[@"Open report", NSStringFromSelector(@selector(showReport:)), @""],
                            @[@"Quit Sharp Receiver", NSStringFromSelector(@selector(terminate:)), @"q"]]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:entry[2]];
        item.target = [entry[0] hasPrefix:@"Quit"] ? NSApp : self; [appMenu addItem:item];
    }
    NSApp.mainMenu = menu;
    [self.window center]; [self showWindow:nil];
    NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
    [nc addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [nc addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [self startListener];
    [self checkForUpdate:nil];
    NSTimer *updates = [NSTimer timerWithTimeInterval:24*60*60 target:self selector:@selector(checkForUpdate:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:updates forMode:NSRunLoopCommonModes];
    self.timer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    (void)app; (void)visible; [self showWindow:nil]; return YES;
}
- (void)startListener {
    if (self.listenerSource || self.sleeping) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    if (fd < 0) { [self status:@"Could not connect" detail:@"Open report from the Sharp Receiver menu."]; return; }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {.sin_len=sizeof(addr), .sin_family=AF_INET, .sin_port=htons(49171), .sin_addr.s_addr=htonl(INADDR_ANY)};
    int bound = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (bound && errno == EADDRINUSE) {
        // Another app holds 49171. Bonjour carries the port, so any free one works.
        [self record:@"Port 49171 is in use; listening on another port"];
        addr.sin_port = 0; bound = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    }
    socklen_t addrSize = sizeof(addr);
    if (bound || listen(fd, 4) || getsockname(fd, (struct sockaddr *)&addr, &addrSize)) {
        [self record:[NSString stringWithFormat:@"listener: %s", strerror(errno)]]; close(fd);
        [self status:@"Could not listen for Sharp" detail:@"Open report from the Sharp Receiver menu."]; return;
    }
    int port = ntohs(addr.sin_port);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    self.listenerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
    __weak ReceiverApp *weak = self;
    dispatch_source_set_event_handler(self.listenerSource, ^{ [weak acceptSocket:fd]; });
    dispatch_source_set_cancel_handler(self.listenerSource, ^{ close(fd); });
    dispatch_resume(self.listenerSource);
    self.service = [[NSNetService alloc] initWithDomain:@"local." type:@"_sharp._tcp." name:self.peerID port:port];
    self.service.delegate = self; [self.service publish];
    [self record:[NSString stringWithFormat:@"Listening on %d; Bonjour _sharp._tcp", port]];
}
- (void)netService:(NSNetService *)service didNotPublish:(NSDictionary *)error {
    (void)service; [self record:[NSString stringWithFormat:@"Bonjour error %@", error]];
    [self status:@"Discovery unavailable" detail:@"Open report from the Sharp Receiver menu."];
}
- (void)acceptSocket:(int)listener {
    int fd = accept(listener, NULL, NULL); if (fd < 0) return;
    struct sockaddr_in local; socklen_t size=sizeof(local);
    if (getsockname(fd,(struct sockaddr *)&local,&size)) { close(fd); return; }
    char ip[INET_ADDRSTRLEN]; inet_ntop(AF_INET,&local.sin_addr,ip,sizeof(ip));
    if (self.input || self.sleeping) { close(fd); return; }
    if (!wiredAddress(@(ip))) {
        // Tell the sender why, so it explains instead of retrying blindly.
        NSString *name = NSHost.currentHost.localizedName ?: @"The display Mac";
        NSDictionary *m = @{@"command":@"rejected", @"peerID":self.peerID, @"peerName":name,
            @"reason":[NSString stringWithFormat:@"%@ can’t use this network link. Connect the Macs with Ethernet or Thunderbolt.", name]};
        NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:m options:0 error:nil] mutableCopy];
        [line appendBytes:"\n" length:1];
        (void)write(fd, line.bytes, line.length);
        [self record:[NSString stringWithFormat:@"Rejected connection on %s: not Ethernet or Thunderbolt", ip]];
        close(fd); return;
    }
    int one=1; setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    CFReadStreamRef read=NULL; CFWriteStreamRef write=NULL;
    CFStreamCreatePairWithSocket(NULL,fd,&read,&write);
    if (!read || !write) { if(read) CFRelease(read); if(write) CFRelease(write); close(fd); return; }
    CFReadStreamSetProperty(read,kCFStreamPropertyShouldCloseNativeSocket,kCFBooleanTrue);
    CFWriteStreamSetProperty(write,kCFStreamPropertyShouldCloseNativeSocket,kCFBooleanTrue);
    self.input=CFBridgingRelease(read); self.output=CFBridgingRelease(write);
    self.localIP=@(ip); self.incoming=[NSMutableData new]; self.outgoing=[NSMutableData new];
    self.peerSleeping=NO; self.peerDisplayAsleep=NO;
    self.lastReceived=NSDate.timeIntervalSinceReferenceDate;
    for (NSStream *stream in @[self.input,self.output]) {
        stream.delegate=self; [stream scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes]; [stream open];
    }
    /* CGDisplayPixelsWide counts points; a 5K iMac would report 2560×1440. */
    size_t width=CGDisplayPixelsWide(CGMainDisplayID()), height=CGDisplayPixelsHigh(CGMainDisplayID());
    CGDisplayModeRef mode=CGDisplayCopyDisplayMode(CGMainDisplayID());
    if(mode) {
        if(CGDisplayModeGetPixelWidth(mode)>=2 && CGDisplayModeGetPixelHeight(mode)>=2) {
            width=CGDisplayModeGetPixelWidth(mode); height=CGDisplayModeGetPixelHeight(mode);
        }
        CGDisplayModeRelease(mode);
    }
    width&=~(size_t)1; height&=~(size_t)1;
    [self send:@{@"command":@"display", @"width":@(MAX(640,width)), @"height":@(MAX(360,height)),
                @"sharingEnabled":@YES, @"audioSupported":@YES}];
    [self record:[NSString stringWithFormat:@"Control connected on %@", self.localIP]];
    [self updateActivities];
}
// App Nap delays the heartbeat timer once the window hides, which dropped the
// connection about once a minute. Hold an activity while connected, and keep
// the screen on while it shows the sender, unless the sender's screens sleep.
- (void)updateActivities {
    NSProcessInfo *info = NSProcessInfo.processInfo;
    if (self.input && !self.sessionActivity) {
        self.sessionActivity = [info beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical
                                                       reason:@"Sharp keeps its connection responsive"];
    } else if (!self.input && self.sessionActivity) {
        [info endActivity:self.sessionActivity]; self.sessionActivity = nil;
    }
    BOOL showing = self.engine.running && !self.starting && !self.peerDisplayAsleep;
    if (showing && !self.displayActivity) {
        self.displayActivity = [info beginActivityWithOptions:NSActivityUserInitiated | NSActivityIdleDisplaySleepDisabled
                                                       reason:@"Sharp is showing another Mac's screen"];
        [self wakeDisplay];
    } else if (!showing && self.displayActivity) {
        [info endActivity:self.displayActivity]; self.displayActivity = nil;
    }
}
- (void)wakeDisplay {
    IOPMAssertionID assertion = 0;
    if (IOPMAssertionDeclareUserActivity(CFSTR("Sharp is showing another Mac's screen"), kIOPMUserActiveLocal, &assertion) == kIOReturnSuccess)
        IOPMAssertionRelease(assertion);
}
- (void)send:(NSDictionary *)message {
    if (!self.output) return;
    NSMutableDictionary *m=[message mutableCopy]; m[@"peerID"]=self.peerID;
    m[@"peerName"]=NSHost.currentHost.localizedName ?: @"Sharp Receiver";
    NSData *data=[NSJSONSerialization dataWithJSONObject:m options:0 error:nil];
    if (!data || self.outgoing.length+data.length>65536) { [self disconnect:@"control send buffer full"]; return; }
    [self.outgoing appendData:data]; [self.outgoing appendBytes:"\n" length:1]; [self flush];
}
- (void)flush {
    while (self.output.hasSpaceAvailable && self.outgoing.length) {
        NSInteger n=[self.output write:self.outgoing.bytes maxLength:self.outgoing.length];
        if (n<0) { [self disconnect:@"send failed"]; return; } if (!n) break;
        [self.outgoing replaceBytesInRange:NSMakeRange(0,n) withBytes:NULL length:0];
    }
}
- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
    if (stream!=self.input && stream!=self.output) return;
    if (event==NSStreamEventErrorOccurred) { [self disconnect:[NSString stringWithFormat:@"stream error: %@", stream.streamError.localizedDescription]]; return; }
    if (event==NSStreamEventEndEncountered) { [self disconnect:@"closed by the other Mac"]; return; }
    if (event==NSStreamEventHasSpaceAvailable) { [self flush]; return; }
    if (event!=NSStreamEventHasBytesAvailable) return;
    uint8_t bytes[8192]; NSInteger n=[self.input read:bytes maxLength:sizeof(bytes)];
    if (n<=0) { [self disconnect:@"closed by the other Mac"]; return; }
    [self.incoming appendBytes:bytes length:n];
    if (self.incoming.length>65536) { [self disconnect:@"message too large"]; return; }
    while (self.incoming.length) {
        const uint8_t *start=self.incoming.bytes, *newline=memchr(start,'\n',self.incoming.length);
        if (!newline) break;
        NSUInteger length=newline-start;
        NSData *line=[self.incoming subdataWithRange:NSMakeRange(0,length)];
        [self.incoming replaceBytesInRange:NSMakeRange(0,length+1) withBytes:NULL length:0];
        id m=[NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if (![m isKindOfClass:NSDictionary.class] || ![m[@"command"] isKindOfClass:NSString.class] ||
            ![m[@"peerID"] isKindOfClass:NSString.class] || ![m[@"peerName"] isKindOfClass:NSString.class]) {
            [self disconnect:@"invalid control message"]; return;
        }
        self.lastReceived=NSDate.timeIntervalSinceReferenceDate; [self handle:m];
    }
}
- (void)stopEngine {
    self.generation++;
    self.starting=NO; self.benchmarkScene=nil;
    self.audioToken=nil; [self.audio stop]; self.audio=nil;
    NSTask *old=self.engine; self.engine=nil;
    self.engineOutput.fileHandleForReading.readabilityHandler=nil;
    self.engineOutput=nil; self.engineInput=nil;
    [self updateActivities];
    if (old.running) {
        self.retiringEngine=old;
        [old terminate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ if(old.running) kill(old.processIdentifier,SIGKILL); });
    }
}
- (void)disconnect:(NSString *)reason {
    if (self.input) [self record:[NSString stringWithFormat:@"Disconnected: %@", reason]];
    for(NSStream *s in @[self.input ?: (id)NSNull.null,self.output ?: (id)NSNull.null]) {
        if (![s isKindOfClass:NSStream.class]) continue;
        s.delegate=nil; [s close]; [s removeFromRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    self.input=nil; self.output=nil; self.incoming=nil; self.outgoing=nil;
    [self stopEngine];
    [self status:@"Waiting for your Mac…" detail:@"Connect Ethernet or Thunderbolt and open Sharp on your other Mac."];
    if(!self.terminating && !self.sleeping) [self.window orderFront:nil];
}
- (void)tick:(id)sender {
    (void)sender;
    if(!self.input) return;
    NSTimeInterval silent=NSDate.timeIntervalSinceReferenceDate-self.lastReceived;
    if(silent>4) { [self disconnect:[NSString stringWithFormat:@"no reply for %.0fs", silent]]; return; }
    [self send:@{@"command":@"ping"}];
}
/* Once a day, ask aminerostane.com for the latest receiver and mention it
 * once per version. Nothing about this Mac is sent. */
- (void)checkForUpdate:(id)sender {
    (void)sender;
    NSURL *url = [NSURL URLWithString:@"https://aminerostane.com/sharp/version.json"];
    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response; if (error || !data) return;
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *latest = [root isKindOfClass:NSDictionary.class] ? root[@"highSierra"] : nil;
        if (![latest isKindOfClass:NSDictionary.class]) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [self offerUpdate:latest]; });
    }] resume];
}
- (void)offerUpdate:(NSDictionary *)latest {
    NSInteger build = [latest[@"build"] isKindOfClass:NSNumber.class] ? [latest[@"build"] integerValue] : 0;
    NSInteger current = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] integerValue];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *version = [latest[@"version"] isKindOfClass:NSString.class] ? latest[@"version"] : nil;
    NSURL *page = [latest[@"url"] isKindOfClass:NSString.class] ? [NSURL URLWithString:latest[@"url"]] : nil;
    if (build <= current || [defaults integerForKey:@"updateOfferedBuild"] >= build || !version || !page) return;
    [defaults setInteger:build forKey:@"updateOfferedBuild"];
    NSMutableString *text = [NSMutableString new];
    NSArray *notes = [latest[@"notes"] isKindOfClass:NSArray.class] ? latest[@"notes"] : @[];
    for (id note in [notes subarrayWithRange:NSMakeRange(0, MIN(notes.count, 8u))])
        if ([note isKindOfClass:NSString.class]) [text appendFormat:@"%@• %@", text.length ? @"\n" : @"What's new:\n", note];
    [text appendFormat:@"%@Download it at aminerostane.com/sharp/highsierra.", text.length ? @"\n\n" : @""];
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Sharp Receiver %@ is available", version];
    alert.informativeText = text;
    [alert addButtonWithTitle:@"Download"]; [alert addButtonWithTitle:@"Later"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] == NSAlertFirstButtonReturn) [NSWorkspace.sharedWorkspace openURL:page];
}
/* Lifts a pause made on the sending Mac without walking over to it. */
- (void)resume:(id)sender {
    (void)sender;
    [self send:@{@"command":@"resume-all",@"sharingEnabled":@YES}];
    [self status:@"Resuming…" detail:self.peerName];
}
- (void)handle:(NSDictionary *)m {
    NSString *cmd=m[@"command"];
    if([cmd isEqual:@"ping"]) return;
    if(self.peerSleeping) return;
    [self record:[NSString stringWithFormat:@"Control %@",cmd]];
    if([cmd isEqual:@"hello"] || [cmd isEqual:@"resume"]) {
        self.peerName=m[@"peerName"]; [self status:@"Connected" detail:self.peerName]; return;
    }
    if([cmd isEqual:@"display-sleep"]) { self.peerDisplayAsleep=YES; [self updateActivities]; return; }
    if([cmd isEqual:@"display-wake"]) { self.peerDisplayAsleep=NO; [self wakeDisplay]; [self updateActivities]; return; }
    if([cmd isEqual:@"stop"] || [cmd isEqual:@"sleeping"]) {
        self.peerSleeping=[cmd isEqual:@"sleeping"];
        [self stopEngine]; [self status:@"Paused" detail:self.peerName];
        self.resumeButton.hidden = self.peerSleeping; [self.window orderFront:nil]; return;
    }
    if([cmd isEqual:@"cursor-style"] || [cmd isEqual:@"start"]) {
        if([m[@"cursorScale"] isKindOfClass:NSNumber.class] && isfinite([m[@"cursorScale"] doubleValue]))
            self.cursorScale=MIN(2,MAX(0.6,[m[@"cursorScale"] doubleValue]));
        if([m[@"cursorHue"] isKindOfClass:NSNumber.class] && isfinite([m[@"cursorHue"] doubleValue]))
            self.cursorHue=MIN(1,MAX(0,[m[@"cursorHue"] doubleValue]));
        if([cmd isEqual:@"cursor-style"]) {
            NSString *line=[NSString stringWithFormat:@"%.4f %.4f\n",self.cursorScale,self.cursorHue];
            if(self.engine.running) write(self.engineInput.fileHandleForWriting.fileDescriptor,line.UTF8String,strlen(line.UTF8String));
            return;
        }
        if(![m[@"width"] isKindOfClass:NSNumber.class] || ![m[@"height"] isKindOfClass:NSNumber.class]) return;
        NSInteger w=[m[@"width"] integerValue], h=[m[@"height"] integerValue];
        // Same finite tile-map capacity as the production receiver; reject before allocating.
        if(w<640 || h<360 || w>8192 || h>8192 ||
           ((w+SHARP_TILE_SIZE-1)/SHARP_TILE_SIZE)*((h+SHARP_TILE_SIZE-1)/SHARP_TILE_SIZE)>SHARP_HYBRID_MAX_TILES) {
            [self send:@{@"command":@"error",@"reason":@"Unsupported resolution"}]; return;
        }
        self.peerName=m[@"peerName"]; [self startEngineWidth:w height:h]; return;
    }
    if([cmd isEqual:@"benchmark-scene"]) {
        self.benchmarkScene=self.engine.running && [m[@"mode"] isKindOfClass:NSString.class] ? m[@"mode"] : nil; return;
    }
    if([cmd isEqual:@"benchmark-stop"]) { self.benchmarkScene=nil; return; }
    if([cmd isEqual:@"audio-stop"]) { self.audioToken=nil; [self.audio stop]; self.audio=nil; return; }
    if([cmd isEqual:@"audio-start"] && self.engine.running && [m[@"audioToken"] isKindOfClass:NSString.class] &&
       [[NSUUID alloc] initWithUUIDString:m[@"audioToken"]]) {
        [self.audio stop]; NSString *token=m[@"audioToken"]; self.audioToken=token;
        __weak ReceiverApp *weak=self;
        self.audio=[[SharpAudio alloc] initWithStatus:^(NSString *state){
            ReceiverApp *s=weak; if(!s || ![s.audioToken isEqual:token]) return;
            [s record:[@"Audio " stringByAppendingString:state]];
            if([state isEqual:@"ready"]) [s send:@{@"command":@"audio-ready",@"audioToken":token}];
            else if(![state isEqual:@"active"]) {
                [s.audio stop]; s.audio=nil; s.audioToken=nil; [s send:@{@"command":@"audio-stop"}];
            }
        }];
        [self.audio receiveOn:self.localIP token:token];
    }
}
- (void)startEngineWidth:(NSInteger)width height:(NSInteger)height {
    [self stopEngine]; NSTask *previous=self.retiringEngine;
    // Do not race a previous helper for the UDP port during a resolution change.
    if(previous.running) {
        __weak ReceiverApp *weak=self; NSInputStream *connection=self.input; NSUInteger generation=self.generation;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            [previous waitUntilExit]; dispatch_async(dispatch_get_main_queue(),^{
                if(weak.generation==generation && weak.input==connection && connection && !weak.sleeping)
                    [weak startEngineWidth:width height:height];
            });
        }); return;
    }
    NSTask *task=[NSTask new]; self.engine=task; self.starting=YES;
    NSString *bundle=NSBundle.mainBundle.bundlePath;
    task.launchPath=[bundle stringByAppendingPathComponent:@"Contents/Helpers/SharpReceiver"];
    task.arguments=@[@"--bind",self.localIP,@"--port",@"49172",@"--width",@(width).stringValue,@"--height",@(height).stringValue,
        @"--video-texture-mode",@"nv12",@"--cursor-dir",[bundle stringByAppendingPathComponent:@"Contents/Resources/Cursors"],@"--fullscreen",@"--keep-open"];
    NSMutableDictionary *env=[NSProcessInfo.processInfo.environment mutableCopy];
    [env addEntriesFromDictionary:@{@"SHARP_SKIP_H264_CHECKSUM":@"1",@"SHARP_NET_DRAIN_PACKET_BUDGET":@"2048",
        @"SHARP_NET_DRAIN_TIME_BUDGET_NS":@"2000000",@"SHARP_SHARPEN":@"0",@"SHARP_CURSOR_CONTROL":@"1",
        @"SHARP_CURSOR_SCALE":@(self.cursorScale).stringValue,@"SHARP_CURSOR_HUE":@(self.cursorHue).stringValue}];
    task.environment=env; self.engineInput=[NSPipe pipe]; task.standardInput=self.engineInput;
    fcntl(self.engineInput.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1);
    self.engineOutput=[NSPipe pipe]; task.standardOutput=self.engineOutput; task.standardError=self.engineOutput;
    self.engineLines=[NSMutableData new];
    __weak ReceiverApp *weak=self; __weak NSTask *weakTask=task;
    self.engineOutput.fileHandleForReading.readabilityHandler=^(NSFileHandle *handle){
        NSData *data=handle.availableData;
        if(!data.length) { handle.readabilityHandler=nil; return; }
        dispatch_async(dispatch_get_main_queue(),^{
            ReceiverApp *s=weak; if(!s || s.engine!=weakTask) return;
            [s.engineLines appendData:data];
            if(s.engineLines.length>65536) { [s disconnect:@"display output overflow"]; return; }
            while(s.engineLines.length) {
                const char *start=s.engineLines.bytes,*end=memchr(start,'\n',s.engineLines.length); if(!end) break;
                NSUInteger n=end-start;
                NSString *line=[[NSString alloc] initWithBytes:start length:n encoding:NSUTF8StringEncoding] ?: @"";
                [s.engineLines replaceBytesInRange:NSMakeRange(0,n+1) withBytes:NULL length:0];
                [s record:line];
                if(s.benchmarkScene) [s send:@{@"command":@"benchmark-line",@"mode":s.benchmarkScene,@"benchmarkLine":line}];
                if(s.starting && [line containsString:@"m1-display-recv bind="]) {
                    s.starting=NO; [s updateActivities];
                    [s send:@{@"command":@"ready",@"receiverIP":s.localIP}];
                    [s status:@"Connected" detail:s.peerName]; [s.window orderOut:nil];
                    [[NSRunningApplication runningApplicationWithProcessIdentifier:s.engine.processIdentifier]
                        activateWithOptions:NSApplicationActivateIgnoringOtherApps];
                }
            }
        });
    };
    task.terminationHandler=^(NSTask *ended){ dispatch_async(dispatch_get_main_queue(),^{
        ReceiverApp *s=weak; if(!s || s.engine!=ended) return;
        [s record:[NSString stringWithFormat:@"Receiver exited %d",ended.terminationStatus]];
        [s send:@{@"command":@"stop",@"sharingEnabled":@YES}]; [s stopEngine];
        [s status:@"Display stopped" detail:@"Click Resume to try again. Open report if this was unexpected."];
        s.resumeButton.hidden = NO;
        [s.window orderFront:nil];
    }); };
    NSError *error=nil;
    if(![task launchAndReturnError:&error]) {
        [self record:error.description]; [self disconnect:@"display could not start"];
        [self status:@"Could not start the display" detail:@"Open report from the Sharp Receiver menu."]; return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        ReceiverApp *s=weak; if(s.engine==weakTask && s.starting) {
            [s disconnect:@"display startup timed out"];
            [s status:@"Could not start the display" detail:@"Open report from the Sharp Receiver menu."];
        }
    });
}
- (void)willSleep:(NSNotification *)note {
    (void)note; self.sleeping=YES; [self send:@{@"command":@"sleeping"}]; [self disconnect:@"this Mac is going to sleep"];
    [self.service stop]; self.service=nil;
    if(self.listenerSource) { dispatch_source_cancel(self.listenerSource); self.listenerSource=nil; }
}
- (void)didWake:(NSNotification *)note { (void)note; self.sleeping=NO; [self startListener]; }
- (void)applicationWillTerminate:(NSNotification *)note {
    (void)note; self.terminating=YES; [self send:@{@"command":@"stop",@"sharingEnabled":@NO}];
    [self disconnect:@"quit"]; [self.service stop]; [self.timer invalidate]; [self.log synchronizeFile];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app=NSApplication.sharedApplication;
        ReceiverApp *delegate=[ReceiverApp new]; app.delegate=delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular]; [app run];
    }
    return 0;
}
