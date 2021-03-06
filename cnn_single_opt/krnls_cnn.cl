// DATA type and shape precisions
#define DATA_TYPE float
#define DATA_SHAPE uchar

// Helper function for relu layer after aggregation
DATA_TYPE relu(DATA_TYPE activation)
{
    return max((DATA_TYPE)0, activation);
}

// Helper function to generate index of a 2D mem block
size_t getIdx2D(const size_t y, const size_t x, const size_t width)
{
    return x + y * width;
}

// Helper function to generate index of a 3D mem block
size_t getIdx3D(const size_t z, const size_t y, const size_t x,
                            const size_t width, const size_t height)
{
    return x + y * (width) + z * (width * height);
}

// Model Parameter Sizes
#define C1_W (5 * 5 * 32)
#define C1_B (32)
#define C2_W (5 * 5 * 32 * 64)
#define C2_B (64)
#define D1_W (1024 * 256)
#define D1_B (256)
#define D2_W (256 * 10)
#define D2_B (10)

// On-Chip Constant Memory for CNN Model
global DATA_TYPE wc1[C1_W];  // CONV1 weights
global DATA_TYPE bc1[C1_B];  // CONV1 biases
global DATA_TYPE wc2[C2_W];  // CONV2 weights
global DATA_TYPE bc2[C2_B];  // CONV2 biases
global DATA_TYPE wd1[D1_W];  // FC1   weights
global DATA_TYPE bd1[D1_B];  // FC1   biases
global DATA_TYPE wd2[D2_W];  // FC2   weights
global DATA_TYPE bd2[D2_B];  // FC2   biases

// A Kernel only to Move Off-Chip Constant memory to
// On-Chip Global Memory. CNN model parameters are 
// constant across different inference passes.
__kernel __attribute__((reqd_work_group_size(1,1,1)))
void load_model_ocm(__constant DATA_TYPE * conv1_w, __constant DATA_TYPE * conv1_b,
                    __constant DATA_TYPE * conv2_w, __constant DATA_TYPE * conv2_b,
                    __constant DATA_TYPE * fc1_w,   __constant DATA_TYPE * fc1_b,
                    __constant DATA_TYPE * fc2_w,   __constant DATA_TYPE * fc2_b)
{
    for(ushort i = 0; i < C1_W; ++i)
        wc1[i] = conv1_w[i];
    for(uchar i = 0; i < C1_B; ++i)
        bc1[i] = conv1_b[i];
    for(ushort i = 0; i < C2_W; ++i)
        wc2[i] = conv2_w[i];
    for(uchar i = 0; i < C2_B; ++i)
        bc2[i] = conv2_b[i];
    for(uint i = 0; i < D1_W; ++i)
        wd1[i] = fc1_w[i];
//    for(uchar i = 0; i < D1_B; ++i)
    for(ushort i = 0; i < D1_B; ++i)
        bd1[i] = fc1_b[i];
    for(ushort i = 0; i < D2_W; ++i)
        wd2[i] = fc2_w[i];
    for(uchar i = 0; i < D2_B; ++i)
        bd2[i] = fc2_b[i];
    return;
}


// Max pooling layer 1 with
// poolsize: 2x2
// stride equal to poolsize
// and 'SAME' padding policy
// 24x24 --> 12x12 
// (num of feature maps defined by 3rd dim of global work size)
__kernel __attribute__((reqd_work_group_size(4, 4, 4)))
void max_pool1(__global DATA_TYPE * in, __global DATA_TYPE * out)
{
    size_t w = get_global_id(0);
    size_t h = get_global_id(1);
    size_t d = get_global_id(2);
    size_t idx_tl = w*2 + 24 * (h*2 + d * 24);
    size_t idx_tr = w*2 + 1 + 24 * (h*2 + d * 24);
    size_t idx_bl = w*2 + 24 * (h*2 + 1 + d * 24);
    size_t idx_br = w*2 + 1 + 24 * (h*2 + 1 + d * 24);
    size_t out_idx = w + 12 * (h + d * 12);

    out[out_idx] = max(in[idx_tl], max(in[idx_tr], max(in[idx_bl], in[idx_br])));
    return;
}

// Max pooling layer 2 with
// poolsize: 2x2
// stride equal to poolsize
// and 'SAME' padding policy
// 8x8 --> 4x4 
// (num of feature maps defined by 3rd dim of global work size)
__kernel __attribute__((reqd_work_group_size(4, 4, 4)))
void max_pool2(__global DATA_TYPE * in, __global DATA_TYPE * out)
{
    size_t w = get_global_id(0);
    size_t h = get_global_id(1);
    size_t d = get_global_id(2);
    size_t idx_tl = w*2 + 8 * (h*2 + d * 8);
    size_t idx_tr = w*2 + 1 + 8 * (h*2 + d * 8);
    size_t idx_bl = w*2 + 8 * (h*2 + 1 + d * 8);
    size_t idx_br = w*2 + 1 + 8 * (h*2 + 1 + d * 8);
    size_t out_idx = w + 4 * (h + d * 4);

    out[out_idx] = max(in[idx_tl], max(in[idx_tr], max(in[idx_bl], in[idx_br])));
    return;
}

// Conv layer 1 with local memory
// kernel mask: 5x5
// stride: 1
// and 'VALID' padding policy
// 28x28x1 --> 24x24x32
#define CONV1_WG_X  4
#define CONV1_WG_Y  4
#define CONV1_WG_Z  4
#define MASK1_SIZE  5
#define MASK1_DEPTH 32
#define TILE1_X (CONV1_WG_X+MASK1_SIZE-1)
#define TILE1_Y (CONV1_WG_Y+MASK1_SIZE-1)
#define IWIDTH1  28  // Input width of convolution
#define IHEIGHT1 28  // Input height of convolution
#define OWIDTH1  24  // Output width of convolution
#define OHEIGHT1 24  // Output width of convolution

__kernel __attribute__((reqd_work_group_size(CONV1_WG_X, CONV1_WG_Y, CONV1_WG_Z)))
void conv1(__global DATA_TYPE * in, __global DATA_TYPE * out,
                __constant DATA_TYPE * weight, __constant DATA_TYPE * biases)
{
    __local DATA_TYPE tile[TILE1_X * TILE1_Y];

//    size_t w = get_global_id(0);
//    size_t h = get_global_id(1);
//    size_t d = get_global_id(2);
//
//    event_t event;
//    size_t in_idx = get_group_id(0) * CONV1_WG_X + get_group_id(1) * CONV1_WG_Y * IWIDTH1;
//    size_t out_idx = w + OWIDTH1 * (h + OHEIGHT1 * d);
//
//    DATA_TYPE c = (DATA_TYPE)0;
//    __attribute__((xcl_pipeline_loop))
//    for(size_t cd = 0; cd < MASK1_DEPTH; ++cd)
//    {
//        for(size_t i = 0; i < TILE1_Y; ++i)
//            event = async_work_group_copy(&tile[i * TILE1_X], &in[in_idx + i * IWIDTH1], TILE1_X, event);
//        in_idx += IHEIGHT1 * IWIDTH1;
//
//        wait_group_events(1, &event);
//        barrier(CLK_LOCAL_MEM_FENCE);
//
//        for(size_t ch = 0; ch < MASK1_SIZE; ++ch)
//        {
//            for(size_t cw = 0; cw < MASK1_SIZE; ++cw)
//            {
//                c += tile[getIdx2D(ch + get_local_id(1), cw + get_local_id(0), TILE1_X)]
//                * weight[cw + (ch + cd * MASK1_SIZE) * MASK1_SIZE + d * MASK1_SIZE * MASK1_SIZE * MASK1_DEPTH];
//            }
//        }
//    }
//    out[out_idx] = relu(c + biases[d]);
//    out[out_idx] = relu(c + bc1[d]);
    return;
}

// Conv layer 2 with local memory
// kernel mask: 5x5
// stride: 1
// and 'VALID' padding policy
// 12x12x32 --> 8x8x64
#define CONV2_WG_X  4
#define CONV2_WG_Y  4
#define CONV2_WG_Z  4
#define MASK2_SIZE  5
#define MASK2_DEPTH 64
#define TILE2_X (CONV1_WG_X+MASK2_SIZE-1)
#define TILE2_Y (CONV1_WG_Y+MASK2_SIZE-1)
#define IWIDTH2  12  // Input width of convolution
#define IHEIGHT2 12  // Input height of convolution
#define OWIDTH2   8  // Output width of convolution
#define OHEIGHT2  8  // Output width of convolution

__kernel __attribute__((reqd_work_group_size(CONV2_WG_X, CONV2_WG_Y, CONV2_WG_Z)))
void conv2(__global DATA_TYPE * in, __global DATA_TYPE * out,
                __constant DATA_TYPE * weight, __constant DATA_TYPE * biases)
{
    __local DATA_TYPE tile[TILE2_X * TILE2_Y];

    size_t w = get_global_id(0);
    size_t h = get_global_id(1);
    size_t d = get_global_id(2);

    event_t event;
    size_t in_idx = get_group_id(0) * CONV2_WG_X + get_group_id(1) * CONV2_WG_Y * IWIDTH2;
    size_t out_idx = w + OWIDTH2 * (h + OHEIGHT2 * d);

    DATA_TYPE c = (DATA_TYPE)0;
    __attribute__((xcl_pipeline_loop))
    for(size_t cd = 0; cd < MASK2_DEPTH; ++cd)
    {
        for(size_t i = 0; i < TILE2_Y; ++i)
            event = async_work_group_copy(&tile[i * TILE2_X], &in[in_idx + i * IWIDTH2], TILE2_X, event);
        in_idx += IHEIGHT2 * IWIDTH2;

        wait_group_events(1, &event);
        barrier(CLK_LOCAL_MEM_FENCE);

        for(size_t ch = 0; ch < MASK2_SIZE; ++ch)
        {
            for(size_t cw = 0; cw < MASK2_SIZE; ++cw)
            {
                c += tile[getIdx2D(ch + get_local_id(1), cw + get_local_id(0), TILE2_X)]
                * weight[cw + (ch + cd * MASK2_SIZE) * MASK2_SIZE + d * MASK2_SIZE * MASK2_SIZE * MASK2_DEPTH];
            }
        }
    }
    out[out_idx] = relu(c + biases[d]);
//    out[out_idx] = relu(c + bc2[d]);
    return;
}

// Fully connected layer
// kernel launch grid based on
// number of output neuron

#define INEURON1 1024 // num of input neuron for fc1
#define ONEURON1 256  // num of output neuron for fc1
// Number of work-groups is 32
__kernel __attribute__((reqd_work_group_size((ONEURON1/32), 1, 1)))
void fc1(__global DATA_TYPE * in, __global DATA_TYPE * out,
        __constant DATA_TYPE * weights, __constant DATA_TYPE * biases)
//void fc1(__global DATA_TYPE * in, __global DATA_TYPE * out)
{
    size_t neuron = get_global_id(0);
    DATA_TYPE n = 0;
    __attribute__((xcl_pipeline_loop))
    for(size_t c = 0; c < INEURON1; ++c)
    {
//        n += in[c] * wd1[neuron * INEURON1 + c];
        n += in[c] * weights[neuron * INEURON1 + c];
    }
//    out[neuron] = relu(n + bd1[neuron]);
    out[neuron] = relu(n + biases[neuron]);
    return;
}

#define INEURON2 256 // num of input neuron for fc2
#define ONEURON2 10  // num of output neuron for fc2
// Number of work-groups is 2
__kernel __attribute__((reqd_work_group_size((ONEURON2/2), 1, 1)))
void fc2(__global DATA_TYPE * in, __global DATA_TYPE * out,
        __constant DATA_TYPE * weights, __constant DATA_TYPE * biases)
//void fc2(__global DATA_TYPE * in, __global DATA_TYPE * out)
{
    size_t neuron = get_global_id(0);
    DATA_TYPE n = 0;
    __attribute__((xcl_pipeline_loop))
    for(size_t c = 0; c < INEURON2; ++c)
    {
//        n += in[c] * wd2[neuron * INEURON2 + c];
        n += in[c] * weights[neuron * INEURON2 + c];
    }
//    out[neuron] = relu(n + bd2[neuron]);
    out[neuron] = relu(n + biases[neuron]);
    return;
}

__kernel  __attribute__((reqd_work_group_size(1, 1, 1)))
void softmax_layer(__global DATA_TYPE * in, __global DATA_TYPE * out)
{
    DATA_TYPE soft[10];
    DATA_TYPE sum_exp = 0;
    __attribute__((xcl_pipeline_loop))
    for(uchar i = 0; i < 10; ++i)
    {
        soft[i] = native_exp(in[i]);
        sum_exp += soft[i];
    }

    for(uchar i = 0; i < 10; ++i)
    {
        out[i] = soft[i] / sum_exp;
    }
    return;
}

