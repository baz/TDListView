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

#import "NSEvent+TDAdditions.h"
#import "TDUtils.h"

#define ESC 53
#define RETURN 36
#define ENTER 76

@implementation NSEvent (TDAdditions)

- (BOOL)isMouseDown {
    return (NSLeftMouseDown == [self type]);
}


- (BOOL)isMouseMoved {
    return (NSMouseMoved == [self type]);
}


- (BOOL)isMouseDragged {
    return (NSLeftMouseDragged == [self type]);
}


- (BOOL)isMouseUp {
    return (NSLeftMouseUp == [self type]);
}


- (BOOL)isKeyUpOrDown {
    return (NSKeyUp == [self type] || NSKeyDown == [self type]);
}


- (BOOL)is3rdButtonClick {
    return 2 == [self buttonNumber];
}


- (BOOL)isScrollWheel {
    return (NSScrollWheel == [self type]);
}


- (BOOL)isDoubleClick {
    return ([self clickCount] % 2 == 0);
}


- (BOOL)isCommandKeyPressed {
    return TDIsCommandKeyPressed([self modifierFlags]);
}


- (BOOL)isControlKeyPressed {
    return TDIsControlKeyPressed([self modifierFlags]);
}


- (BOOL)isShiftKeyPressed {
    return TDIsShiftKeyPressed([self modifierFlags]);
}


- (BOOL)isOptionKeyPressed {
    return TDIsOptionKeyPressed([self modifierFlags]);
}


- (BOOL)isEscKeyPressed {
    return [self isKeyUpOrDown] && ESC == [self keyCode];
}


- (BOOL)isReturnKeyPressed {
    return [self isKeyUpOrDown] && RETURN == [self keyCode];
}


- (BOOL)isEnterKeyPressed {
    return [self isKeyUpOrDown] && ENTER == [self keyCode];
}

@end
