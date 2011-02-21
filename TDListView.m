//  vim: expandtab:ts=4:sw=4
//  Copyright 2009 Todd Ditchendorf
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

#import "TDListView.h"
#import "TDListItem.h"
#import "TDScrollView.h"
#import "NSEvent+TDAdditions.h"
#import "TDListItemQueue.h"

#define EXCEPTION_NAME @"TDListViewDataSourceException"
#define DEFAULT_ITEM_EXTENT 44
#define DRAG_RADIUS 22

NSString *const TDListItemPboardType = @"TDListItemPboardType";
static const CGFloat kRowMutationAnimationDuration = 0.5;

typedef NSRect(^ListViewCalculateFrameBlock)(NSRect itemFrame, NSUInteger index);
typedef void(^ListViewVisibleItemBlock)(TDListItem *item, NSUInteger index);

@interface NSToolbarPoofAnimator
+ (void)runPoofAtPoint:(NSPoint)p;
@end

@interface TDListItem ()
@property (nonatomic, assign) NSUInteger index;
@end

@interface TDListView ()
- (void)setUp;
- (void)layoutItems;
- (void)layoutItemsWhileDragging;
- (NSUInteger)indexForItemWhileDraggingAtPoint:(NSPoint)p;
- (TDListItem *)itemAtVisibleIndex:(NSUInteger)i;
- (NSUInteger)visibleIndexForItemAtPoint:(NSPoint)p;
- (TDListItem *)itemWhileDraggingAtIndex:(NSInteger)i;
- (void)draggingSourceDragDidEnd;
- (void)unsuppressLayout;
- (void)handleRightClickEvent:(NSEvent *)evt;
- (void)displayContextMenu:(NSTimer *)t;
- (void)handleDoubleClickAtIndex:(NSUInteger)i;
- (BOOL)isFrameVisible:(NSRect)frame;
- (void)updateFrameWithExtent:(NSNumber *)extentNumber;
- (CGFloat)layoutItemsWithCalculateFrameBlock:(ListViewCalculateFrameBlock)calculateFrameBlock visibleItemBlock:(ListViewVisibleItemBlock)visibleItemBlock;
- (CGFloat)totalExtentForRowsInIndexSet:(NSIndexSet *)indexSet;
- (CGFloat)extentForRect:(NSRect)rect;
- (void)appendItemsToFillExtentFromIndexSet:(NSIndexSet *)indexSet;

@property (nonatomic, retain) NSMutableArray *items;
@property (nonatomic, retain) NSMutableArray *unusedItems;
@property (nonatomic, retain) TDListItemQueue *queue;
@property (nonatomic, retain) NSEvent *lastMouseDownEvent;
@property (nonatomic, retain) NSMutableArray *itemFrames;
@property (nonatomic, assign) NSPoint dragOffset;
@end

@implementation TDListView

- (id)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {        
        [self setUp];
    } 
    return self;
}


- (id)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        [self setUp];
    }
    return self;
}


- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];
}


- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    self.scrollView = nil;
    self.dataSource = nil;
    self.delegate = nil;
    self.backgroundColor = nil;
    self.items = nil;
    self.unusedItems = nil;
    self.queue = nil;
    self.lastMouseDownEvent = nil;
    self.itemFrames = nil;
    self.selectedIndexes = nil;
    [super dealloc];
}


- (void)awakeFromNib {

}


- (void)setUp {
    self.items = [NSMutableArray array];
    self.unusedItems = [NSMutableArray array];
    
    self.selectedIndexes = [NSMutableIndexSet indexSet];
    self.backgroundColor = [NSColor whiteColor];
    self.itemExtent = DEFAULT_ITEM_EXTENT;
    
    self.queue = [[[TDListItemQueue alloc] init] autorelease];
    
    self.displaysClippedItems = YES;
    
    draggingVisibleIndex = NSNotFound;
    draggingIndex = NSNotFound;
    [self setDraggingSourceOperationMask:NSDragOperationEvery forLocal:YES];
    [self setDraggingSourceOperationMask:NSDragOperationNone forLocal:NO];    
}


#pragma mark -
#pragma mark Public

- (void)reloadData {
    [self layoutItems];
    [self setNeedsDisplay:YES];
}


- (TDListItem *)dequeueReusableItemWithIdentifier:(NSString *)s {
    TDListItem *item = [queue dequeueWithIdentifier:s];
    [item prepareForReuse];
    return item;
}


- (NSUInteger)visibleIndexForItemAtPoint:(NSPoint)p {
    NSUInteger i = 0;
    for (TDListItem *item in items) {
        if (NSPointInRect(p, [item frame])) {
            return i;
        }
        i++;
    }
    return NSNotFound;
}


- (NSUInteger)indexForItemAtPoint:(NSPoint)p {
    BOOL variableExtent = (delegate && [delegate respondsToSelector:@selector(listView:extentForItemAtIndex:)]);
    CGFloat n = 0;
    CGFloat w = NSWidth([self frame]);
    CGFloat h = NSHeight([self frame]);

    NSUInteger count = [dataSource numberOfItemsInListView:self];
    NSUInteger i = 0;
    for ( ; i < count; i++) {
        CGFloat extent = floor(variableExtent ? [delegate listView:self extentForItemAtIndex:i] : itemExtent);
        NSRect itemFrame;
        if (self.isPortrait) {
            itemFrame = NSMakeRect(0, n, w, extent);
        } else {
            itemFrame = NSMakeRect(n, 0, extent, h);
        }
        if (NSPointInRect(p, itemFrame)) {
            return i;
        }
        n += extent;
    }
    
    return NSNotFound;
}


- (TDListItem *)itemAtIndex:(NSUInteger)i {
    for (TDListItem *item in items) {
        if (item.index == i) {
            return item;
        }
    }
    return nil; //[dataSource listView:self itemAtIndex:i]; //[self itemAtVisibleIndex:i];
}


- (TDListItem *)itemAtVisibleIndex:(NSUInteger)i {
    if (i >= [items count]) return nil;
    
    return [items objectAtIndex:i];
}


- (NSRect)frameForItemAtIndex:(NSUInteger)i {
    CGFloat extent = 0;

    NSUInteger j = 0;
    for ( ; j < i; j++) {
        extent += [delegate listView:self extentForItemAtIndex:j];
    }
    
    CGFloat x, y, w, h;
    NSRect bounds = [self bounds];
    
    if (self.isPortrait) {
        x = 0; y = extent;
        w = bounds.size.width;
        h = [delegate listView:self extentForItemAtIndex:i];
    } else {
        x = extent; y = 0;
        w = [delegate listView:self extentForItemAtIndex:i];
        h = bounds.size.height;
    }
    NSRect r = NSMakeRect(x, y, w, h);
    return r;
}


- (BOOL)isPortrait {
    return TDListViewOrientationPortrait == orientation;
}


- (BOOL)isLandscape {
    return TDListViewOrientationLandscape == orientation;
}


- (void)insertRowsAtIndexesWithAnimation:(NSIndexSet *)indexSet {
    // Add items which are immediately off-screen by appending to the self.items property until there are enough items present to satisfy the shift extent
    [self appendItemsToFillExtentFromIndexSet:indexSet];

    // Place all cells in their original positions.
    // Then perform a second pass to animate the new cells in and shift the old cells down.
    __block CGFloat shiftExtent = 0;
    ListViewCalculateFrameBlock calculateFrameBlock = ^ NSRect (NSRect itemFrame, NSUInteger index) {
        BOOL isNewlyInserted = [indexSet containsIndex:index];
        if (isNewlyInserted) {
            // Running total of how much we have shifted everything else down
            shiftExtent += itemFrame.size.height;
        }

        NSRect newFrame;
        if (self.isPortrait) {
            newFrame = NSMakeRect(itemFrame.origin.x, itemFrame.origin.y - shiftExtent, itemFrame.size.width, itemFrame.size.height);
        } else {
            newFrame = NSMakeRect(itemFrame.origin.x - shiftExtent, itemFrame.origin.y, itemFrame.size.width, itemFrame.size.height);
        }

        return newFrame;
    };

    __block BOOL firstItemVisible = NO;
    ListViewVisibleItemBlock visibleItemBlock = ^(TDListItem *item, NSUInteger index) {
        BOOL isNewlyInserted = [indexSet containsIndex:index];
        if (isNewlyInserted) {
            [item setAlphaValue:0.0];

            if (!firstItemVisible) {
                firstItemVisible = [indexSet firstIndex] == index;
            }
        }
    };

    CGFloat extent = [self layoutItemsWithCalculateFrameBlock:calculateFrameBlock visibleItemBlock:visibleItemBlock];

    if (firstItemVisible) {
        [NSAnimationContext beginGrouping];
        [[NSAnimationContext currentContext] setDuration:kRowMutationAnimationDuration];
        // Second pass animating everything into place
        for (int i=0; i<[self.items count]; i++) {
            TDListItem *item = [self.items objectAtIndex:i];
            NSRect frame = [self frameForItemAtIndex:i];
            if (!NSEqualRects(item.frame, frame)) {
                [[item animator] setFrame:frame];
                [[item animator] setAlphaValue:1.0];
            }
        }
        [NSAnimationContext endGrouping];
    }

    if (extent) {
        [self performSelector:@selector(updateFrameWithExtent:) withObject:[NSNumber numberWithFloat:extent] afterDelay:kRowMutationAnimationDuration];
    }
}


- (void)deleteRowsAtIndexesWithAnimation:(NSIndexSet *)indexSet {
    // Add items which are immediately off-screen by appending to the self.items property until there are enough items present to satisfy the shift extent
    [self appendItemsToFillExtentFromIndexSet:indexSet];

    // Animate items upwards and close in on the gaps left by the deleted items
    [NSAnimationContext beginGrouping];
    [[NSAnimationContext currentContext] setDuration:kRowMutationAnimationDuration];
    NSUInteger numPriorDeletedItems = 0;
    NSRect previousNonDeletedItemFrame = [[self.items objectAtIndex:0] frame];
    for (TDListItem *item in self.items) {
        // Remove deleted items
        if ([indexSet containsIndex:item.index]) {
            // Move deleted items up to the last non-deleted item
            [[item animator] setFrame:previousNonDeletedItemFrame];
            [[item animator] setAlphaValue:0];
            numPriorDeletedItems++;
        } else {
            item.index -= numPriorDeletedItems;
            // Position items where they are supposed to go
            NSRect frame = [self frameForItemAtIndex:item.index];
            [[item animator] setFrame:frame];
            [item setAlphaValue:1.0];
            previousNonDeletedItemFrame = frame;
        }
    }
    [NSAnimationContext endGrouping];

    [self performSelector:@selector(layoutItems) withObject:nil afterDelay:kRowMutationAnimationDuration];
}


#pragma mark -
#pragma mark Notifications

- (void)viewBoundsChanged:(NSNotification *)n {
    // if this returns false, the view hierarchy is being torn down. 
    // don't try to layout in that case cuz it crashes on Leopard
    if ([[n object] superview] && dataSource) {
        [self layoutItems];
    }
}


#pragma mark -
#pragma mark NSView

- (void)viewWillMoveToSuperview:(NSView *)newSuperview {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    
    NSView *oldSuperview = [self superview];
    if (oldSuperview) {
        [nc removeObserver:self name:NSViewBoundsDidChangeNotification object:oldSuperview];
    }

    if (newSuperview) {
        [nc addObserver:self selector:@selector(viewBoundsChanged:) name:NSViewBoundsDidChangeNotification object:newSuperview];
    }
}


- (void)resizeSubviewsWithOldSize:(NSSize)oldBoundsSize {
    [self layoutItems];
}


- (BOOL)isFlipped {
    return YES;
}


- (BOOL)acceptsFirstResponder {
    return YES;
}


- (void)drawRect:(NSRect)dirtyRect {
    [backgroundColor set];
    NSRectFill(dirtyRect);
}


- (void)selectItemAtIndex:(NSUInteger)index cumulative:(BOOL)isCumulative {
    if (NSNotFound != index) {
        if (delegate && [delegate respondsToSelector:@selector(listView:willSelectItemAtIndex:)]) {
            if (NSNotFound == [delegate listView:self willSelectItemAtIndex:index]) {
                return;
            }
        }

        if ([self.selectedIndexes containsIndex:index] && [self.selectedIndexes count] > 1) {
            // multiple selected and then a single item is clicked
            [self.selectedIndexes removeAllIndexes];
            [self.selectedIndexes addIndex:index];
        } else if ([self.selectedIndexes containsIndex:index]) {
            [self.selectedIndexes removeIndex:index];
        } else {
            if (!isCumulative) {
                [self.selectedIndexes removeAllIndexes];
            }
            [self.selectedIndexes addIndex:index];
        }

        if ([self.selectedIndexes count] && delegate && [delegate respondsToSelector:@selector(listView:didSelectItemsAtIndexes:)]) {
            [delegate listView:self didSelectItemsAtIndexes:self.selectedIndexes];
        }
    } else {
        // empty area was clicked so deselect all
        [self.selectedIndexes removeAllIndexes];
    }

    [self reloadData];
}


- (void)selectItemsInRange:(NSRange)range {
    [self.selectedIndexes removeAllIndexes];
    for (int i=range.location; i<=range.location + range.length; i++) {
        if (delegate && [delegate respondsToSelector:@selector(listView:willSelectItemAtIndex:)]) {
            if (NSNotFound == [delegate listView:self willSelectItemAtIndex:i]) {
                continue;
            }
        }
        [self selectItemAtIndex:i cumulative:YES];
    }

    [self reloadData];
}


- (void)clearAllSelections {
    [self.selectedIndexes removeAllIndexes];
    [self reloadData];
}


#pragma mark -
#pragma mark NSResponder

- (void)rightMouseUp:(NSEvent *)evt {
    [self handleRightClickEvent:evt];
}


- (NSUInteger)indexForItemFromEvent:(NSEvent *)event {
    NSPoint locInWin = [event locationInWindow];
    NSPoint p = [self convertPoint:locInWin fromView:nil];
    return [self indexForItemAtPoint:p];
}


- (void)mouseDown:(NSEvent *)evt {
    NSPoint locInWin = [evt locationInWindow];
    NSPoint p = [self convertPoint:locInWin fromView:nil];
    NSUInteger i = [self indexForItemAtPoint:p];
    NSUInteger visibleIndex = [self visibleIndexForItemAtPoint:p];

    // handle right click
    if ([evt isControlKeyPressed] && 1 == [evt clickCount]) {
        [self handleRightClickEvent:evt];
        return;
    } else if ([evt isDoubleClick]) {
        [self handleDoubleClickAtIndex:i];
        return;
    }

    BOOL isCopy = [evt isOptionKeyPressed] && (NSDragOperationCopy & [self draggingSourceOperationMaskForLocal:YES]);

    // handle item selection
    if ([evt isShiftKeyPressed]) {
        // range selected
        NSUInteger lastEventIndex = [self indexForItemFromEvent:self.lastMouseDownEvent];
        NSUInteger location = lastEventIndex < i ? lastEventIndex : i;
        NSUInteger lastIndex = [self.items indexOfObject:[self.items lastObject]];
        if (lastEventIndex == NSNotFound) {
            lastEventIndex = lastIndex;
        }
        NSUInteger destination;
        if (i == NSNotFound) {
            destination = lastIndex;
        } else {
            destination = location == lastEventIndex ? i : lastEventIndex;
        }

        NSRange range = {location, destination - location};
        [self selectItemsInRange:range];
    } else {
        [self selectItemAtIndex:i cumulative:[evt isCommandKeyPressed]];
    }

    self.lastMouseDownEvent = evt;
    
    // this adds support for click-to-select-and-drag all in one click. 
    // otherwise you have to click once to select and then click again to begin a drag, which sux.
    BOOL withinDragRadius = YES;
        
    NSInteger radius = DRAG_RADIUS;
    NSRect r = NSMakeRect(locInWin.x - radius, locInWin.y - radius, radius * 2, radius * 2);
    
    while (withinDragRadius) {
        evt = [[self window] nextEventMatchingMask:NSLeftMouseUpMask|NSLeftMouseDraggedMask|NSPeriodicMask];
        
        switch ([evt type]) {
            case NSLeftMouseDragged:
                if (NSPointInRect([evt locationInWindow], r)) {
                    // still within drag radius tolerance. dont drag yet
                    break;
                }
                draggingIndex = i;
                draggingVisibleIndex = isCopy ? NSNotFound : visibleIndex;
                isDragSource = YES;
                [self mouseDragged:evt];
                withinDragRadius = NO;
                break;
            case NSLeftMouseUp:
                withinDragRadius = NO;
                [self draggingSourceDragDidEnd];
                [self mouseUp:evt];
                break;
            default:
                break;
        }
    }
}


- (void)handleRightClickEvent:(NSEvent *)evt {
    if (delegate && [delegate respondsToSelector:@selector(listView:contextMenuForItemAtIndex:)]) {
        NSTimer *timer = [NSTimer timerWithTimeInterval:0 
                                                 target:self 
                                               selector:@selector(displayContextMenu:) 
                                               userInfo:evt 
                                                repeats:NO];
        [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
    }
}


- (void)displayContextMenu:(NSTimer *)timer {
    if (delegate && [delegate respondsToSelector:@selector(listView:contextMenuForItemAtIndex:)]) {
        NSEvent *evt = [timer userInfo];
        
        NSPoint locInWin = [evt locationInWindow];
        NSPoint p = [self convertPoint:locInWin fromView:nil];
        NSUInteger i = [self indexForItemAtPoint:p];
        
        //if (NSNotFound == i || i >= [dataSource numberOfItemsInListView:self]) return;
        
        NSMenu *menu = [delegate listView:self contextMenuForItemAtIndex:i];
        if (menu) {
            NSEvent *click = [NSEvent mouseEventWithType:[evt type] 
                                                location:[evt locationInWindow]
                                           modifierFlags:[evt modifierFlags] 
                                               timestamp:[evt timestamp] 
                                            windowNumber:[evt windowNumber] 
                                                 context:[evt context]
                                             eventNumber:[evt eventNumber] 
                                              clickCount:[evt clickCount] 
                                                pressure:[evt pressure]];
            
            [NSMenu popUpContextMenu:menu withEvent:click forView:self];
        }
    }
    
    [timer invalidate];
}


- (void)handleDoubleClickAtIndex:(NSUInteger)i {
    if (NSNotFound == i) {
        if (delegate && [delegate respondsToSelector:@selector(listViewEmptyAreaWasDoubleClicked:)]) {
            [delegate listViewEmptyAreaWasDoubleClicked:self];
        }
    } else {
        if (delegate && [delegate respondsToSelector:@selector(listView:itemWasDoubleClickedAtIndex:)]) {
            [delegate listView:self itemWasDoubleClickedAtIndex:i];
        }
    }    
}


- (void)mouseDragged:(NSEvent *)evt {
    // have to get the image before calling any delegate methods... they may rearrange or remove views which would cause us to have the wrong image
    self.dragOffset = NSZeroPoint;
    NSImage *dragImg = nil;
    if (delegate && [delegate respondsToSelector:@selector(listView:draggingImageForItemAtIndex:withEvent:offset:)]) {
        dragImg = [delegate listView:self draggingImageForItemAtIndex:draggingIndex withEvent:lastMouseDownEvent offset:&dragOffset];
    } else {
        dragImg = [self draggingImageForItemAtIndex:draggingIndex withEvent:evt offset:&dragOffset];
    }
 
    BOOL canDrag = NO;
    BOOL slideBack = YES;
    if (draggingIndex != NSNotFound && delegate && [delegate respondsToSelector:@selector(listView:canDragItemAtIndex:withEvent:slideBack:)]) {
        canDrag = [delegate listView:self canDragItemAtIndex:draggingIndex withEvent:evt slideBack:&slideBack];
    }
    if (!canDrag) return;
    
    NSPasteboard *pboard = [NSPasteboard pasteboardWithName:NSDragPboard];
    [pboard declareTypes:[NSArray arrayWithObject:TDListItemPboardType] owner:self];
    
    canDrag = NO;
    if (/*NSNotFound != draggingVisibleIndex && */delegate && [delegate respondsToSelector:@selector(listView:writeItemAtIndex:toPasteboard:)]) {
        canDrag = [delegate listView:self writeItemAtIndex:draggingIndex toPasteboard:pboard];
    }
    if (!canDrag) return;
    
    [self.selectedIndexes removeAllIndexes];
    
    NSPoint p = [self convertPoint:[evt locationInWindow] fromView:nil];
    
    dragOffset.x = dragOffset.x - ([evt locationInWindow].x - [lastMouseDownEvent locationInWindow].x);
    dragOffset.y = dragOffset.y + ([evt locationInWindow].y - [lastMouseDownEvent locationInWindow].y);
    
    p.x -= dragOffset.x;
    p.y -= dragOffset.y;
    
    NSSize ignored = NSZeroSize;
    [self dragImage:dragImg at:p offset:ignored event:evt pasteboard:pboard source:self slideBack:slideBack];
}


#pragma mark -
#pragma mark DraggingSource

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal {
    return isLocal ? localDragOperationMask : nonLocalDragOperationMask;
}


- (void)setDraggingSourceOperationMask:(NSDragOperation)mask forLocal:(BOOL)localDestination {
    if (localDestination) {
        localDragOperationMask = mask;
    } else {
        nonLocalDragOperationMask = mask;
    }
}


- (BOOL)ignoreModifierKeysWhileDragging {
    return YES;
}


- (NSImage *)draggingImageForItemAtIndex:(NSInteger)i withEvent:(NSEvent *)evt offset:(NSPointPointer)dragImageOffset {
    TDListItem *item = [self itemAtIndex:i];
    if (dragImageOffset) {
        NSPoint p = [item convertPoint:[evt locationInWindow] fromView:nil];
        *dragImageOffset = NSMakePoint(p.x, p.y - NSHeight([item frame]));
    }

    return [item draggingImage];
}


- (void)draggedImage:(NSImage *)image endedAt:(NSPoint)endPointInScreen operation:(NSDragOperation)op {
    // screen origin is lower left
    endPointInScreen.x += dragOffset.x;
    endPointInScreen.y -= dragOffset.y;

    // window origin is lower left
    NSPoint endPointInWin = [[self window] convertScreenToBase:endPointInScreen];

    // get frame of visible portion of list view in window coords
    NSRect dropZone = [self convertRect:[self visibleRect] toView:nil];

    if (!NSPointInRect(endPointInWin, dropZone)) {
        if (delegate && [delegate respondsToSelector:@selector(listView:shouldRunPoofAt:forRemovedItemAtIndex:)]) {
            if ([delegate listView:self shouldRunPoofAt:endPointInScreen forRemovedItemAtIndex:draggingIndex]) {
                NSShowAnimationEffect(NSAnimationEffectPoof, endPointInScreen, NSZeroSize, nil, nil, nil);
            }
        }
    }

    [self layoutItems];

    [self draggingSourceDragDidEnd];
}


#pragma mark -
#pragma mark NSDraggingDestination

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)dragInfo {    
    delegateRespondsToValidateDrop = delegate && [delegate respondsToSelector:@selector(listView:validateDrop:proposedIndex:dropOperation:)];
    
    if (!itemFrames) {
        self.itemFrames = [NSMutableArray arrayWithCapacity:[items count]];
        for (TDListItem *item in items) {
            [itemFrames addObject:[NSValue valueWithRect:[item frame]]];
        }
    }
    
    NSPasteboard *pboard = [dragInfo draggingPasteboard];
    NSDragOperation srcMask = [dragInfo draggingSourceOperationMask];
    
    if ([[pboard types] containsObject:TDListItemPboardType]) {
        BOOL optPressed = [[[dragInfo draggingDestinationWindow] currentEvent] isOptionKeyPressed];
        
        if (optPressed && (srcMask & NSDragOperationCopy)) {
            return NSDragOperationCopy;
        } else if ((srcMask & NSDragOperationMove)) {
            return NSDragOperationMove;
        }
    }
    
    return NSDragOperationNone;
}


/* TODO if the destination responded to draggingEntered: but not to draggingUpdated: the return value from draggingEntered: should be used */
- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)dragInfo {
    if (!delegateRespondsToValidateDrop) {
        return NSDragOperationNone;
    }
    
    NSDragOperation dragOp = NSDragOperationNone;
    BOOL isDraggingListItem = (draggingVisibleIndex != NSNotFound || [[[dragInfo draggingPasteboard] types] containsObject:TDListItemPboardType]);
    
    NSPoint locInWin = [dragInfo draggingLocation];
    NSPoint locInList = [self convertPoint:locInWin fromView:nil];

    if (isDraggingListItem) {
        dropIndex = [self indexForItemWhileDraggingAtPoint:locInList];
    } else {
        dropIndex = [self indexForItemAtPoint:locInList];
    }
        
    NSUInteger itemCount = [items count];
    //if (dropIndex < 0 || NSNotFound == dropIndex) {// || dropIndex > itemCount) {
    if (NSNotFound == dropIndex || dropIndex > itemCount) {
        dropIndex = itemCount;
    }
    
    TDListItem *item = [self itemAtIndex:dropIndex];
    NSUInteger firstIndex = 0;
    if ([items count]) {
        firstIndex =  [[items objectAtIndex:0] index];
    }
    if (item) {
        dropVisibleIndex = [items indexOfObject:item];
        dropVisibleIndex += firstIndex;
    } else {
        dropVisibleIndex = firstIndex - (firstIndex - dropIndex);
    }

    dropIndex += firstIndex;
    item = [self itemWhileDraggingAtIndex:dropIndex];
    NSPoint locInItem = [item convertPoint:locInWin fromView:nil];

    NSRect itemBounds = [item bounds];
    NSRect front, back;
    
    if (self.isPortrait) {
        front = NSMakeRect(itemBounds.origin.x, itemBounds.origin.y, itemBounds.size.width, itemBounds.size.height / 3);
        back = NSMakeRect(itemBounds.origin.x, ceil(itemBounds.size.height * .66), itemBounds.size.width, itemBounds.size.height / 3);
    } else {
        front = NSMakeRect(itemBounds.origin.x, itemBounds.origin.y, itemBounds.size.width / 3, itemBounds.size.height);
        back = NSMakeRect(ceil(itemBounds.size.width * .66), itemBounds.origin.y, itemBounds.size.width / 3, itemBounds.size.height);
    }
    
    dropOp = TDListViewDropOn;
    if (isDraggingListItem) {
        if (NSPointInRect(locInItem, front)) {
            // if p is in the first 1/3 of the item change the op to DropBefore
            dropOp = TDListViewDropBefore;
            
        } else if (NSPointInRect(locInItem, back)) {
            // if p is in the last 1/3 of the item view change op to DropBefore and increment index
            dropIndex++;
            dropVisibleIndex++;
            dropOp = TDListViewDropBefore;
        } else {
            // if p is in the middle 1/3 of the item view leave as DropOn
        }    
    }
    
    // if copying...
    if (NSNotFound == draggingVisibleIndex && dropIndex > draggingIndex) {
        dropIndex++;
    }

    dragOp = [delegate listView:self validateDrop:dragInfo proposedIndex:&dropIndex dropOperation:&dropOp];
    
    //NSLog(@"over: %@. Drop %@ : %d", item, dropOp == TDListViewDropOn ? @"On" : @"Before", dropIndex);

    if (dragOp != NSDragOperationNone) {
        [self layoutItemsWhileDragging];
    }
    
    return dragOp;
}


- (void)draggingExited:(id <NSDraggingInfo>)dragInfo {
    [super draggingExited:dragInfo];
    if (!isDragSource) {
        [self performSelector:@selector(reloadData) withObject:nil afterDelay:.3];
    }
}


- (BOOL)performDragOperation:(id <NSDraggingInfo>)dragInfo {
    if (dropIndex > draggingIndex) {
//        NSUInteger diff = dropIndex - draggingIndex;
//        dropIndex -= diff;
//        dropVisibleIndex -= diff;
        dropIndex--;
        dropVisibleIndex--;
    }
    self.itemFrames = nil;
    
    suppressLayout = YES;
    [self performSelector:@selector(unsuppressLayout) withObject:nil afterDelay:.15];

    if (delegate && [delegate respondsToSelector:@selector(listView:acceptDrop:index:dropOperation:)]) {
        return [delegate listView:self acceptDrop:dragInfo index:dropIndex dropOperation:dropOp];
    } else {
        return NO;
    }
}


- (void)unsuppressLayout {
    suppressLayout = NO;
    [self layoutItems];
}


#pragma mark -
#pragma mark Private

- (void)layoutItems {
    if (suppressLayout) return;
    
    CGFloat extent = [self layoutItemsWithCalculateFrameBlock:nil visibleItemBlock:nil];

    if (extent) {
        [self updateFrameWithExtent:[NSNumber numberWithFloat:extent]];
    }
}


- (CGFloat)layoutItemsWithCalculateFrameBlock:(ListViewCalculateFrameBlock)calculateFrameBlock visibleItemBlock:(ListViewVisibleItemBlock)visibleItemBlock {
    if (!dataSource) {
        return 0;
    }

    for (TDListItem *item in items) {
        [queue enqueue:item];
        [unusedItems addObject:item];
    }
    
    [items removeAllObjects];
    
    NSRect bounds = [self bounds];
    BOOL isPortrait = self.isPortrait;
    
    CGFloat x = itemMargin;
    CGFloat y = 0;
    CGFloat w = isPortrait ? bounds.size.width : 0;
    CGFloat h = isPortrait ? 0 : bounds.size.height;
    
    NSInteger c = [dataSource numberOfItemsInListView:self];
    BOOL respondsToExtentForItem = (delegate && [delegate respondsToSelector:@selector(listView:extentForItemAtIndex:)]);
    BOOL respondsToWillDisplay = (delegate && [delegate respondsToSelector:@selector(listView:willDisplayItem:atIndex:)]);
    
    NSUInteger i = 0;
    for ( ; i < c; i++) {
        // determine item frame
        CGFloat extent = respondsToExtentForItem ? [delegate listView:self extentForItemAtIndex:i] : itemExtent;
        if (isPortrait) {
            h = extent;
        } else {
            w = extent;
        }
        NSRect itemFrame = NSMakeRect(x, y, w, h);

        if (calculateFrameBlock) {
            itemFrame = calculateFrameBlock(itemFrame, i);
        }
        
        // if the item is visible...
        BOOL isItemVisible = [self isFrameVisible:itemFrame];

        if (isItemVisible) {
            TDListItem *item = [dataSource listView:self itemAtIndex:i];
            if (!item) {
                [NSException raise:EXCEPTION_NAME format:@"nil list item view returned for index: %d by: %@", i, dataSource];
            }
            item.index = i;
            [item setFrame:itemFrame];
            [item setHidden:NO];
            [item setSelected:[self.selectedIndexes containsIndex:i]];
            [item setAlphaValue:1.0];
            [self addSubview:item];
            [items addObject:item];
            [unusedItems removeObject:item];

            if (visibleItemBlock) {
                visibleItemBlock(item, i);
            }

            if (respondsToWillDisplay) {
                [delegate listView:self willDisplayItem:item atIndex:i];
            }
        }

        if (isPortrait) {
            y += extent + itemMargin; // add height for next row
        } else {
            x += extent + itemMargin;
        }
    }
    
    for (TDListItem *item in unusedItems) {
        [item removeFromSuperview];
    }

    [unusedItems removeAllObjects];

    // Return extent
    return isPortrait ? y : x;
    
    //NSLog(@"%s my bounds: %@, viewport bounds: %@", _cmd, NSStringFromRect([self bounds]), NSStringFromRect([[self superview] bounds]));
    //NSLog(@"view count: %d, queue count: %d", [items count], [queue count]);
}


- (void)updateFrameWithExtent:(NSNumber *)extentNumber {
    NSRect viewportRect = [self visibleRect];
    NSRect frame = [self frame];
    CGFloat extent = [extentNumber floatValue];
    if (self.isPortrait) {
        if ([self autoresizingMask] & NSViewHeightSizable) {
            extent = extent < viewportRect.size.height ? viewportRect.size.height : extent;
        }
        frame.size.height = extent;
    } else {
        if ([self autoresizingMask] & NSViewWidthSizable) {
            extent = extent < viewportRect.size.width ? viewportRect.size.width : extent;
        }
        frame.size.width = extent;
    }
    
    [self setFrame:frame];
}


- (void)layoutItemsWhileDragging {
    //if (NSNotFound == draggingIndex) return;
    
    NSUInteger itemCount = [items count];
    TDListItem *item = nil;
    
    TDListItem *draggingItem = [self itemAtVisibleIndex:draggingVisibleIndex];
    CGFloat draggingExtent = 0;
    if (draggingItem) {
        draggingExtent = self.isPortrait ? NSHeight([draggingItem frame]) : NSWidth([draggingItem frame]);
    } else {
        draggingExtent = (itemExtent > 0) ? itemExtent : DEFAULT_ITEM_EXTENT;
    }

    [NSAnimationContext beginGrouping];
    [[NSAnimationContext currentContext] setDuration:.05];
    
    NSRect startFrame = [[self itemAtVisibleIndex:0] frame];
    CGFloat extent = self.isPortrait ? NSMinY(startFrame) : NSMinX(startFrame);
    
    CGFloat offset = self.isPortrait ? NSMinY([self visibleRect]) : NSMinX([self visibleRect]);
    BOOL scrolled = (offset > 0);
    if (!scrolled) {
        extent = extent > 0 ? 0 : extent;
    } else {
//        CGFloat firstExtent = self.isPortrait ? NSMinY(startFrame) + NSHeight(startFrame) : NSMinX(startFrame) + NSWidth(startFrame);
//        extent = extent > firstExtent ? firstExtent : extent;
    }
    NSInteger i = 0;
    for ( ; i <= itemCount; i++) {
        item = [self itemAtVisibleIndex:i];
        NSRect frame = [item frame];
        if (self.isPortrait) {
            frame.origin.y = extent;
        } else {
            frame.origin.x = extent;
        }
        
        [item setHidden:i == draggingVisibleIndex];
        
        if (i >= dropVisibleIndex) {
            if (self.isPortrait) {
                frame.origin.y += draggingExtent;
            } else {
                frame.origin.x += draggingExtent;
            }
        }
        
        [[item animator] setFrame:frame];
        if (i != draggingVisibleIndex) {
            extent += self.isPortrait ? frame.size.height : frame.size.width;
        }
    }

    [NSAnimationContext endGrouping];
}


- (NSUInteger)indexForItemWhileDraggingAtPoint:(NSPoint)p {
    if ([itemFrames count] && [items count]) {
        NSUInteger offset = [[items objectAtIndex:0] index];
        NSUInteger i = 0;
        for (NSValue *v in itemFrames) {
            if (i > [items count] - 1) break;
            
            NSRect r = [v rectValue];
            if (NSPointInRect(p, r)) {
                if (i >= draggingVisibleIndex) {
                    return [[items objectAtIndex:i] index] + 1 - offset;
                } else {
                    return [[items objectAtIndex:i] index] - offset;
                }
            }
            i++;
        }
    }
    return NSNotFound;
}


- (TDListItem *)itemWhileDraggingAtIndex:(NSInteger)i {
    TDListItem *item = [self itemAtIndex:i];
    TDListItem *draggingItem = [self itemAtVisibleIndex:draggingVisibleIndex];
                                
    if (item == draggingItem) {
        TDListItem *nextItem = [self itemAtVisibleIndex:i + 1];
        item = nextItem ? nextItem : item;
    }
    if (!item) {
        item = (i < 0) ? [items objectAtIndex:0] : [items lastObject];
    }
    return item;
}


- (void)draggingSourceDragDidEnd {
    draggingVisibleIndex = NSNotFound;
    draggingIndex = NSNotFound;
    isDragSource = NO;
}


- (BOOL)isFrameVisible:(NSRect)frame {
    BOOL visible = NO;
    NSRect viewportRect = [self visibleRect];
    if (displaysClippedItems) {
        visible = NSIntersectsRect(viewportRect, frame);
    } else {
        visible = NSContainsRect(viewportRect, frame);
    }

    return visible;
}


- (CGFloat)totalExtentForRowsInIndexSet:(NSIndexSet *)indexSet {
    BOOL respondsToExtentForItem = (delegate && [delegate respondsToSelector:@selector(listView:extentForItemAtIndex:)]);
    CGFloat totalExtent = 0;
    NSUInteger index = [indexSet firstIndex];
    while (index != NSNotFound) {
        CGFloat extent = respondsToExtentForItem ? [delegate listView:self extentForItemAtIndex:index] : itemExtent;
        totalExtent += extent;
        index = [indexSet indexGreaterThanIndex:index];
    }

    return totalExtent;
}


- (CGFloat)extentForRect:(NSRect)rect {
    CGFloat extent = 0;
    if (self.isPortrait) {
        extent = rect.size.height;
    } else {
        extent = rect.size.width;
    }

    return extent;
}


- (void)appendItemsToFillExtentFromIndexSet:(NSIndexSet *)indexSet {
    // Determine total shift extent of items
    CGFloat extent = [self totalExtentForRowsInIndexSet:indexSet];

    CGFloat offScreenExtent = 0;
    BOOL respondsToWillDisplay = (delegate && [delegate respondsToSelector:@selector(listView:willDisplayItem:atIndex:)]);
    NSUInteger lastOnScreenIndex = [[self.items lastObject] index];
    NSUInteger offScreenIndex = lastOnScreenIndex + 1;
    NSInteger totalCount = [dataSource numberOfItemsInListView:self];
    while ((offScreenExtent < extent) && (totalCount > offScreenIndex)) {
        TDListItem *item = [dataSource listView:self itemAtIndex:offScreenIndex - [indexSet count]];
        if (!item) {
            [NSException raise:EXCEPTION_NAME format:@"nil list item view returned for index: %d by: %@", offScreenIndex, dataSource];
        }
        [self.items insertObject:item atIndex:offScreenIndex];
        [self addSubview:item];

        if (respondsToWillDisplay) {
            [delegate listView:self willDisplayItem:item atIndex:offScreenIndex];
        }

        item.index = offScreenIndex;
        NSRect frame = [self frameForItemAtIndex:offScreenIndex];
        [item setFrame:frame];
        [item setHidden:NO];
        [item setSelected:NO];

        offScreenExtent += [self extentForRect:item.frame];
        offScreenIndex++;
    }
}

@synthesize scrollView;
@synthesize dataSource;
@synthesize delegate;
@synthesize backgroundColor;
@synthesize itemExtent;
@synthesize itemMargin;
@synthesize selectedIndexes;
@synthesize orientation;
@synthesize items;
@synthesize unusedItems;
@synthesize queue;
@synthesize displaysClippedItems;
@synthesize lastMouseDownEvent;
@synthesize itemFrames;
@synthesize dragOffset;
@end
