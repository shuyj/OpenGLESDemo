//
//  ViewController.m
//  OpenGLTest
//
//  Created by shuyj on 2017/7/14.
//  Copyright © 2017年 shuyj. All rights reserved.
//

#import "ViewController.h"
#import "OpenGLView.h"

@interface ViewController ()
@property (nonatomic, strong) OpenGLView* glView;
@property (nonatomic, strong) NSTimer *   refreshTimer;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
    _glView = [[OpenGLView alloc] initWithFrame:self.view.bounds];
    _glView.autoresizesSubviews = YES;
    _glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_glView];
    
    _refreshTimer =  [NSTimer timerWithTimeInterval:0.01 target:self selector:@selector(timerAction) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_refreshTimer forMode:NSRunLoopCommonModes];
}

- (void)timerAction
{
    [_glView onDraw];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
