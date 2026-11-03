// Claude Buddy.app's Dock menu: its "Check for Updates..." runs Buddy's own update check.
//
// Right-clicking the app in the Dock shows the engine's menu (Hammerspoon's), and its
// "Check for Updates..." belongs to the engine's updater, Sparkle. The app switches that
// updater off (it would put plain Hammerspoon back over Buddy), so the item could only
// say "You must specify the URL of the appcast...". Lua can't reach that menu, so app.lua
// builds this small library (app/dockmenu.sh) and loads it with package.loadlib.
// claude_buddy_dock_menu() points every "Check for Updates..." item at an object of ours;
// a click posts the distributed notification "<bundle id>.checkForUpdates", which app.lua
// listens for. Nothing here holds on to Lua, so a reload can't leave it pointing at a
// closed Lua state.

#import <Cocoa/Cocoa.h>

// From the engine's Lua (LuaSkin), looked up when the library loads (-Wl,-U).
extern void lua_pushinteger(void *L, long long n);

@interface ClaudeBuddyDockMenu : NSObject
@property (copy) NSString *note;
@end

@implementation ClaudeBuddyDockMenu
- (void)checkForUpdates:(id)sender {
  [[NSDistributedNotificationCenter defaultCenter] postNotificationName:self.note object:nil
                                                               userInfo:nil deliverImmediately:YES];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item { return YES; }
@end

static ClaudeBuddyDockMenu *helper;

// Every "Check for Updates..." in menu and its submenus now asks us; how many there are.
static long long retarget(NSMenu *menu, int depth) {
  if (!menu || depth > 4) return 0;
  long long n = 0;
  for (NSMenuItem *item in menu.itemArray) {
    if (item.action == @selector(checkForUpdates:)) {
      item.target = helper;
      n++;
    }
    n += retarget(item.submenu, depth + 1);
  }
  return n;
}

// Called from Lua as a C function: no arguments; returns how many items it found (the
// Dock's and the app menu's can be the same one). Safe to call again after a reload.
int claude_buddy_dock_menu(void *L) {
  long long n = 0;
  @try {
    if (!helper) {
      helper = [ClaudeBuddyDockMenu new];
      NSString *me = NSBundle.mainBundle.bundleIdentifier ?: NSProcessInfo.processInfo.processName;
      helper.note = [me stringByAppendingString:@".checkForUpdates"];
    }
    id<NSApplicationDelegate> delegate = NSApp.delegate;
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *menus = [NSMutableArray array];
    if ([delegate respondsToSelector:@selector(applicationDockMenu:)]) {
      NSMenu *dock = [delegate applicationDockMenu:NSApp];
      if (dock) [menus addObject:dock];
    }
    if (NSApp.mainMenu) [menus addObject:NSApp.mainMenu];
    for (NSMenu *menu in menus) {
      NSValue *key = [NSValue valueWithNonretainedObject:menu];
      if ([seen containsObject:key]) continue;
      [seen addObject:key];
      n += retarget(menu, 0);
    }
  } @catch (NSException *e) {
    NSLog(@"Claude Buddy dock menu: %@", e);
    n = -1;
  }
  lua_pushinteger(L, n);
  return 1;
}
