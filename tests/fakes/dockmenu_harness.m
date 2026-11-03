// A stand-in for Claude Buddy.app's engine, for tests/test_dock_menu.py: an app delegate
// whose Dock menu has "Reload Config" and "Check for Updates..." (wired to a fake
// updater, as the engine wires it to Sparkle), plus an app menu with its own
// "Check for Updates...". It loads app/dockmenu.dylib, calls it twice (a reload), clicks
// the Dock item and prints what happened as JSON.
// usage: dockmenu_harness <dockmenu.dylib>

#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

// The engine's Lua stands in here: the library hands its count to lua_pushinteger.
static long long pushed = -2;
void lua_pushinteger(void *L, long long n) { (void)L; pushed = n; }

@interface FakeUpdater : NSObject
@property int calls;
@end
@implementation FakeUpdater
- (void)checkForUpdates:(id)sender { self.calls++; }
- (void)reloadConfig:(id)sender {}
@end

@interface FakeDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSMenu *menuBarMenu;
@end
@implementation FakeDelegate
- (NSMenu *)applicationDockMenu:(NSApplication *)sender { return self.menuBarMenu; }
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) return 2;
    [NSApplication sharedApplication];
    FakeUpdater *sparkle = [FakeUpdater new];
    FakeDelegate *delegate = [FakeDelegate new];
    NSMenu *dock = [[NSMenu alloc] initWithTitle:@"dock"];
    NSMenuItem *reload = [dock addItemWithTitle:@"Reload Config" action:@selector(reloadConfig:) keyEquivalent:@""];
    reload.target = sparkle;
    NSMenuItem *check = [dock addItemWithTitle:@"Check for Updates..." action:@selector(checkForUpdates:) keyEquivalent:@""];
    check.target = sparkle;
    delegate.menuBarMenu = dock;
    NSApp.delegate = delegate;
    NSMenu *main = [NSMenu new];
    NSMenuItem *appItem = [main addItemWithTitle:@"App" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [NSMenu new];
    NSMenuItem *check2 = [appMenu addItemWithTitle:@"Check for Updates..." action:@selector(checkForUpdates:) keyEquivalent:@""];
    check2.target = sparkle;
    appItem.submenu = appMenu;
    NSApp.mainMenu = main;

    void *lib = dlopen(argv[1], RTLD_NOW);
    if (!lib) { printf("{\"error\": \"%s\"}\n", dlerror()); return 1; }
    int (*open)(void *) = (int (*)(void *))dlsym(lib, "claude_buddy_dock_menu");
    if (!open) { printf("{\"error\": \"no claude_buddy_dock_menu\"}\n"); return 1; }
    int results = open((void *)1);
    long long first = pushed;
    open((void *)1);
    long long again = pushed;

    __block int heard = 0;
    NSString *note = [NSProcessInfo.processInfo.processName stringByAppendingString:@".checkForUpdates"];
    [[NSDistributedNotificationCenter defaultCenter] addObserverForName:note object:nil queue:nil
                                                             usingBlock:^(NSNotification *n) { heard++; }];
    BOOL enabled = [(id)check.target respondsToSelector:@selector(validateMenuItem:)]
        ? [(id)check.target validateMenuItem:check] : YES;
    BOOL sent = [NSApp sendAction:check.action to:check.target from:check];
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!heard && until.timeIntervalSinceNow > 0) {
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    printf("{\"results\": %d, \"found\": %lld, \"found_again\": %lld, \"retargeted\": %s, "
           "\"app_menu_too\": %s, \"reload_untouched\": %s, \"enabled\": %s, \"sent\": %s, "
           "\"sparkle_calls\": %d, \"heard\": %d}\n",
           results, first, again, check.target != sparkle ? "true" : "false",
           check2.target == check.target ? "true" : "false", reload.target == sparkle ? "true" : "false",
           enabled ? "true" : "false", sent ? "true" : "false", sparkle.calls, heard);
  }
  return 0;
}
