#import "Internal.h"
#import "../platform/CursorImage.h"

@implementation SharpFramebufferView
@synthesize program = _program;
@synthesize rectProgram = _rectProgram;
@synthesize nv12Program = _nv12Program;
@synthesize colorProgram = _colorProgram;
@synthesize maskProgram = _maskProgram;
@synthesize texture = _texture;
@synthesize motionMaskTexture = _motionMaskTexture;
@synthesize vao = _vao;
@synthesize vbo = _vbo;
@synthesize videoVbo = _videoVbo;
@synthesize cursorVbo = _cursorVbo;
@synthesize cursorTexture = _cursorTexture;
@synthesize cursorTextureWidth = _cursorTextureWidth;
@synthesize cursorTextureHeight = _cursorTextureHeight;
@synthesize cursorScale = _cursorScale;
@synthesize cursorPath = _cursorPath;
@synthesize cursorDir = _cursorDir;
@synthesize textureWidth = _textureWidth;
@synthesize textureHeight = _textureHeight;
@synthesize videoTextureCache = _videoTextureCache;
@synthesize lastVideoUpdateKind = _lastVideoUpdateKind;
@synthesize videoTextureMode = _videoTextureMode;
@synthesize videoSharpen = _videoSharpen;
- (instancetype)initWithFrame:(NSRect)frameRect {
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFAOpenGLProfile,
        NSOpenGLProfileVersion3_2Core,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize,
        24,
        NSOpenGLPFAAlphaSize,
        8,
        0,
    };
    NSOpenGLPixelFormat *format =
        [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    self = [super initWithFrame:frameRect pixelFormat:format];
    return self;
}

- (void)prepareOpenGL {
    [super prepareOpenGL];
    if (_program != 0) {
        return;
    }
    [[self openGLContext] makeCurrentContext];

    GLint swap = 1;
    [[self openGLContext] setValues:&swap forParameter:NSOpenGLCPSwapInterval];

    const char *vertexSource =
        "#version 150 core\n"
        "in vec2 position;\n"
        "in vec2 texcoord;\n"
        "out vec2 v_texcoord;\n"
        "void main() {\n"
        "  gl_Position = vec4(position, 0.0, 1.0);\n"
        "  v_texcoord = texcoord;\n"
        "}\n";
    const char *fragmentSource =
        "#version 150 core\n"
        "uniform sampler2D framebuffer_tex;\n"
        "in vec2 v_texcoord;\n"
        "out vec4 frag_color;\n"
        "void main() {\n"
        "  frag_color = texture(framebuffer_tex, v_texcoord);\n"
        "}\n";
    const char *maskFragmentSource =
        "#version 150 core\n"
        "uniform sampler2D framebuffer_tex;\n"
        "uniform sampler2D motion_mask;\n"
        "uniform vec2 framebuffer_size;\n"
        "uniform float mask_bytes;\n"
        "uniform float tile_size;\n"
        "uniform float mask_cols;\n"
        "in vec2 v_texcoord;\n"
        "out vec4 frag_color;\n"
        "void main() {\n"
        "  vec2 tile = floor(v_texcoord * framebuffer_size / tile_size);\n"
        "  float tile_id = tile.y * mask_cols + tile.x;\n"
        "  float byte_id = floor(tile_id / 8.0);\n"
        "  float bit_id = tile_id - byte_id * 8.0;\n"
        "  float packed = texture(motion_mask,\n"
        "      vec2((byte_id + 0.5) / mask_bytes, 0.5)).r * 255.0;\n"
        "  if (mod(floor(packed / exp2(bit_id)), 2.0) > 0.5) discard;\n"
        "  frag_color = texture(framebuffer_tex, v_texcoord);\n"
        "}\n";
    const char *colorFragmentSource =
        "#version 150 core\n"
        "uniform vec4 cursor_color;\n"
        "out vec4 frag_color;\n"
        "void main() {\n"
        "  frag_color = cursor_color;\n"
        "}\n";

    GLuint vertex = compile_shader(GL_VERTEX_SHADER, vertexSource);
    GLuint fragment = compile_shader(GL_FRAGMENT_SHADER, fragmentSource);
    _program = glCreateProgram();
    glAttachShader(_program, vertex);
    glAttachShader(_program, fragment);
    glBindAttribLocation(_program, 0, "position");
    glBindAttribLocation(_program, 1, "texcoord");
    glLinkProgram(_program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);

    GLuint maskVertex = compile_shader(GL_VERTEX_SHADER, vertexSource);
    GLuint maskFragment = compile_shader(GL_FRAGMENT_SHADER, maskFragmentSource);
    _maskProgram = glCreateProgram();
    glAttachShader(_maskProgram, maskVertex);
    glAttachShader(_maskProgram, maskFragment);
    glBindAttribLocation(_maskProgram, 0, "position");
    glBindAttribLocation(_maskProgram, 1, "texcoord");
    glLinkProgram(_maskProgram);
    glDeleteShader(maskVertex);
    glDeleteShader(maskFragment);

    GLuint colorVertex = compile_shader(GL_VERTEX_SHADER, vertexSource);
    GLuint colorFragment = compile_shader(GL_FRAGMENT_SHADER, colorFragmentSource);
    _colorProgram = glCreateProgram();
    glAttachShader(_colorProgram, colorVertex);
    glAttachShader(_colorProgram, colorFragment);
    glBindAttribLocation(_colorProgram, 0, "position");
    glBindAttribLocation(_colorProgram, 1, "texcoord");
    glLinkProgram(_colorProgram);
    glDeleteShader(colorVertex);
    glDeleteShader(colorFragment);

    const char *rectFragmentSource =
        "#version 150 core\n"
        "uniform sampler2DRect framebuffer_tex;\n"
        "in vec2 v_texcoord;\n"
        "out vec4 frag_color;\n"
        "void main() {\n"
        "  frag_color = texture(framebuffer_tex, v_texcoord);\n"
        "}\n";
    GLuint rectVertex = compile_shader(GL_VERTEX_SHADER, vertexSource);
    GLuint rectFragment = compile_shader(GL_FRAGMENT_SHADER, rectFragmentSource);
    _rectProgram = glCreateProgram();
    glAttachShader(_rectProgram, rectVertex);
    glAttachShader(_rectProgram, rectFragment);
    glBindAttribLocation(_rectProgram, 0, "position");
    glBindAttribLocation(_rectProgram, 1, "texcoord");
    glLinkProgram(_rectProgram);
    glDeleteShader(rectVertex);
    glDeleteShader(rectFragment);

    /* Normalized 8-bit video uses 16/255 and 128/255 offsets. Using 1/16
     * and 1/2 adds a visible red/blue bias to dark, otherwise neutral UI. */
    const char *nv12FragmentSource =
        "#version 150 core\n"
        "uniform sampler2DRect y_tex;\n"
        "uniform sampler2DRect uv_tex;\n"
        "uniform float sharpen_strength;\n"
        "uniform int yuv_matrix;\n"
        "in vec2 v_texcoord;\n"
        "out vec4 frag_color;\n"
        "void main() {\n"
        "  float y = texture(y_tex, v_texcoord).r;\n"
        "  if (sharpen_strength > 0.0) {\n"
        "    float n = texture(y_tex, v_texcoord + vec2(0.0, -1.0)).r;\n"
        "    float s = texture(y_tex, v_texcoord + vec2(0.0, 1.0)).r;\n"
        "    float e = texture(y_tex, v_texcoord + vec2(1.0, 0.0)).r;\n"
        "    float w = texture(y_tex, v_texcoord + vec2(-1.0, 0.0)).r;\n"
        "    float blur = (n + s + e + w) * 0.25;\n"
        "    y = clamp(y + (y - blur) * sharpen_strength, 0.0, 1.0);\n"
        "  }\n"
        "  vec2 uv = texture(uv_tex, v_texcoord * 0.5).rg;\n"
        "  float yy = 1.16438356 * (y - 16.0 / 255.0);\n"
        "  float cb = uv.x - 128.0 / 255.0;\n"
        "  float cr = uv.y - 128.0 / 255.0;\n"
        "  float r = yy + (yuv_matrix == 1 ? 1.79274107 : 1.59602678) * cr;\n"
        "  float g = yy - (yuv_matrix == 1 ? 0.21324861 : 0.39176229) * cb -\n"
        "             (yuv_matrix == 1 ? 0.53290933 : 0.81296764) * cr;\n"
        "  float b = yy + (yuv_matrix == 1 ? 2.11240179 : 2.01723214) * cb;\n"
        "  frag_color = vec4(clamp(vec3(r, g, b), 0.0, 1.0), 1.0);\n"
        "}\n";
    GLuint nv12Vertex = compile_shader(GL_VERTEX_SHADER, vertexSource);
    GLuint nv12Fragment = compile_shader(GL_FRAGMENT_SHADER, nv12FragmentSource);
    _nv12Program = glCreateProgram();
    glAttachShader(_nv12Program, nv12Vertex);
    glAttachShader(_nv12Program, nv12Fragment);
    glBindAttribLocation(_nv12Program, 0, "position");
    glBindAttribLocation(_nv12Program, 1, "texcoord");
    glLinkProgram(_nv12Program);
    glDeleteShader(nv12Vertex);
    glDeleteShader(nv12Fragment);

    const GLfloat vertices[] = {
        -1.0f, -1.0f, 0.0f, 1.0f,
         1.0f, -1.0f, 1.0f, 1.0f,
        -1.0f,  1.0f, 0.0f, 0.0f,
         1.0f,  1.0f, 1.0f, 0.0f,
    };

    glGenVertexArrays(1, &_vao);
    glBindVertexArray(_vao);
    glGenBuffers(1, &_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, _vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    glGenBuffers(1, &_videoVbo);
    glGenBuffers(1, &_cursorVbo);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), 0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                          (const GLvoid *)(2 * sizeof(GLfloat)));

    glGenTextures(1, &_texture);
    glBindTexture(GL_TEXTURE_2D, _texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    _cursorHue = getenv("SHARP_CURSOR_HUE") ? strtod(getenv("SHARP_CURSOR_HUE"), NULL) : 0.94;
    (void)[self loadCursorTexture];
    [self loadCursorThemeTextures];
    glGenTextures(1, &_motionMaskTexture);
    glBindTexture(GL_TEXTURE_2D, _motionMaskTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    for (size_t i = 0; i < SHARP_MAX_VIDEO_REGIONS; i++) {
        glGenTextures(1, &_videoSlots[i].bgra_texture);
        glBindTexture(GL_TEXTURE_2D, _videoSlots[i].bgra_texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glGenTextures(1, &_videoSlots[i].y_texture);
        glBindTexture(GL_TEXTURE_RECTANGLE, _videoSlots[i].y_texture);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glGenTextures(1, &_videoSlots[i].uv_texture);
        glBindTexture(GL_TEXTURE_RECTANGLE, _videoSlots[i].uv_texture);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        _videoSlots[i].texture_target = GL_TEXTURE_2D;
        _videoSlots[i].texture_name = _videoSlots[i].bgra_texture;
    }
    glUseProgram(_program);
    glUniform1i(glGetUniformLocation(_program, "framebuffer_tex"), 0);
    glUseProgram(_maskProgram);
    glUniform1i(glGetUniformLocation(_maskProgram, "framebuffer_tex"), 0);
    glUniform1i(glGetUniformLocation(_maskProgram, "motion_mask"), 1);
    glUseProgram(_rectProgram);
    glUniform1i(glGetUniformLocation(_rectProgram, "framebuffer_tex"), 0);
    glUseProgram(_nv12Program);
    glUniform1i(glGetUniformLocation(_nv12Program, "y_tex"), 0);
    glUniform1i(glGetUniformLocation(_nv12Program, "uv_tex"), 1);
    glUniform1i(glGetUniformLocation(_nv12Program, "yuv_matrix"),
                SHARP_NV12_MATRIX_BT709);
    const char *sharpenEnv = getenv("SHARP_SHARPEN");
    _videoSharpen = 0.0f;
    if (sharpenEnv != NULL && sharpenEnv[0] != '\0') {
        char *end = NULL;
        double parsed = strtod(sharpenEnv, &end);
        if (end != sharpenEnv && isfinite(parsed)) {
            _videoSharpen = (float)MAX(0.0, MIN(1.0, parsed));
        }
    }
    glUniform1f(glGetUniformLocation(_nv12Program, "sharpen_strength"),
                _videoSharpen);
    _cursorScale = 1.0f;
    const char *cursorScaleEnv = getenv("SHARP_CURSOR_SCALE");
    if (cursorScaleEnv != NULL && cursorScaleEnv[0] != '\0') {
        char *end = NULL;
        double parsed = strtod(cursorScaleEnv, &end);
        if (end != cursorScaleEnv && isfinite(parsed)) {
            _cursorScale = (float)MAX(0.5, MIN(3.0, parsed));
        }
    }

    CGLContextObj cglContext = [[self openGLContext] CGLContextObj];
    CGLPixelFormatObj cglPixelFormat = [[self pixelFormat] CGLPixelFormatObj];
    if (cglContext != NULL && cglPixelFormat != NULL) {
        (void)CVOpenGLTextureCacheCreate(kCFAllocatorDefault, NULL, cglContext,
                                         cglPixelFormat, NULL,
                                         &_videoTextureCache);
    }
}

- (void)setDrawableViewportWidth:(uint32_t)drawableWidth
                   drawableHeight:(uint32_t)drawableHeight
                             clear:(BOOL)clear {
    glViewport(0, 0, (GLsizei)drawableWidth, (GLsizei)drawableHeight);
    if (clear) {
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    if (_textureWidth == 0 || _textureHeight == 0) {
        return;
    }

    CGFloat textureAspect = (CGFloat)_textureWidth / (CGFloat)_textureHeight;
    CGFloat drawableAspect = (CGFloat)drawableWidth / (CGFloat)drawableHeight;
    uint32_t viewportWidth = drawableWidth;
    uint32_t viewportHeight = drawableHeight;
    uint32_t viewportX = 0;
    uint32_t viewportY = 0;
    if (drawableAspect > textureAspect) {
        viewportWidth = (uint32_t)floor((CGFloat)drawableHeight * textureAspect);
        viewportX = (drawableWidth - viewportWidth) / 2u;
    } else if (drawableAspect < textureAspect) {
        viewportHeight = (uint32_t)floor((CGFloat)drawableWidth / textureAspect);
        viewportY = (drawableHeight - viewportHeight) / 2u;
    }

    glViewport((GLint)viewportX, (GLint)viewportY, (GLsizei)viewportWidth,
               (GLsizei)viewportHeight);
}

- (void)drawCurrentTextureInDrawableWidth:(uint32_t)drawableWidth
                           drawableHeight:(uint32_t)drawableHeight {
    [self setDrawableViewportWidth:drawableWidth
                      drawableHeight:drawableHeight
                                clear:YES];
    if (_textureWidth == 0 || _textureHeight == 0) {
        return;
    }
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _texture);
    glUseProgram(_program);
    glBindVertexArray(_vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

- (void)drawCurrentTextureMaskedInDrawableWidth:(uint32_t)drawableWidth
                                   drawableHeight:(uint32_t)drawableHeight
                                  motionMaskBytes:(uint32_t)motionMaskBytes {
    if (_textureWidth == 0 || _textureHeight == 0 || _maskProgram == 0 ||
        _motionMaskTexture == 0 || motionMaskBytes == 0) {
        return;
    }
    [self setDrawableViewportWidth:drawableWidth
                      drawableHeight:drawableHeight
                                clear:NO];
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _texture);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, _motionMaskTexture);
    glUseProgram(_maskProgram);
    glUniform2f(glGetUniformLocation(_maskProgram, "framebuffer_size"),
                (GLfloat)_textureWidth, (GLfloat)_textureHeight);
    glUniform1f(glGetUniformLocation(_maskProgram, "mask_bytes"),
                (GLfloat)motionMaskBytes);
    glUniform1f(glGetUniformLocation(_maskProgram, "tile_size"),
                (GLfloat)SHARP_TILE_SIZE);
    glUniform1f(glGetUniformLocation(_maskProgram, "mask_cols"),
                (GLfloat)sharp_tile_cols(_textureWidth));
    glBindVertexArray(_vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glActiveTexture(GL_TEXTURE0);
}

- (void)drawCurrentTextureWithViewportWidth:(uint32_t)viewportWidth
                             viewportHeight:(uint32_t)viewportHeight {
    [self drawCurrentTextureInDrawableWidth:viewportWidth
                             drawableHeight:viewportHeight];
}

- (sharp_video_texture_slot_t *)slotForRegion:(uint16_t)regionId create:(BOOL)create {
    sharp_video_texture_slot_t *freeSlot = NULL;
    for (size_t i = 0; i < SHARP_MAX_VIDEO_REGIONS; i++) {
        if (_videoSlots[i].active && _videoSlots[i].region_id == regionId) {
            return &_videoSlots[i];
        }
        if (!_videoSlots[i].active && freeSlot == NULL) {
            freeSlot = &_videoSlots[i];
        }
    }
    if (!create || freeSlot == NULL) {
        return NULL;
    }
    freeSlot->active = 1u;
    freeSlot->region_id = regionId;
    freeSlot->width = 0;
    freeSlot->height = 0;
    freeSlot->texture_target = GL_TEXTURE_2D;
    freeSlot->texture_name = freeSlot->bgra_texture;
    freeSlot->last_update_kind = 0;
    freeSlot->nv12_matrix = SHARP_NV12_MATRIX_BT709;
    return freeSlot;
}

- (void)releaseVideoSlot:(sharp_video_texture_slot_t *)slot {
    if (slot == NULL) {
        return;
    }
    if (slot->cv_texture != NULL) {
        CFRelease(slot->cv_texture);
        slot->cv_texture = NULL;
    }
    slot->active = 0u;
    slot->region_id = 0;
    slot->texture_target = GL_TEXTURE_2D;
    slot->texture_name = slot->bgra_texture;
    slot->width = 0;
    slot->height = 0;
    slot->last_update_kind = 0;
    slot->nv12_matrix = SHARP_NV12_MATRIX_BT709;
}

- (void)releaseVideoRegion:(uint16_t)regionId {
    sharp_video_texture_slot_t *slot = [self slotForRegion:regionId create:NO];
    [self releaseVideoSlot:slot];
}

- (void)drawVideoLayer:(const sharp_video_layer_snapshot_t *)layer
                  slot:(const sharp_video_texture_slot_t *)slot {
    if (layer == NULL || slot == NULL || !layer->active || !slot->active ||
        slot->width == 0 || slot->height == 0 || _textureWidth == 0 ||
        _textureHeight == 0 || slot->texture_name == 0) {
        return;
    }
    float x0 = ((float)layer->header.x / (float)_textureWidth) * 2.0f - 1.0f;
    float x1 = ((float)(layer->header.x + layer->header.w) /
                (float)_textureWidth) * 2.0f - 1.0f;
    float y0 = 1.0f - ((float)layer->header.y / (float)_textureHeight) * 2.0f;
    float y1 = 1.0f - ((float)(layer->header.y + layer->header.h) /
                       (float)_textureHeight) * 2.0f;
    GLfloat ll[2] = {0.0f, 1.0f};
    GLfloat lr[2] = {1.0f, 1.0f};
    GLfloat ul[2] = {0.0f, 0.0f};
    GLfloat ur[2] = {1.0f, 0.0f};
    if (slot->cv_texture != NULL) {
        GLfloat cleanLl[2];
        GLfloat cleanLr[2];
        GLfloat cleanUr[2];
        GLfloat cleanUl[2];
        CVOpenGLTextureGetCleanTexCoords(slot->cv_texture, cleanLl,
                                          cleanLr, cleanUr, cleanUl);
        ll[0] = cleanLl[0];
        ll[1] = cleanLl[1];
        lr[0] = cleanLr[0];
        lr[1] = cleanLr[1];
        ul[0] = cleanUl[0];
        ul[1] = cleanUl[1];
        ur[0] = cleanUr[0];
        ur[1] = cleanUr[1];
    } else if (slot->texture_target == GL_TEXTURE_RECTANGLE) {
        ll[0] = 0.0f;
        ll[1] = (GLfloat)slot->height;
        lr[0] = (GLfloat)slot->width;
        lr[1] = (GLfloat)slot->height;
        ul[0] = 0.0f;
        ul[1] = 0.0f;
        ur[0] = (GLfloat)slot->width;
        ur[1] = 0.0f;
    }
    const GLfloat vertices[] = {
        x0, y1, ll[0], ll[1],
        x1, y1, lr[0], lr[1],
        x0, y0, ul[0], ul[1],
        x1, y0, ur[0], ur[1],
    };
    glActiveTexture(GL_TEXTURE0);
    if (_videoTextureMode == SHARP_VIDEO_TEXTURE_NV12) {
        glBindTexture(GL_TEXTURE_RECTANGLE, slot->y_texture);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_RECTANGLE, slot->uv_texture);
        glActiveTexture(GL_TEXTURE0);
        glUseProgram(_nv12Program);
        glUniform1i(glGetUniformLocation(_nv12Program, "yuv_matrix"),
                    slot->nv12_matrix);
    } else {
        glBindTexture(slot->texture_target, slot->texture_name);
        glUseProgram(slot->texture_target == GL_TEXTURE_RECTANGLE ? _rectProgram
                                                                  : _program);
    }
    glBindVertexArray(_vao);
    glBindBuffer(GL_ARRAY_BUFFER, _videoVbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STREAM_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), 0);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                          (const GLvoid *)(2 * sizeof(GLfloat)));
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindBuffer(GL_ARRAY_BUFFER, _vbo);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), 0);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                          (const GLvoid *)(2 * sizeof(GLfloat)));
}

- (void)drawCursorTriangleX:(float)x
                          y:(float)y
                      width:(float)w
                     height:(float)h
                      colorR:(float)r
                           g:(float)g
                           b:(float)b {
    if (_textureWidth == 0 || _textureHeight == 0 || _colorProgram == 0 ||
        _cursorVbo == 0) {
        return;
    }
    float x0 = (x / (float)_textureWidth) * 2.0f - 1.0f;
    float y0 = 1.0f - (y / (float)_textureHeight) * 2.0f;
    float x1 = ((x + w * 0.28f) / (float)_textureWidth) * 2.0f - 1.0f;
    float y1 = 1.0f - ((y + h) / (float)_textureHeight) * 2.0f;
    float x2 = ((x + w) / (float)_textureWidth) * 2.0f - 1.0f;
    float y2 = 1.0f - ((y + h * 0.62f) / (float)_textureHeight) * 2.0f;
    const GLfloat vertices[] = {
        x0, y0, 0.0f, 0.0f,
        x1, y1, 0.0f, 0.0f,
        x2, y2, 0.0f, 0.0f,
    };
    glUseProgram(_colorProgram);
    glUniform4f(glGetUniformLocation(_colorProgram, "cursor_color"), r, g, b, 1.0f);
    glBindVertexArray(_vao);
    glBindBuffer(GL_ARRAY_BUFFER, _cursorVbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STREAM_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), 0);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                          (const GLvoid *)(2 * sizeof(GLfloat)));
    glDrawArrays(GL_TRIANGLES, 0, 3);
}

- (void)drawCursor:(const sharp_cursor_snapshot_t *)cursor {
    if (cursor == NULL || !cursor->visible) {
        return;
    }
    glEnable(GL_BLEND);
    sharp_cursor_texture_slot_t *cursorSlot = NULL;
    if (cursor->image_id > 0u && cursor->image_id < SHARP_CURSOR_IMAGE_MAX &&
        _cursorSlots[cursor->image_id].texture != 0u) {
        cursorSlot = &_cursorSlots[cursor->image_id];
    } else if (_cursorSlots[SHARP_CURSOR_IMAGE_ARROW].texture != 0u) {
        cursorSlot = &_cursorSlots[SHARP_CURSOR_IMAGE_ARROW];
    }
    GLuint cursorTexture = cursorSlot != NULL ? cursorSlot->texture : _cursorTexture;
    uint32_t cursorWidth = cursorSlot != NULL ? cursorSlot->width : _cursorTextureWidth;
    uint32_t cursorHeight = cursorSlot != NULL ? cursorSlot->height : _cursorTextureHeight;
    uint16_t hotspotX = cursorSlot != NULL ? cursorSlot->hotspot_x : cursor->hotspot_x;
    uint16_t hotspotY = cursorSlot != NULL ? cursorSlot->hotspot_y : cursor->hotspot_y;
    if (cursorTexture != 0 && cursorWidth > 0 && cursorHeight > 0) {
        float scale = _cursorScale > 0.0f ? _cursorScale : 1.0f;
        float x = (float)cursor->x - (float)hotspotX * scale;
        float y = (float)cursor->y - (float)hotspotY * scale;
        float w = (float)cursorWidth * scale;
        float h = (float)cursorHeight * scale;
        float x0 = (x / (float)_textureWidth) * 2.0f - 1.0f;
        float y0 = 1.0f - (y / (float)_textureHeight) * 2.0f;
        float x1 = ((x + w) / (float)_textureWidth) * 2.0f - 1.0f;
        float y1 = 1.0f - ((y + h) / (float)_textureHeight) * 2.0f;
        const GLfloat vertices[] = {
            x0, y1, 0.0f, 1.0f,
            x1, y1, 1.0f, 1.0f,
            x0, y0, 0.0f, 0.0f,
            x1, y0, 1.0f, 0.0f,
        };
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, cursorTexture);
        glUseProgram(_program);
        glBindVertexArray(_vao);
        glBindBuffer(GL_ARRAY_BUFFER, _cursorVbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STREAM_DRAW);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), 0);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                              (const GLvoid *)(2 * sizeof(GLfloat)));
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    } else {
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    [self drawCursorTriangleX:(float)cursor->x
                            y:(float)cursor->y
                        width:27.0f
                       height:36.0f
                       colorR:0.0f
                            g:0.0f
                            b:0.0f];
    [self drawCursorTriangleX:(float)cursor->x + 3.0f
                            y:(float)cursor->y + 4.0f
                        width:19.0f
                       height:27.0f
                       colorR:1.0f
                            g:1.0f
                            b:1.0f];
    }
    glDisable(GL_BLEND);
    glBindBuffer(GL_ARRAY_BUFFER, _vbo);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), 0);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                          (const GLvoid *)(2 * sizeof(GLfloat)));
}

- (BOOL)loadCursorTexture {
    if (_cursorPath.length == 0) {
        return NO;
    }
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:_cursorPath];
    if (image == nil) {
        fprintf(stderr, "cursor image load failed: %s\n", _cursorPath.UTF8String);
        return NO;
    }
    image = SharpCursorImage(image, _cursorHue);
    NSRect proposed = NSMakeRect(0, 0, image.size.width, image.size.height);
    CGImageRef cgImage = [image CGImageForProposedRect:&proposed
                                               context:nil
                                                 hints:nil];
    if (cgImage == NULL) {
        return NO;
    }
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0 || width > 256 || height > 256) {
        return NO;
    }
    uint8_t *pixels = calloc(width * height, 4u);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = pixels != NULL && colorSpace != NULL
                              ? CGBitmapContextCreate(
                                    pixels, width, height, 8, width * 4u,
                                    colorSpace,
                                    kCGImageAlphaPremultipliedLast |
                                        kCGBitmapByteOrder32Big)
                              : NULL;
    if (colorSpace != NULL) {
        CGColorSpaceRelease(colorSpace);
    }
    if (bitmap == NULL) {
        free(pixels);
        return NO;
    }
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(bitmap);

    glGenTextures(1, &_cursorTexture);
    glBindTexture(GL_TEXTURE_2D, _cursorTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)width,
                 (GLsizei)height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    free(pixels);
    _cursorTextureWidth = (uint32_t)width;
    _cursorTextureHeight = (uint32_t)height;
    return YES;
}

- (BOOL)loadCursorTexturePath:(NSString *)path
                         slot:(sharp_cursor_texture_slot_t *)slot {
    if (path.length == 0 || slot == NULL) {
        return NO;
    }
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    if (image == nil) {
        fprintf(stderr, "cursor image load failed: %s\n", path.UTF8String);
        return NO;
    }
    image = SharpCursorImage(image, _cursorHue);
    NSRect proposed = NSMakeRect(0, 0, image.size.width, image.size.height);
    CGImageRef cgImage = [image CGImageForProposedRect:&proposed
                                               context:nil
                                                 hints:nil];
    if (cgImage == NULL) {
        return NO;
    }
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0 || width > 256 || height > 256) {
        return NO;
    }
    uint8_t *pixels = calloc(width * height, 4u);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = pixels != NULL && colorSpace != NULL
                              ? CGBitmapContextCreate(
                                    pixels, width, height, 8, width * 4u,
                                    colorSpace,
                                    kCGImageAlphaPremultipliedLast |
                                        kCGBitmapByteOrder32Big)
                              : NULL;
    if (colorSpace != NULL) {
        CGColorSpaceRelease(colorSpace);
    }
    if (bitmap == NULL) {
        free(pixels);
        return NO;
    }
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(bitmap);

    if (slot->texture) glDeleteTextures(1, &slot->texture);
    glGenTextures(1, &slot->texture);
    glBindTexture(GL_TEXTURE_2D, slot->texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)width,
                 (GLsizei)height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    free(pixels);
    slot->width = (uint32_t)width;
    slot->height = (uint32_t)height;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length >= 14u) {
        const uint8_t *bytes = data.bytes;
        if (bytes[0] == 0u && bytes[1] == 0u && bytes[2] == 2u &&
            bytes[3] == 0u) {
            slot->hotspot_x = (uint16_t)bytes[10] | ((uint16_t)bytes[11] << 8u);
            slot->hotspot_y = (uint16_t)bytes[12] | ((uint16_t)bytes[13] << 8u);
        }
    }
    return YES;
}

- (void)updateCursorScale:(double)scale hue:(double)hue {
    if (!isfinite(scale) || !isfinite(hue)) return;
    NSOpenGLContext *context = self.openGLContext;
    CGLLockContext(context.CGLContextObj);
    [context makeCurrentContext];
    _cursorScale = (float)MAX(0.6, MIN(2.0, scale));
    hue = MAX(0, MIN(1, hue));
    if (_cursorHue != hue) {
        _cursorHue = hue;
        [self loadCursorThemeTextures];
    }
    CGLUnlockContext(context.CGLContextObj);
    fprintf(stdout, "cursor-style scale=%.3f hue=%.3f\n", _cursorScale, _cursorHue);
    fflush(stdout);
}

- (void)loadCursorThemeTextures {
    if (_cursorDir.length == 0) {
        return;
    }
    static const struct {
        uint32_t image_id;
        __unsafe_unretained NSString *file_name;
    } files[] = {
        { SHARP_CURSOR_IMAGE_ARROW, @"Normal Select.cur" },
        { SHARP_CURSOR_IMAGE_IBEAM, @"Text Select.cur" },
        { SHARP_CURSOR_IMAGE_LINK, @"Link Select.cur" },
        { SHARP_CURSOR_IMAGE_CROSSHAIR, @"Precision Select.cur" },
        { SHARP_CURSOR_IMAGE_MOVE, @"Move.cur" },
        { SHARP_CURSOR_IMAGE_RESIZE_HORIZONTAL, @"horizontal resize.cur" },
        { SHARP_CURSOR_IMAGE_RESIZE_VERTICAL, @"vertical resize.cur" },
        { SHARP_CURSOR_IMAGE_UNAVAILABLE, @"Unavailable.cur" },
        { SHARP_CURSOR_IMAGE_ALTERNATE, @"Alternate Select.cur" },
    };
    uint32_t loaded = 0u;
    for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
        NSString *path = [_cursorDir stringByAppendingPathComponent:files[i].file_name];
        if ([self loadCursorTexturePath:path slot:&_cursorSlots[files[i].image_id]]) {
            loaded++;
        }
    }
    fprintf(stdout, "m1-display-cursor theme_loaded=%u sample_hz=240 prediction_ms=8\n",
            loaded);
}

- (int)bindDecoderTextureLayer:(const sharp_video_layer_snapshot_t *)layer
                          slot:(sharp_video_texture_slot_t *)slot {
    if (layer == NULL || !layer->updated || layer->pixel_buffer == NULL ||
        slot == NULL || layer->header.w == 0 || layer->header.h == 0 ||
        _videoTextureCache == NULL) {
        return 0;
    }
    if (slot->cv_texture != NULL) {
        CFRelease(slot->cv_texture);
        slot->cv_texture = NULL;
    }
    CVOpenGLTextureRef cvTexture = NULL;
    CVReturn cvStatus = CVOpenGLTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, _videoTextureCache, layer->pixel_buffer, NULL,
        &cvTexture);
    if (cvStatus != kCVReturnSuccess || cvTexture == NULL) {
        if (_videoTextureCache != NULL) {
            CVOpenGLTextureCacheFlush(_videoTextureCache, 0);
        }
        return 0;
    }
    GLenum target = CVOpenGLTextureGetTarget(cvTexture);
    GLuint name = CVOpenGLTextureGetName(cvTexture);
    if ((target != GL_TEXTURE_2D && target != GL_TEXTURE_RECTANGLE) ||
        name == 0) {
        CFRelease(cvTexture);
        return 0;
    }
    slot->cv_texture = cvTexture;
    slot->texture_target = target;
    slot->texture_name = name;
    slot->width = layer->header.w;
    slot->height = layer->header.h;
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(slot->texture_target, slot->texture_name);
    glTexParameteri(slot->texture_target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(slot->texture_target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(slot->texture_target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(slot->texture_target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return 2;
}

- (int)bindNv12IOSurfaceLayer:(const sharp_video_layer_snapshot_t *)layer
                         slot:(sharp_video_texture_slot_t *)slot {
    if (layer == NULL || !layer->updated || layer->pixel_buffer == NULL ||
        slot == NULL || layer->header.w == 0 || layer->header.h == 0 ||
        CVPixelBufferGetPixelFormatType(layer->pixel_buffer) !=
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        CVPixelBufferGetPlaneCount(layer->pixel_buffer) < 2) {
        return 0;
    }
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(layer->pixel_buffer);
    if (surface == NULL || IOSurfaceGetPlaneCount(surface) < 2) {
        return 0;
    }
    CGLContextObj cgl = [[self openGLContext] CGLContextObj];
    if (cgl == NULL) {
        return 0;
    }
    size_t yWidth = IOSurfaceGetWidthOfPlane(surface, 0);
    size_t yHeight = IOSurfaceGetHeightOfPlane(surface, 0);
    size_t uvWidth = IOSurfaceGetWidthOfPlane(surface, 1);
    size_t uvHeight = IOSurfaceGetHeightOfPlane(surface, 1);
    if (yWidth < layer->header.w || yHeight < layer->header.h ||
        uvWidth < (layer->header.w + 1u) / 2u ||
        uvHeight < (layer->header.h + 1u) / 2u) {
        return 0;
    }
    if (slot->cv_texture != NULL) {
        CFRelease(slot->cv_texture);
        slot->cv_texture = NULL;
    }
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_RECTANGLE, slot->y_texture);
    CGLError err = CGLTexImageIOSurface2D(
        cgl, GL_TEXTURE_RECTANGLE, GL_R8, (GLsizei)yWidth, (GLsizei)yHeight,
        GL_RED, GL_UNSIGNED_BYTE, surface, 0);
    if (err != kCGLNoError) {
        return 0;
    }
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_RECTANGLE, slot->uv_texture);
    err = CGLTexImageIOSurface2D(
        cgl, GL_TEXTURE_RECTANGLE, GL_RG8, (GLsizei)uvWidth, (GLsizei)uvHeight,
        GL_RG, GL_UNSIGNED_BYTE, surface, 1);
    if (err != kCGLNoError) {
        glActiveTexture(GL_TEXTURE0);
        return 0;
    }
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glActiveTexture(GL_TEXTURE0);
    slot->texture_target = GL_TEXTURE_RECTANGLE;
    slot->texture_name = slot->y_texture;
    slot->width = layer->header.w;
    slot->height = layer->header.h;
    slot->nv12_matrix = nv12_matrix_for_pixel_buffer(layer->pixel_buffer);
    return 3;
}

- (int)uploadVideoLayer:(const sharp_video_layer_snapshot_t *)layer
                   slot:(sharp_video_texture_slot_t *)slot {
    if (layer == NULL || !layer->updated || layer->pixel_buffer == NULL ||
        slot == NULL || layer->header.w == 0 || layer->header.h == 0 ||
        CVPixelBufferGetPixelFormatType(layer->pixel_buffer) !=
            kCVPixelFormatType_32BGRA) {
        return 0;
    }
    if (slot->cv_texture != NULL) {
        CFRelease(slot->cv_texture);
        slot->cv_texture = NULL;
    }
    if (CVPixelBufferLockBaseAddress(layer->pixel_buffer,
                                     kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        return -1;
    }
    const uint8_t *src = CVPixelBufferGetBaseAddress(layer->pixel_buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(layer->pixel_buffer);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)(stride / 4u));
    glActiveTexture(GL_TEXTURE0);
    slot->texture_target = GL_TEXTURE_2D;
    slot->texture_name = slot->bgra_texture;
    glBindTexture(GL_TEXTURE_2D, slot->bgra_texture);
    if (slot->width != layer->header.w || slot->height != layer->header.h) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)layer->header.w,
                     (GLsizei)layer->header.h, 0, GL_BGRA, GL_UNSIGNED_BYTE,
                     src);
        slot->width = layer->header.w;
        slot->height = layer->header.h;
    } else {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)layer->header.w,
                        (GLsizei)layer->header.h, GL_BGRA, GL_UNSIGNED_BYTE,
                        src);
    }
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    CVPixelBufferUnlockBaseAddress(layer->pixel_buffer,
                                   kCVPixelBufferLock_ReadOnly);
    return 1;
}

- (int)uploadMotionMask:(const uint8_t *)motionMask bytes:(uint32_t)motionMaskBytes {
    if (motionMask == NULL || motionMaskBytes == 0 ||
        motionMaskBytes > SHARP_MOTION_MASK_MAX_BYTES ||
        _motionMaskTexture == 0) {
        return -1;
    }
    if (_motionMaskTextureBytes == motionMaskBytes &&
        memcmp(_motionMaskTextureData, motionMask, motionMaskBytes) == 0) {
        return 0;
    }
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, _motionMaskTexture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, (GLsizei)motionMaskBytes, 1, 0,
                 GL_RED, GL_UNSIGNED_BYTE, motionMask);
    memcpy(_motionMaskTextureData, motionMask, motionMaskBytes);
    _motionMaskTextureBytes = motionMaskBytes;
    glActiveTexture(GL_TEXTURE0);
    return 0;
}

- (int)renderFramebuf:(const sharp_framebuf_t *)fb
        viewportWidth:(uint32_t)viewportWidth
       viewportHeight:(uint32_t)viewportHeight
          dirtyBounds:(const sharp_dirty_bounds_t *)dirtyBounds
          videoLayers:(const sharp_video_layer_snapshot_t *)videoLayers
       videoLayerCount:(size_t)videoLayerCount
     deactivateRegions:(const uint16_t *)deactivateRegions
 deactivateRegionCount:(size_t)deactivateRegionCount
            motionMask:(const uint8_t *)motionMask
       motionMaskBytes:(uint32_t)motionMaskBytes
               cursor:(const sharp_cursor_snapshot_t *)cursor {
    NSOpenGLContext *context = [self openGLContext];
    CGLContextObj cgl = [context CGLContextObj];
    CGLLockContext(cgl);
    [context makeCurrentContext];
    _lastVideoUpdateKind = 0;

    if (fb == NULL || fb->pixels == NULL) {
        [self drawCurrentTextureWithViewportWidth:viewportWidth
                                   viewportHeight:viewportHeight];
        [self drawCursor:cursor];
        [context flushBuffer];
        CGLUnlockContext(cgl);
        return 0;
    }

    int uploadKind = 0;
    if (_textureWidth != fb->width || _textureHeight != fb->height) {
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)(fb->stride / 4u));
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, _texture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)fb->width,
                     (GLsizei)fb->height, 0, GL_BGRA, GL_UNSIGNED_BYTE,
                     fb->pixels);
        _textureWidth = fb->width;
        _textureHeight = fb->height;
        uploadKind = 2;
    } else if (dirtyBounds != NULL && dirtyBounds->valid &&
               dirtyBounds->w > 0 && dirtyBounds->h > 0) {
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)(fb->stride / 4u));
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, _texture);
        const uint8_t *src =
            fb->pixels + (size_t)dirtyBounds->y * fb->stride +
            (size_t)dirtyBounds->x * 4u;
        glTexSubImage2D(GL_TEXTURE_2D, 0, (GLint)dirtyBounds->x,
                        (GLint)dirtyBounds->y, (GLsizei)dirtyBounds->w,
                        (GLsizei)dirtyBounds->h, GL_BGRA, GL_UNSIGNED_BYTE,
                        src);
        uploadKind = (dirtyBounds->x == 0 && dirtyBounds->y == 0 &&
                      dirtyBounds->w == fb->width &&
                      dirtyBounds->h == fb->height)
                         ? 2
                         : 1;
    }
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);

    BOOL maskedOverlay = motionMask != NULL && motionMaskBytes > 0 &&
                         videoLayerCount > 0 &&
                         [self uploadMotionMask:motionMask
                                          bytes:motionMaskBytes] == 0;
    if (!maskedOverlay) {
        [self drawCurrentTextureWithViewportWidth:viewportWidth
                                   viewportHeight:viewportHeight];
    } else {
        [self setDrawableViewportWidth:viewportWidth
                          drawableHeight:viewportHeight
                                    clear:YES];
    }
    for (size_t i = 0; i < deactivateRegionCount; i++) {
        [self releaseVideoRegion:deactivateRegions[i]];
    }
    for (size_t i = 0; videoLayers != NULL && i < videoLayerCount; i++) {
        const sharp_video_layer_snapshot_t *videoLayer = &videoLayers[i];
        if (!videoLayer->active) {
            continue;
        }
        sharp_video_texture_slot_t *slot =
            [self slotForRegion:videoLayer->region_id create:YES];
        if (slot == NULL) {
            continue;
        }
        slot->last_update_kind = 0;
        if (videoLayer->updated) {
            int videoUpload = 0;
            if (_videoTextureMode == SHARP_VIDEO_TEXTURE_NV12) {
                videoUpload = [self bindNv12IOSurfaceLayer:videoLayer slot:slot];
            } else if (_videoTextureMode == SHARP_VIDEO_TEXTURE_DECODER) {
                videoUpload = [self bindDecoderTextureLayer:videoLayer slot:slot];
                if (videoUpload == 0) {
                    videoUpload = [self uploadVideoLayer:videoLayer slot:slot];
                }
            } else {
                videoUpload = [self uploadVideoLayer:videoLayer slot:slot];
            }
            slot->last_update_kind = videoUpload;
            if (videoUpload > _lastVideoUpdateKind) {
                _lastVideoUpdateKind = videoUpload;
            }
        }
        if (slot->texture_name != 0) {
            [self drawVideoLayer:videoLayer slot:slot];
        }
    }
    _testVideoPPM = nil;
    // Read back the very same decoded frame before adding lossless overlays.
    // Enabled only for the existing diagnostic snapshot run; never a timing test.
    if (maskedOverlay && getenv("SHARP_TEST_HYBRID_SNAPSHOTS") &&
        strcmp(getenv("SHARP_TEST_HYBRID_SNAPSHOTS"), "1") == 0) {
        size_t row = (size_t)viewportWidth * 3;
        NSMutableData *pixels = [NSMutableData dataWithLength:row * viewportHeight];
        glReadBuffer(GL_BACK);
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(0, 0, viewportWidth, viewportHeight, GL_RGB, GL_UNSIGNED_BYTE, pixels.mutableBytes);
        if (glGetError() == GL_NO_ERROR) {
            NSMutableData *ppm = [NSMutableData dataWithData:
                [[NSString stringWithFormat:@"P6\n%u %u\n255\n", viewportWidth, viewportHeight]
                 dataUsingEncoding:NSASCIIStringEncoding]];
            for (uint32_t y = 0; y < viewportHeight; y++)
                [ppm appendBytes:(const uint8_t *)pixels.bytes + (viewportHeight - 1 - y) * row length:row];
            _testVideoPPM = ppm;
        }
    }
    if (maskedOverlay) {
        [self drawCurrentTextureMaskedInDrawableWidth:viewportWidth
                                         drawableHeight:viewportHeight
                                        motionMaskBytes:motionMaskBytes];
    }
    [self drawCursor:cursor];
    [context flushBuffer];
    CGLUnlockContext(cgl);
    return uploadKind;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect backing = [self convertRectToBacking:self.bounds];
    (void)[self renderFramebuf:NULL
                 viewportWidth:(uint32_t)MAX(1.0, floor(backing.size.width))
                viewportHeight:(uint32_t)MAX(1.0, floor(backing.size.height))
                   dirtyBounds:NULL
                   videoLayers:NULL
               videoLayerCount:0
             deactivateRegions:NULL
         deactivateRegionCount:0
                   motionMask:NULL
              motionMaskBytes:0
                       cursor:NULL];
}

- (int)writePresenterSnapshotPath:(const char *)path {
    if (path == NULL) {
        return -1;
    }
    NSOpenGLContext *context = [self openGLContext];
    if (context == nil) {
        return -1;
    }
    CGLContextObj cgl = [context CGLContextObj];
    if (cgl == NULL) {
        return -1;
    }

    CGLLockContext(cgl);
    [context makeCurrentContext];
    NSRect backing = [self convertRectToBacking:self.bounds];
    uint32_t width = (uint32_t)MAX(1.0, floor(backing.size.width));
    uint32_t height = (uint32_t)MAX(1.0, floor(backing.size.height));
    size_t rowBytes = (size_t)width * 3u;
    size_t bytes = rowBytes * (size_t)height;
    uint8_t *pixels = malloc(bytes);
    if (pixels == NULL) {
        CGLUnlockContext(cgl);
        return -1;
    }

    glReadBuffer(GL_FRONT);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_RGB,
                 GL_UNSIGNED_BYTE, pixels);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        glReadBuffer(GL_BACK);
        glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_RGB,
                     GL_UNSIGNED_BYTE, pixels);
        err = glGetError();
    }
    CGLUnlockContext(cgl);
    if (err != GL_NO_ERROR) {
        free(pixels);
        return -1;
    }

    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        free(pixels);
        return -1;
    }
    fprintf(f, "P6\n%u %u\n255\n", width, height);
    for (uint32_t y = 0; y < height; y++) {
        uint32_t srcY = height - 1u - y;
        if (fwrite(pixels + (size_t)srcY * rowBytes, 1, rowBytes, f) !=
            rowBytes) {
            fclose(f);
            free(pixels);
            return -1;
        }
    }
    fclose(f);
    free(pixels);
    if (_testVideoPPM)
        [_testVideoPPM writeToFile:[[NSString stringWithUTF8String:path] stringByAppendingString:@".video.ppm"] atomically:YES];
    return 0;
}

- (void)dealloc {
    [[self openGLContext] makeCurrentContext];
    if (_texture != 0) {
        glDeleteTextures(1, &_texture);
    }
    if (_motionMaskTexture != 0) {
        glDeleteTextures(1, &_motionMaskTexture);
    }
    if (_cursorTexture != 0) {
        glDeleteTextures(1, &_cursorTexture);
    }
    for (size_t i = 0; i < SHARP_CURSOR_IMAGE_MAX; i++) {
        if (_cursorSlots[i].texture != 0u) {
            glDeleteTextures(1, &_cursorSlots[i].texture);
        }
    }
    for (size_t i = 0; i < SHARP_MAX_VIDEO_REGIONS; i++) {
        [self releaseVideoSlot:&_videoSlots[i]];
        if (_videoSlots[i].bgra_texture != 0) {
            glDeleteTextures(1, &_videoSlots[i].bgra_texture);
        }
        if (_videoSlots[i].y_texture != 0) {
            glDeleteTextures(1, &_videoSlots[i].y_texture);
        }
        if (_videoSlots[i].uv_texture != 0) {
            glDeleteTextures(1, &_videoSlots[i].uv_texture);
        }
    }
    if (_videoTextureCache != NULL) {
        CVOpenGLTextureCacheFlush(_videoTextureCache, 0);
        CFRelease(_videoTextureCache);
        _videoTextureCache = NULL;
    }
    if (_vbo != 0) {
        glDeleteBuffers(1, &_vbo);
    }
    if (_videoVbo != 0) {
        glDeleteBuffers(1, &_videoVbo);
    }
    if (_cursorVbo != 0) {
        glDeleteBuffers(1, &_cursorVbo);
    }
    if (_vao != 0) {
        glDeleteVertexArrays(1, &_vao);
    }
    if (_program != 0) {
        glDeleteProgram(_program);
    }
    if (_maskProgram != 0) {
        glDeleteProgram(_maskProgram);
    }
    if (_rectProgram != 0) {
        glDeleteProgram(_rectProgram);
    }
    if (_nv12Program != 0) {
        glDeleteProgram(_nv12Program);
    }
    if (_colorProgram != 0) {
        glDeleteProgram(_colorProgram);
    }
}
@end
