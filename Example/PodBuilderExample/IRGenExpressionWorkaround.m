//
//  IRGenExpressionWorkaround.m
//  PodBuilderExample
//
//  Created by tomas on 03/09/2020.
//  Copyright © 2020 Subito. All rights reserved.
//

#import "IRGenExpressionWorkaround.h"

@implementation IRGenExpressionWorkaround

// Adding an Objective-C file to a Swift only project workarounds an issue where lldb
// prints out 'error: couldn't IRGen expression. Please check the above error messages for possible root causes.'
// when trying to print a variable

@end
