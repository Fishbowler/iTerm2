//
//  iTermFunctionCallSuggesterTest.m
//  iTerm2XCTests
//
//  Created by George Nachman on 6/12/18.
//

#import <XCTest/XCTest.h>
#import "iTermFunctionCallSuggester.h"
#import "iTermFunctionCallParser.h"
#import "iTermParsedExpression+Tests.h"
#import "iTermScriptFunctionCall+Private.h"

@interface iTermFunctionCallParser(Testing)
- (instancetype)initPrivate;
@end

@interface iTermFunctionCallSuggesterTest : XCTestCase

@end

@implementation iTermFunctionCallSuggesterTest {
    iTermFunctionCallParser *_parser;
    iTermFunctionCallSuggester *_suggester;
}

- (void)setUp {
    [super setUp];

    NSDictionary *signatures = @{ @"func1": @[ @"arg1", @"arg2" ],
                                  @"func2": @[ ] };
    NSArray *paths = @[ @"path.first", @"path.second", @"third" ];
    _suggester =
        [[iTermFunctionCallSuggester alloc] initWithFunctionSignatures:signatures
                                                                 paths:paths];

    _parser = [[iTermFunctionCallParser alloc] initWithStart:@"expression"];
}

- (void)tearDown {
    [_suggester release];
}

- (void)testSuggestFunctionName {
    NSArray<NSString *> *actual = [_suggester suggestionsForString:@"f"];
    NSArray<NSString *> *expected = @[ @"func1(arg1:", @"func2()" ];
    XCTAssertEqualObjects(actual, expected);
}

- (void)testParseFunctionCallWithStringLiteral {
    NSString *code = @"func(x: \"foo\")";
    iTermParsedExpression *actual = [_parser parse:code
                                            source:^id(NSString *name) {
                                                return @"value";
                                            }];
    iTermParsedExpression *expected = [[iTermParsedExpression alloc] init];
    expected.functionCall = [[iTermScriptFunctionCall alloc] init];
    expected.functionCall.name = @"func";
    [expected.functionCall addParameterWithName:@"x" value:@"foo"];

    XCTAssertEqualObjects(actual, expected);
}

- (void)testParseFunctionCallWithSwiftyString {
    NSString *code = @"func(x: \"foo\\(path)bar\")";
    iTermParsedExpression *actual = [_parser parse:code
                                            source:^id(NSString *name) {
                                                return @"value";
                                            }];
    iTermParsedExpression *expected = [[iTermParsedExpression alloc] init];
    expected.functionCall = [[iTermScriptFunctionCall alloc] init];
    expected.functionCall.name = @"func";
    [expected.functionCall addParameterWithName:@"x" value:@"foovaluebar"];

    XCTAssertEqualObjects(actual, expected);
}

- (void)testParseFunctionCallWithNestedSwiftyString {
    // func(                                                      )
    //      x: "foo\(                                        )bar"
    //               inner(                                 )
    //                     s: "Hello \(     ), how are you?"
    //                                 world

    NSString *code = @"func(x: \"foo\\(inner(s: \"Hello \\(world), how are you?\"))bar\")";
    iTermParsedExpression *actual = [_parser parse:code
                                            source:^id(NSString *name) {
                                                return [name uppercaseString];
                                            }];
    iTermParsedExpression *innerCall = [[iTermParsedExpression alloc] init];
    innerCall.functionCall = [[iTermScriptFunctionCall alloc] init];
    innerCall.functionCall.name = @"inner";
    [innerCall.functionCall addParameterWithName:@"s" value:@"Hello WORLD, how are you?"];

    iTermParsedExpression *xValue = [[iTermParsedExpression alloc] init];
    xValue.interpolatedStringParts = @[ @"foo", innerCall, @"bar" ];

    iTermParsedExpression *expected = [[iTermParsedExpression alloc] init];
    expected.functionCall = [[iTermScriptFunctionCall alloc] init];
    expected.functionCall.name = @"func";
    [expected.functionCall addParameterWithName:@"x" value:xValue];

    XCTAssertEqualObjects(actual, expected);
}

@end
