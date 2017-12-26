//
//  OpenGLSample.m
//  OpenGLTest
//
//  Created by shuyj on 2017/7/14.
//  Copyright © 2017年 shuyj. All rights reserved.
//

#import "OpenGLView.h"
#import <GLKit/GLKit.h>
#import <OpenGLES/ES2/glext.h>

typedef struct YUV420FFrame {
    int width;  //width of video frame
    int height;  //height of video frame
    int yStride;  //stride of Y data buffer
    int uvStride;  //stride of U data buffer
    void* yBuffer;  //Y data buffer
    void* uvBuffer;  //U data buffer
} YUV420FFrame;

@interface OpenGLView(){
    GLint      _uniformSamplers[2];
    GLint      _uniform[1];
    GLuint     _textures[2];
    
    CVOpenGLESTextureCacheRef _textureCache;
    CVOpenGLESTextureRef      _cvTexturesRef[2];
    
    GLfloat         _vertices[8];
    GLfloat         _texCoords[8];
    
    YUV420FFrame            _curYuv;
    
    dispatch_source_t __timerSource;
}

@property (nonatomic, strong, nonnull) EAGLContext * eaglContext;
@property (nonatomic, strong, nonnull) CAEAGLLayer*  caeaglLayer;

@property (nonatomic, assign, readwrite) GLuint     renderbuffers;
@property (nonatomic, assign, readwrite) GLuint     framebuffers;

@property (nonatomic, assign, readwrite) GLint      renderBufferWidth;
@property (nonatomic, assign, readwrite) GLint      renderBufferHeight;

@property (nonatomic, assign, readwrite) GLuint     program;

@property (nonatomic, assign, readwrite) GLint      uniformMatrix;

@property (nonatomic, assign) CVPixelBufferRef      pixelbuffer;

@property (nonatomic, strong) CADisplayLink *       displayLink;


@end
#define IJK_STRINGIZE(x) #x
#define IJK_STRINGIZE2(x) IJK_STRINGIZE(x)
#define IJK_SHADER_STRING(text) @ IJK_STRINGIZE2(text)

static NSString *const g_vertexShaderString = IJK_SHADER_STRING
(
 attribute vec4 position;
 attribute vec2 texcoord;
 uniform mat4 modelViewProjectionMatrix;
 varying vec2 v_texcoord;
 
 void main()
 {
     gl_Position = modelViewProjectionMatrix * position;
     v_texcoord = texcoord.xy;
 }
 );

static NSString *const g_nv12FragmentShaderString = IJK_SHADER_STRING
(
 varying highp vec2 v_texcoord;
 precision mediump float;
 uniform sampler2D SamplerY;
 uniform sampler2D SamplerUV;
 uniform mat3 colorConversionMatrix;
 
 void main()
 {
     mediump vec3 yuv;
     lowp vec3 rgb;
     
     // Subtract constants to map the video range start at 0
     yuv.x = (texture2D(SamplerY, v_texcoord).r - (16.0/255.0));
     yuv.yz = (texture2D(SamplerUV, v_texcoord).ra - vec2(0.5, 0.5));
     rgb = colorConversionMatrix * yuv;
//     rgb.r = yuv.x +               1.40200 * yuv.z;
//     rgb.g = yuv.x - 0.34414 * yuv.y - 0.71414 * yuv.z;
//     rgb.b = yuv.x + 1.77200 * yuv.y;
     
     gl_FragColor = vec4(rgb,1);
 }
 );

static BOOL validateProgram(GLuint prog)
{
    GLint status;
    
    glValidateProgram(prog);
    
#ifdef DEBUG
    GLint logLength;
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0)
    {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program validate log:\n%s", log);
        free(log);
    }
#endif
    
    glGetProgramiv(prog, GL_VALIDATE_STATUS, &status);
    if (status == GL_FALSE) {
        NSLog(@"Failed to validate program %d", prog);
        return NO;
    }
    
    return YES;
}

static GLuint compileShader(GLenum type, NSString *shaderString)
{
    GLint status;
    const GLchar *sources = (GLchar *)shaderString.UTF8String;
    
    GLuint shader = glCreateShader(type);
    if (shader == 0 || shader == GL_INVALID_ENUM) {
        NSLog(@"Failed to create shader %d", type);
        return 0;
    }
    
    glShaderSource(shader, 1, &sources, NULL);
    glCompileShader(shader);
    
#ifdef DEBUG
    GLint logLength;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0)
    {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }
#endif
    
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == GL_FALSE) {
        glDeleteShader(shader);
        NSLog(@"Failed to compile shader:\n");
        return 0;
    }
    
    return shader;
}
__unused static void MLCheckGLErrors() {
    GLenum error;
    BOOL hadError = NO;
    do {
        error = glGetError();
        if (error != 0) {
            NSLog(@"OpenGL error: %@",@(error));
            hadError = YES;
        }
    } while (error != 0);
    NSCAssert(!hadError,@"OpenGL Error");
}

// BT.709, which is the standard for HDTV.
static const GLfloat kColorConversion709[] = {
    1.164,  1.164,  1.164,
    0.0,   -0.213,  2.112,
    1.793, -0.533,  0.0,
};

enum {
    ATTRIBUTE_VERTEX,
    ATTRIBUTE_TEXCOORD,
};

@implementation OpenGLView

+ (Class) layerClass
{
    return [CAEAGLLayer class];
}
- (id) initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [self setupCAEAGLLayerProperties:(CAEAGLLayer*)self.layer];
        [self setupEAGLContext];
        [self setupFramebufferRenderbuffer];
        
        _curYuv.width = 480;
        _curYuv.height = 640;
        _curYuv.yBuffer = malloc(_curYuv.width*_curYuv.height);
        _curYuv.yStride = _curYuv.width;
        _curYuv.uvBuffer = malloc(_curYuv.width*_curYuv.height/2);
        _curYuv.uvStride = _curYuv.width;
        
        CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, _curYuv.width, _curYuv.height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &_pixelbuffer);
        
        NSLog(@"CVPixelBufferCreate ret:%@", @(ret));
        
//        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDraw)];
//        [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        
//        __timerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
//        dispatch_source_set_timer(__timerSource, dispatch_walltime(nil, 0), 0.01 * NSEC_PER_SEC, 0);
//        OpenGLView* __weak weakSelf = self;
//        dispatch_source_set_event_handler(__timerSource, ^{
//            dispatch_async(dispatch_get_main_queue(), ^{
//                [weakSelf onDraw];
//            });
//        });
//        dispatch_resume(__timerSource);
    
    }
    
    return self;
}
- (void)setupEAGLContext
{
    // 指定GL ES 版本
    EAGLRenderingAPI api = kEAGLRenderingAPIOpenGLES3;
    // 创建EAGLContext上下文
    _eaglContext = [[EAGLContext alloc] initWithAPI:api];   // 另一个构造可以指定sharegroup,让不同的EAGLContext可以共享元素
    
}

- (void)setupCAEAGLLayerProperties:(CAEAGLLayer*) eaglLayer
{
    eaglLayer.opaque = YES;
    eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
                                     [NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking,
                                     kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat,
                                     nil];
    _caeaglLayer = eaglLayer;
}

- (BOOL) setupFramebufferRenderbuffer
{
    if (_eaglContext == nil || ![EAGLContext setCurrentContext:_eaglContext]) {
        return NO;
    }
    CGFloat scaleFactor = [[UIScreen mainScreen] scale];
    
    [_caeaglLayer setContentsScale:scaleFactor];
    
    glGenFramebuffers(1, &_framebuffers);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffers);
    
    glGenRenderbuffers(1, &_renderbuffers);
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffers);
    
    [_eaglContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:_caeaglLayer];
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_renderBufferWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_renderBufferHeight);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _renderbuffers);
    
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        return NO;
    }
    
    CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _eaglContext, NULL, &_textureCache);
    if (err) {
        NSLog(@"Error at CVOpenGLESTextureCacheCreate %d\n", err);
        return NO;
    }
    
    if (![self loadShaders]) {
        return NO;
    }
    
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    
    glActiveTexture(GL_TEXTURE0);
    glGenTextures(1, &_textures[0]);
    glBindTexture(GL_TEXTURE_2D, _textures[0]);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    glActiveTexture(GL_TEXTURE1);
    glGenTextures(1, &_textures[1]);
    glBindTexture(GL_TEXTURE_2D, _textures[1]);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return YES;
}
- (void)updateRenderbuffer
{
    [EAGLContext setCurrentContext:_eaglContext];
    
    CGFloat scaleFactor = [[UIScreen mainScreen] scale];
    
    [_caeaglLayer setContentsScale:scaleFactor];
    
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffers);
    
    [_eaglContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_renderBufferWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_renderBufferHeight);
    NSLog(@"update Renderbuffer w:%@ h:%@", @(_renderBufferWidth), @(_renderBufferHeight));
}

- (BOOL)loadShaders
{
    BOOL result = NO;
    GLuint vertShader = 0, fragShader = 0;
    
    _program = glCreateProgram();
    
    vertShader = compileShader(GL_VERTEX_SHADER, g_vertexShaderString);
    if (!vertShader)
        goto exit;
    
    fragShader = compileShader(GL_FRAGMENT_SHADER, g_nv12FragmentShaderString);
    if (!fragShader)
        goto exit;
    
    glAttachShader(_program, vertShader);
    glAttachShader(_program, fragShader);
    glBindAttribLocation(_program, ATTRIBUTE_VERTEX, "position");
    glBindAttribLocation(_program, ATTRIBUTE_TEXCOORD, "texcoord");
    
    glLinkProgram(_program);
    
    GLint status;
    glGetProgramiv(_program, GL_LINK_STATUS, &status);
    if (status == GL_FALSE) {
        NSLog(@"Failed to link program %d", _program);
        goto exit;
    }
    
    result = validateProgram(_program);
    
    _uniformMatrix = glGetUniformLocation(_program, "modelViewProjectionMatrix");
    _uniformSamplers[0] = glGetUniformLocation(_program, "SamplerY");
    _uniformSamplers[1] = glGetUniformLocation(_program, "SamplerUV");
    _uniform[0] = glGetUniformLocation(_program, "colorConversionMatrix");
    
exit:
    
    if (vertShader)
        glDeleteShader(vertShader);
    if (fragShader)
        glDeleteShader(fragShader);
    
    if (result) {
        
        NSLog(@"OK setup GL programm");
        
    } else {
        
        glDeleteProgram(_program);
        _program = 0;
    }
    
    return result;
}

- (void)generateTextureForIos:(CVPixelBufferRef) pixelBuffer
{
    
    for (int i = 0; i < 2; ++i) {
        if (_cvTexturesRef[i]) {
            CFRelease(_cvTexturesRef[i]);
            _cvTexturesRef[i] = 0;
            _textures[i] = 0;
        }
    }
    
    // Periodic texture cache flush every frame
    if (_textureCache)
        CVOpenGLESTextureCacheFlush(_textureCache, 0);
    
    size_t frameWidth  = CVPixelBufferGetWidth(pixelBuffer);
    size_t frameHeight = CVPixelBufferGetHeight(pixelBuffer);
    
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    // GL_RED_EXT y plane GL_RG_EXT uv plane only available GLES2API
    // GL_LUMINANCE y plane GL_LUMINANCE_ALPHA uv plane available GLES2 GLES3
    CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                 _textureCache,
                                                 pixelBuffer,
                                                 NULL,
                                                 GL_TEXTURE_2D,
                                                 GL_LUMINANCE,
                                                 (GLsizei)frameWidth,
                                                 (GLsizei)frameHeight,
                                                 GL_LUMINANCE,
                                                 GL_UNSIGNED_BYTE,
                                                 0,
                                                 &_cvTexturesRef[0]);
    MLCheckGLErrors();
    _textures[0] = CVOpenGLESTextureGetName(_cvTexturesRef[0]);
    MLCheckGLErrors();
    glBindTexture(CVOpenGLESTextureGetTarget(_cvTexturesRef[0]), _textures[0]);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    
    CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                 _textureCache,
                                                 pixelBuffer,
                                                 NULL,
                                                 GL_TEXTURE_2D,
                                                 GL_LUMINANCE_ALPHA,
                                                 (GLsizei)frameWidth / 2,
                                                 (GLsizei)frameHeight / 2,
                                                 GL_LUMINANCE_ALPHA,
                                                 GL_UNSIGNED_BYTE,
                                                 1,
                                                 &_cvTexturesRef[1]);
    MLCheckGLErrors();
    _textures[1] = CVOpenGLESTextureGetName(_cvTexturesRef[1]);
    glBindTexture(CVOpenGLESTextureGetTarget(_cvTexturesRef[1]), _textures[1]);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

- (void)generateTexture:(YUV420FFrame) yuv
{
    size_t frameWidth  = yuv.width;
    size_t frameHeight = yuv.height;
    
    glBindTexture(GL_TEXTURE_2D, _textures[0]);
    MLCheckGLErrors();
    
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, (int)frameWidth, (int)frameHeight, 0, GL_LUMINANCE, GL_UNSIGNED_BYTE, yuv.yBuffer);
//    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, frameWidth, frameHeight, GL_RGBA, GL_UNSIGNED_BYTE, yuv.yBuffer);
//    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _textures, 0);
    MLCheckGLErrors();
    
    glBindTexture(GL_TEXTURE_2D, _textures[1]);
    MLCheckGLErrors();
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE_ALPHA, (int)frameWidth/2, (int)frameHeight/2, 0, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, yuv.uvBuffer);
    MLCheckGLErrors();
}

- (void) updateYuv
{
    int height = _curYuv.height;
    int width = _curYuv.width;
    static int i = 0;
    /* Y */
    for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++)
            ((uint8_t*)(_curYuv.yBuffer))[y * _curYuv.yStride + x] = x + y + i * 3;
    
    /* Cb and Cr */
    for (int y = 0; y < height / 2; y++) {
        for (int x = 0; x < width; x+=2) {
            ((uint8_t*)(_curYuv.uvBuffer))[y * _curYuv.uvStride + x] = 128 + y + i * 2;
            ((uint8_t*)(_curYuv.uvBuffer))[y * _curYuv.uvStride + x + 1] = 64 + x + i * 5;
        }
    }
    i++;
}

- (CVPixelBufferRef)genPixelbuffer
{
    // Create a vImage buffer for the destination pixel buffer.
    CVPixelBufferLockBaseAddress(_pixelbuffer, 0);
    
    uint8_t* y_src= (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(_pixelbuffer, 0);
    memcpy(y_src, _curYuv.yBuffer, _curYuv.yStride*_curYuv.height);
    uint8_t* u_src= (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(_pixelbuffer, 1);
    memcpy(u_src, _curYuv.uvBuffer, _curYuv.uvStride*_curYuv.height/2);
    
    CVPixelBufferUnlockBaseAddress(_pixelbuffer, 0);
    
    return _pixelbuffer;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    if ([NSThread isMainThread]) {
        [self updateRenderbuffer];
        [self onDraw];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self updateRenderbuffer];
            [self onDraw];
        });
    }
}

- (void)drawRect:(CGRect)rect
{
    [self onDraw];
}

- (void) onDraw
{
    [EAGLContext setCurrentContext:_eaglContext];
    
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffers);
    MLCheckGLErrors();
    glViewport(0, 0, _renderBufferWidth, _renderBufferHeight);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(_program);
    MLCheckGLErrors();
    
    [self updateYuv];
    
    [self generateTextureForIos:[self genPixelbuffer]];
    
//    [self generateTexture:_curYuv];
    
    if (_textures[0] == 0)
        return;
    
    for (int i = 0; i < 2; ++i) {
        glActiveTexture(GL_TEXTURE0 + i);
        glBindTexture(GL_TEXTURE_2D, _textures[i]);
        glUniform1i(_uniformSamplers[i], i);
    }
    
    glUniformMatrix3fv(_uniform[0], 1, GL_FALSE, kColorConversion709);
    GLfloat modelviewProj[16] = {1, 0, 0, 0,
                                0, 1, 0, 0,
                                0, 0, 1, 0,
                                0, 0, 0, 1
    };
    
    glUniformMatrix4fv(_uniformMatrix, 1, GL_FALSE, modelviewProj);
    MLCheckGLErrors();
    _vertices[0] = -1.0f;  // x0
    _vertices[1] = -1.0f;  // y0
    _vertices[2] =  1.0f;  // ..
    _vertices[3] = -1.0f;
    _vertices[4] = -1.0f;
    _vertices[5] =  1.0f;
    _vertices[6] =  1.0f;  // x3
    _vertices[7] =  1.0f;  // y3
    
    glVertexAttribPointer(ATTRIBUTE_VERTEX, 2, GL_FLOAT, 0, 0, _vertices);
    glEnableVertexAttribArray(ATTRIBUTE_VERTEX);
    _texCoords[0] = 0.0f;
    _texCoords[1] = 1.0f;
    _texCoords[2] = 1.0f;
    _texCoords[3] = 1.0f;
    _texCoords[4] = 0.0f;
    _texCoords[5] = 0.0f;
    _texCoords[6] = 1.0f;
    _texCoords[7] = 0.0f;
    glVertexAttribPointer(ATTRIBUTE_TEXCOORD, 2, GL_FLOAT, 0, 0, _texCoords);
    glEnableVertexAttribArray(ATTRIBUTE_TEXCOORD);
    MLCheckGLErrors();
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    MLCheckGLErrors();
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffers);
    [_eaglContext presentRenderbuffer:GL_RENDERBUFFER];
    
    if ([EAGLContext currentContext] == _eaglContext)
        [EAGLContext setCurrentContext:nil];
}

- (void)dealloc
{
    if ([EAGLContext currentContext] != _eaglContext) {
        [EAGLContext setCurrentContext:_eaglContext];
    }
    
    dispatch_source_cancel(__timerSource);
    __timerSource = nil;
    
    for (int i = 0; i < 2; ++i) {
        if (_cvTexturesRef[i]) {
            CFRelease(_cvTexturesRef[i]);
            _cvTexturesRef[i] = 0;
            _textures[i] = 0;
        }
    }
    
    if (_textures[0])
        glDeleteTextures(2, _textures);
    
    if (_framebuffers) {
        glDeleteFramebuffers(1, &_framebuffers);
        _framebuffers = 0;
    }
    
    if (_renderbuffers) {
        glDeleteRenderbuffers(1, &_renderbuffers);
        _renderbuffers = 0;
    }
    
    if (_program) {
        glDeleteProgram(_program);
        _program = 0;
    }
    
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = 0;
    }
    
    if ([EAGLContext currentContext] == _eaglContext) {
        [EAGLContext setCurrentContext:nil];
    }
    
    _eaglContext = nil;
}

@end
