/* Native iOS menu sheet.
 *
 * frontend/ui/widget/nativetouchmenu.lua keeps KOReader's menu logic and
 * sends each menu level here as a JSON snapshot. This file only displays
 * snapshots and queues what the user did: Lua is never called from here,
 * since Lua is itself running further down the stack, pumping the runloop.
 * It drains the queue with ko_ios_menu_poll() from a UIManager timer. */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <stdbool.h>

UIViewController *ko_ios_top_view_controller(void);

enum {
    KO_MENU_EV_NONE = 0,
    KO_MENU_EV_SELECT = 1,
    KO_MENU_EV_HOLD = 2,
    KO_MENU_EV_BACK = 3,
    KO_MENU_EV_TAB = 4,
    KO_MENU_EV_DISMISS = 5,
};

static NSMutableArray<NSArray<NSNumber *> *> *g_events = nil;
static UINavigationController *g_nav = nil;
static id g_delegate = nil;
static NSInteger g_lua_depth = 0;
static NSInteger g_tab = -1;
static BOOL g_want_visible = NO;
static BOOL g_transitioning = NO;

static void ko_menu_post(int type, int value, int depth) {
    @synchronized (g_events) {
        [g_events addObject:@[ @(type), @(value), @(depth) ]];
    }
}

@interface KOMenuController : UITableViewController
@property (nonatomic) NSInteger depth;
@property (nonatomic) NSInteger scrollTo;
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sections;
- (void)setItems:(NSArray<NSDictionary *> *)items;
@end

@implementation KOMenuController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(donePressed)];
    [self.tableView addGestureRecognizer:[[UILongPressGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(rowHeld:)]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self applyScroll];
}

/* The sheet is well clear of the camera that the window's side inset is for, so
 * that only keeps a margin matching the other side's. */
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    static const CGFloat margin = 16;
    UIEdgeInsets insets = self.view.safeAreaInsets;
    UIEdgeInsets additional = self.additionalSafeAreaInsets;
    if (insets.left > margin) {
        additional.left -= insets.left - margin;
    }
    if (insets.right > margin) {
        additional.right -= insets.right - margin;
    }
    if (!UIEdgeInsetsEqualToEdgeInsets(additional, self.additionalSafeAreaInsets)) {
        self.additionalSafeAreaInsets = additional;
    }
}

/* Separators in KOReader's menus become grouped table sections. */
- (void)setItems:(NSArray<NSDictionary *> *)items {
    NSMutableArray *sections = [NSMutableArray array];
    NSMutableArray *section = [NSMutableArray array];
    for (NSDictionary *item in items) {
        [section addObject:item];
        if ([item[@"sep"] boolValue]) {
            [sections addObject:section];
            section = [NSMutableArray array];
        }
    }
    if (section.count > 0) {
        [sections addObject:section];
    }
    self.sections = sections;
    [self.tableView reloadData];
    [self applyScroll];
}

- (void)applyScroll {
    if (self.scrollTo <= 0 || !self.view.window) {
        return;
    }
    [self.sections enumerateObjectsUsingBlock:^(NSArray *section, NSUInteger s, BOOL *stop) {
        [section enumerateObjectsUsingBlock:^(NSDictionary *item, NSUInteger r, BOOL *stop2) {
            if ([item[@"i"] integerValue] == self.scrollTo) {
                [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:r inSection:s]
                                      atScrollPosition:UITableViewScrollPositionMiddle
                                              animated:NO];
                *stop2 = YES;
                *stop = YES;
            }
        }];
    }];
    self.scrollTo = 0;
}

- (NSDictionary *)itemAtIndexPath:(NSIndexPath *)indexPath {
    return self.sections[indexPath.section][indexPath.row];
}

- (void)donePressed {
    ko_menu_post(KO_MENU_EV_DISMISS, 0, (int)self.depth);
}

- (void)switchToggled:(UISwitch *)sender {
    ko_menu_post(KO_MENU_EV_SELECT, (int)sender.tag, (int)self.depth);
}

- (void)rowHeld:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:[recognizer locationInView:self.tableView]];
    if (indexPath) {
        ko_menu_post(KO_MENU_EV_HOLD, [[self itemAtIndexPath:indexPath][@"i"] intValue], (int)self.depth);
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const reuse_id = @"item";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse_id];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse_id];
        cell.textLabel.numberOfLines = 0;
    }
    NSDictionary *item = [self itemAtIndexPath:indexPath];
    BOOL enabled = [item[@"enabled"] boolValue];
    BOOL checked = [item[@"checked"] boolValue];
    BOOL submenu = [item[@"sub"] boolValue];

    cell.textLabel.text = item[@"text"];
    cell.textLabel.textColor = enabled ? UIColor.labelColor : UIColor.secondaryLabelColor;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.imageView.image = nil;

    if (submenu) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (checked) {
            cell.imageView.image = [UIImage systemImageNamed:@"checkmark"];
        }
    } else if ([item[@"radio"] boolValue]) {
        cell.accessoryType = checked ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else if ([item[@"checkable"] boolValue]) {
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = checked;
        toggle.enabled = enabled;
        toggle.tag = [item[@"i"] integerValue];
        [toggle addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (checked) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = [self itemAtIndexPath:indexPath];
    if ([item[@"enabled"] boolValue]) {
        ko_menu_post(KO_MENU_EV_SELECT, [item[@"i"] intValue], (int)self.depth);
    }
}

@end

static void ko_menu_reconcile(void);

@interface KOMenuDelegate : NSObject <UINavigationControllerDelegate, UIAdaptivePresentationControllerDelegate>
@end

@implementation KOMenuDelegate

/* The back button or swipe popped a level: tell Lua which one we're on. */
- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    NSInteger depth = (NSInteger)navigationController.viewControllers.count - 1;
    if (depth < g_lua_depth) {
        g_lua_depth = depth;
        ko_menu_post(KO_MENU_EV_BACK, 0, (int)depth);
    }
}

/* Only called when the user swipes the sheet away or taps outside it. */
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    g_want_visible = NO;
    ko_menu_post(KO_MENU_EV_DISMISS, 0, 0);
}

- (void)tabChanged:(UISegmentedControl *)sender {
    ko_menu_post(KO_MENU_EV_TAB, (int)sender.selectedSegmentIndex + 1, 0);
}

@end

static void ko_menu_apply(NSDictionary *snapshot) {
    if (!g_nav) {
        g_delegate = [[KOMenuDelegate alloc] init];
        g_nav = [[UINavigationController alloc] initWithRootViewController:[[KOMenuController alloc] init]];
        g_nav.delegate = g_delegate;
        g_nav.modalPresentationStyle = UIModalPresentationPageSheet;
    }
    NSInteger depth = [snapshot[@"depth"] integerValue];
    NSInteger tab = [snapshot[@"tab"] integerValue];
    BOOL same_tab = tab == g_tab;
    g_lua_depth = depth;
    g_tab = tab;

    NSMutableArray *stack = [g_nav.viewControllers mutableCopy];
    if (!same_tab) {
        [stack removeObjectsInRange:NSMakeRange(1, stack.count - 1)];
    }
    while ((NSInteger)stack.count > depth + 1) {
        [stack removeLastObject];
    }
    while ((NSInteger)stack.count <= depth) {
        [stack addObject:[[KOMenuController alloc] init]];
    }

    KOMenuController *top = stack.lastObject;
    top.depth = depth;
    top.title = snapshot[@"title"];
    top.scrollTo = [snapshot[@"scroll_to"] integerValue];
    [top setItems:snapshot[@"items"]];

    KOMenuController *root = stack.firstObject;
    UISegmentedControl *tabs = (UISegmentedControl *)root.navigationItem.titleView;
    NSArray<NSString *> *symbols = snapshot[@"tabs"];
    if (!tabs) {
        tabs = [[UISegmentedControl alloc] init];
        [tabs addTarget:g_delegate action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
        root.navigationItem.titleView = tabs;
    }
    if (tabs.numberOfSegments != (NSInteger)symbols.count) {
        [tabs removeAllSegments];
        [symbols enumerateObjectsUsingBlock:^(NSString *symbol, NSUInteger i, BOOL *stop) {
            [tabs insertSegmentWithImage:[UIImage systemImageNamed:symbol] atIndex:i animated:NO];
        }];
        [tabs sizeToFit];
    }
    tabs.selectedSegmentIndex = tab - 1;

    g_nav.overrideUserInterfaceStyle = [snapshot[@"dark"] boolValue]
        ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified;
    [g_nav setViewControllers:stack animated:same_tab && g_nav.viewIfLoaded.window != nil];
}

/* Presenting and dismissing can't overlap, so changes that arrive during a
 * transition wait for it to end. */
static void ko_menu_reconcile(void) {
    if (g_transitioning || !g_nav) {
        return;
    }
    BOOL presented = g_nav.presentingViewController != nil;
    if (g_want_visible == presented) {
        return;
    }
    void (^done)(void) = ^{
        g_transitioning = NO;
        ko_menu_reconcile();
    };
    if (presented) {
        g_transitioning = YES;
        [g_nav dismissViewControllerAnimated:YES completion:done];
        return;
    }
    UIViewController *presenter = ko_ios_top_view_controller();
    if (!presenter) {
        return;
    }
    UISheetPresentationController *sheet = g_nav.sheetPresentationController;
    sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent,
                       UISheetPresentationControllerDetent.largeDetent ];
    sheet.prefersGrabberVisible = YES;
    g_nav.presentationController.delegate = g_delegate;
    g_transitioning = YES;
    [presenter presentViewController:g_nav animated:YES completion:done];
}

void ko_ios_menu_update(const char *json) {
    NSData *data = [NSData dataWithBytes:json length:strlen(json)];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        NSDictionary *snapshot = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (![snapshot isKindOfClass:[NSDictionary class]]) {
            NSLog(@"ko_ios_menu_update: bad snapshot: %@", error);
            return;
        }
        ko_menu_apply(snapshot);
    });
}

void ko_ios_menu_set_visible(bool visible) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_want_visible = visible;
        ko_menu_reconcile();
    });
}

void ko_ios_menu_close(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_want_visible = NO;
        g_tab = -1;
        @synchronized (g_events) {
            [g_events removeAllObjects];
        }
        ko_menu_reconcile();
    });
}

bool ko_ios_menu_transitioning(void) {
    return g_transitioning;
}

/* Returns the next event type (KO_MENU_EV_NONE when there's none). */
int ko_ios_menu_poll(int *value, int *depth) {
    @synchronized (g_events) {
        if (g_events.count == 0) {
            return KO_MENU_EV_NONE;
        }
        NSArray<NSNumber *> *event = g_events.firstObject;
        [g_events removeObjectAtIndex:0];
        *value = event[1].intValue;
        *depth = event[2].intValue;
        return event[0].intValue;
    }
}

__attribute__((constructor)) static void ko_menu_init_events(void) {
    g_events = [NSMutableArray array];
}
