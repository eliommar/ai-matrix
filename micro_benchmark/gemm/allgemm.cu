#include <iostream>
#include <curand.h>
#include <cublas_v2.h>
#include <iomanip>

#define MAX(x, y) ((x>y) ? x : y)
// Define some error checking macros.
#define cudaErrCheck(stat) { cudaErrCheck_((stat), __FILE__, __LINE__); }
void cudaErrCheck_(cudaError_t stat, const char *file, int line) {
	if (stat != cudaSuccess) {
		fprintf(stderr, "CUDA Error: %s %s %d\n", cudaGetErrorString(stat), file, line);
	}
}

#define cublasErrCheck(stat) { cublasErrCheck_((stat), __FILE__, __LINE__); }
void cublasErrCheck_(cublasStatus_t stat, const char *file, int line) {
	if (stat != CUBLAS_STATUS_SUCCESS) {
		fprintf(stderr, "cuBLAS Error: %d %s %d\n", stat, file, line);
	}
}

#define curandErrCheck(stat) { curandErrCheck_((stat), __FILE__, __LINE__); }
void curandErrCheck_(curandStatus_t stat, const char *file, int line) {
	if (stat != CURAND_STATUS_SUCCESS) {
		fprintf(stderr, "cuRand Error: %d %s %d\n", stat, file, line);
	}
}


double cal_tflops(int m, int n, int k, double msec)
{
    double flops = 2. * m * n * k;
    double tflops = (1E-12*flops) / (1E-3*msec);
    return tflops;
}

 

__global__ void assignFloatValue (float *out, int n, float value) {
	int idx = blockDim.x * blockIdx.x + threadIdx.x;
	if (idx < n) {
		out[idx] = value;
	}
}

__global__ void assignHalfValue (half *out, int n, float value) {
	int idx = blockDim.x * blockIdx.x + threadIdx.x;
	if (idx < n) {
		out[idx] = value;
	}
}
void correctnessCheck(int m, int n, int k, float *host, float value){
        for (int i = 0; i < m * n; i++) {      
            float val = host[i];
            if ( val != k * value * value) {
                std::cout << "ERROR value = " << val<< std::endl;
            }
        }
}

void printTime(float cublasTime, int m, int n, int k, float &s_max_tflops){
        float tflops = cal_tflops(m, n, k, cublasTime);
        s_max_tflops = MAX(tflops, s_max_tflops);
        std::cout << std::setw(7) << m << ",";
        std::cout << std::setw(7) << n << ",";
        std::cout << std::setw(7) << k << ",";
        std::cout << std::setw(15) << std::setprecision(4) << cublasTime << ",";
        std::cout << std::setw(15) << std::setprecision(4) << tflops << "," << std::endl;
}


int main(int argc, char* argv[]) {
    int m,n,k;
    int start = 512;
    int end = 10240;
    if (argc < 3) {
        return 0;
    }
    start = std::atoi(argv[1]);
    end = std::atoi(argv[2]);
    
    
    std::cout << "[TensorCore INT8(INT32 accumulation) Time and TOPS Result]" << std::endl;
    std::cout << std::setw(7) << "m" << std::setw(7) << "n" << std::setw(7) << "k";
    std::cout << std::setw(15) << "Time (msec)" << std::setw(15) << "TOPS";
    std::cout << std::endl;
    float s_max_tflops = 0;
    // for tensorcore test
    for (int i=start; i<=end; i+= 1024){
        m = n = k = i;
  
        int8_t *a_fp16;
        int8_t *b_fp16;
        int *c_cublas;
        int *c_host_cublas;
        //const int  value = 1;

   
        cublasHandle_t cublasHandle;

        cudaEvent_t startcublas;
        cudaEvent_t stopcublas;

        cudaErrCheck(cudaEventCreate(&startcublas));
        cudaErrCheck(cudaEventCreate(&stopcublas));
        cublasErrCheck(cublasCreate(&cublasHandle));
        // Use tensor cores
        cublasErrCheck(cublasSetMathMode(cublasHandle, CUBLAS_TENSOR_OP_MATH));

        cudaErrCheck(cudaMalloc((void**)&a_fp16, m * k * sizeof(int8_t)));
        cudaErrCheck(cudaMalloc((void**)&b_fp16, k * m * sizeof(int8_t)));
        cudaErrCheck(cudaMalloc((void**)&c_cublas, m * n * sizeof(int)));
        c_host_cublas = (int*)malloc(m * n * sizeof(int));

        //TODO curand doesn't currently support fp16 so we generate in fp32 and convert to fp16.
        //assignHalfValue <<< (m * k + 255) / 256, 256 >>> (a_fp16, m*k, value);
        //assignHalfValue <<< (k * n + 255) / 256, 256 >>> (b_fp16, k*n, value);
        //assignHalfValue <<< (k * n + 255) / 256, 256 >>> (c_cublas, m*n, 0.0f);

        int alpha = 1;
        int beta = 0;
        int numRepeats = 50;
        // Warp up
        cublasErrCheck(cublasGemmEx(cublasHandle, CUBLAS_OP_N, CUBLAS_OP_N, 
            m, n, k, 
            &alpha,
            a_fp16, CUDA_R_8I, m,
            b_fp16, CUDA_R_8I, k,
            &beta, 
            c_cublas, CUDA_R_32I, m,
            CUDA_R_32I, CUBLAS_GEMM_DFALT_TENSOR_OP));

        // Now using cuBLAS
        cudaErrCheck(cudaEventRecord(startcublas));
        for (int iteration = 0; iteration < numRepeats; ++iteration) {
        cublasErrCheck(cublasGemmEx(cublasHandle, CUBLAS_OP_N, CUBLAS_OP_N, 
                    m, n, k, 
                    &alpha,
                    a_fp16, CUDA_R_8I, m,
                    b_fp16, CUDA_R_8I, k,
                    &beta, 
                    c_cublas, CUDA_R_32I, m,
                    CUDA_R_32I, CUBLAS_GEMM_DFALT_TENSOR_OP));
        }
        cudaErrCheck(cudaEventRecord(stopcublas));
        cudaErrCheck(cudaEventSynchronize(stopcublas));
        // TODO: Correctness check
        //cudaErrCheck(cudaMemcpy(c_host_cublas, c_cublas, m * n * sizeof(float), cudaMemcpyDeviceToHost));
       //correctnessCheck(m, n, k, c_host_cublas, value);
        // Check time
        float cublasTime;	
        cudaErrCheck(cudaEventElapsedTime(&cublasTime, startcublas, stopcublas)); 
        cublasTime /= numRepeats;
        printTime(cublasTime, m, n, k, s_max_tflops);
        
        cudaErrCheck(cudaEventDestroy(startcublas));             
        cudaErrCheck(cudaEventDestroy(stopcublas));
        cudaErrCheck(cudaFree(a_fp16));
        cudaErrCheck(cudaFree(b_fp16));
        cudaErrCheck(cudaFree(c_cublas));
        free(c_host_cublas);
    }
    std::cout << "[Peak TOPS]" << std::endl << std::setprecision(4) << s_max_tflops << std::endl;
    cudaErrCheck(cudaDeviceReset());
    

    std::cout << "[TensorCore FP16(FP16 accumulation) Time and TFLOPS Result]" << std::endl;
    std::cout << std::setw(7) << "m" << std::setw(7) << "n" << std::setw(7) << "k";
    std::cout << std::setw(15) << "Time (msec)" << std::setw(15) << "TFLOPS";
    std::cout << std::endl;
    s_max_tflops = 0;
    // for tensorcore test
    for (int i=start; i<=end; i+= 1024){
        m = n = k = i;
  
        half *a_fp16;
        half *b_fp16;
        half *c_cublas;
        float *c_host_cublas;
        const float  value = 1.0f;

   
        cublasHandle_t cublasHandle;

        cudaEvent_t startcublas;
        cudaEvent_t stopcublas;

        cudaErrCheck(cudaEventCreate(&startcublas));
        cudaErrCheck(cudaEventCreate(&stopcublas));
        cublasErrCheck(cublasCreate(&cublasHandle));
        // Use tensor cores
        cublasErrCheck(cublasSetMathMode(cublasHandle, CUBLAS_TENSOR_OP_MATH));

        cudaErrCheck(cudaMalloc((void**)&a_fp16, m * k * sizeof(half)));
        cudaErrCheck(cudaMalloc((void**)&b_fp16, k * m * sizeof(half)));
        cudaErrCheck(cudaMalloc((void**)&c_cublas, m * n * sizeof(half)));
        c_host_cublas = (float*)malloc(m * n * sizeof(float));

        // curand doesn't currently support fp16 so we generate in fp32 and convert to fp16.
        assignHalfValue <<< (m * k + 255) / 256, 256 >>> (a_fp16, m*k, value);
        assignHalfValue <<< (k * n + 255) / 256, 256 >>> (b_fp16, k*n, value);
        assignHalfValue <<< (k * n + 255) / 256, 256 >>> (c_cublas, m*n, 0.0f);

        float alpha = 1.0f;
        float beta = 0.0f;
        int numRepeats = 50;
        // Warp up
        cublasErrCheck(cublasGemmEx(cublasHandle, CUBLAS_OP_N, CUBLAS_OP_N, 
            m, n, k, 
            &alpha,
            a_fp16, CUDA_R_16F, m,
            b_fp16, CUDA_R_16F, k,
            &beta, 
            c_cublas, CUDA_R_16F, m,
            CUDA_R_16F, CUBLAS_GEMM_DFALT_TENSOR_OP));

        // Now using cuBLAS
        cudaErrCheck(cudaEventRecord(startcublas));
        for (int iteration = 0; iteration < numRepeats; ++iteration) {
        cublasErrCheck(cublasGemmEx(cublasHandle, CUBLAS_OP_N, CUBLAS_OP_N, 
                    m, n, k, 
                    &alpha,
                    a_fp16, CUDA_R_16F, m,
                    b_fp16, CUDA_R_16F, k,
                    &beta, 
                    c_cublas, CUDA_R_16F, m,
                    CUDA_R_16F, CUBLAS_GEMM_DFALT_TENSOR_OP));
        }
        cudaErrCheck(cudaEventRecord(stopcublas));
        cudaErrCheck(cudaEventSynchronize(stopcublas));
        // TODO: Correctness check
        //cudaErrCheck(cudaMemcpy(c_host_cublas, c_cublas, m * n * sizeof(float), cudaMemcpyDeviceToHost));
       //correctnessCheck(m, n, k, c_host_cublas, value);
        // Check time
        float cublasTime;	
        cudaErrCheck(cudaEventElapsedTime(&cublasTime, startcublas, stopcublas)); 
        cublasTime /= numRepeats;
        printTime(cublasTime, m, n, k, s_max_tflops);
        
        cudaErrCheck(cudaEventDestroy(startcublas));             
        cudaErrCheck(cudaEventDestroy(stopcublas));
        cudaErrCheck(cudaFree(a_fp16));
        cudaErrCheck(cudaFree(b_fp16));
        cudaErrCheck(cudaFree(c_cublas));
        free(c_host_cublas);
    }
    std::cout << "[Peak TFLOPS]" << std::endl << std::setprecision(4) << s_max_tflops << std::endl;
    cudaErrCheck(cudaDeviceReset());
    
 
    std::cout << "[TensorCore FP16(FP32 accumulation) Time and TFLOPS Result]" << std::endl;
    std::cout << std::setw(7) << "m" << std::setw(7) << "n" << std::setw(7) << "k";
    std::cout << std::setw(15) << "Time (msec)" << std::setw(15) << "TFLOPS";
    std::cout << std::endl;
    s_max_tflops = 0;
    // for tensorcore test
    for (int i=start; i<=end; i+= 1024){
        m = n = k = i;
  
        half *a_fp16;
        half *b_fp16;
        float *c_cublas;
        float *c_host_cublas;
        const float  value = 1.0f;

   
        cublasHandle_t cublasHandle;

        cudaEvent_t startcublas;
        cudaEvent_t stopcublas;

        cudaErrCheck(cudaEventCreate(&startcublas));
        cudaErrCheck(cudaEventCreate(&stopcublas));
        cublasErrCheck(cublasCreate(&cublasHandle));
        // Use tensor cores
        cublasErrCheck(cublasSetMathMode(cublasHandle, CUBLAS_TENSOR_OP_MATH));

        cudaErrCheck(cudaMalloc((void**)&a_fp16, m * k * sizeof(half)));
        cudaErrCheck(cudaMalloc((void**)&b_fp16, k * m * sizeof(half)));
        cudaErrCheck(cudaMalloc((void**)&c_cublas, m * n * sizeof(float)));
        c_host_cublas = (float*)malloc(m * n * sizeof(float));

        // curand doesn't currently support fp16 so we generate in fp32 and convert to fp16.
        assignHalfValue <<< (m * k + 255) / 256, 256 >>> (a_fp16, m*k, value);
        assignHalfValue <<< (k * n + 255) / 256, 256 >>> (b_fp16, k*n, value);
        assignFloatValue <<< (k * n + 255) / 256, 256 >>> (c_cublas, m*n, 0.0f);

        float alpha = 1.0f;
        float beta = 0.0f;
        int numRepeats = 50;
        // Warp up
        cublasErrCheck(cublasGemmEx(cublasHandle, CUBLAS_OP_N, CUBLAS_OP_N, 
            m, n, k, 
            &alpha,
            a_fp16, CUDA_R_16F, m,
            b_fp16, CUDA_R_16F, k,
            &beta, 
            c_cublas, CUDA_R_32F, m,
            CUDA_R_32F, CUBLAS_GEMM_DFALT_TENSOR_OP));

        // Now using cuBLAS
        cudaErrCheck(cudaEventRecord(startcublas));
        for (int iteration = 0; iteration < numRepeats; ++iteration) {
        cublasErrCheck(cublasGemmEx(cublasHandle, CUBLAS_OP_N, CUBLAS_OP_N, 
                    m, n, k, 
                    &alpha,
                    a_fp16, CUDA_R_16F, m,
                    b_fp16, CUDA_R_16F, k,
                    &beta, 
                    c_cublas, CUDA_R_32F, m,
                    CUDA_R_32F, CUBLAS_GEMM_DFALT_TENSOR_OP));
        }
        cudaErrCheck(cudaEventRecord(stopcublas));
        cudaErrCheck(cudaEventSynchronize(stopcublas));
        // Correctness check
        cudaErrCheck(cudaMemcpy(c_host_cublas, c_cublas, m * n * sizeof(float), cudaMemcpyDeviceToHost));
        correctnessCheck(m, n, k, c_host_cublas, value);
        // Check time
        float cublasTime;	
        cudaErrCheck(cudaEventElapsedTime(&cublasTime, startcublas, stopcublas)); 
        cublasTime /= numRepeats;
        printTime(cublasTime, m, n, k, s_max_tflops);
        
        cudaErrCheck(cudaEventDestroy(startcublas));             
        cudaErrCheck(cudaEventDestroy(stopcublas));
        cudaErrCheck(cudaFree(a_fp16));
        cudaErrCheck(cudaFree(b_fp16));
        cudaErrCheck(cudaFree(c_cublas));
        free(c_host_cublas);
    }
    std::cout << "[Peak TFLOPS]" << std::endl << std::setprecision(4) << s_max_tflops << std::endl;
    cudaErrCheck(cudaDeviceReset());

    std::cout << "[FP32 Time and TFLOPS Result]" << std::endl;
    std::cout << std::setw(7) << "m" << std::setw(7) << "n" << std::setw(7) << "k";
    std::cout << std::setw(15) << "Time (msec)" << std::setw(15) << "TFLOPS";
    std::cout << std::endl;
    s_max_tflops = 0;
    // for float test
    for (int i=start; i<=end; i+= 1024){
        m = n = k = i;
  
        float *a_fp32;
        float *b_fp32;
        float *c_cublas;
        float *c_host_cublas;
        const float  value = 1.0f;

   
        cublasHandle_t cublasHandle;

        cudaEvent_t startcublas;
        cudaEvent_t stopcublas;

        cudaErrCheck(cudaEventCreate(&startcublas));
        cudaErrCheck(cudaEventCreate(&stopcublas));
        cublasErrCheck(cublasCreate(&cublasHandle));
        // No tensor cores
        cublasErrCheck(cublasSetMathMode(cublasHandle, CUBLAS_DEFAULT_MATH));

        cudaErrCheck(cudaMalloc((void**)&a_fp32, m * k * sizeof(float)));
        cudaErrCheck(cudaMalloc((void**)&b_fp32, k * m * sizeof(float)));
        cudaErrCheck(cudaMalloc((void**)&c_cublas, m * n * sizeof(float)));
        c_host_cublas = (float*)malloc(m * n * sizeof(float));

        // curand doesn't currently support fp16 so we generate in fp32 and convert to fp16.
        assignFloatValue <<< (m * k + 255) / 256, 256 >>> (a_fp32, m*k, value);
        assignFloatValue <<< (k * n + 255) / 256, 256 >>> (b_fp32, k*n, value);
        assignFloatValue <<< (k * n + 255) / 256, 256 >>> (c_cublas, m*n, 0.0f);

        float alpha = 1.0f;
        float beta = 0.0f;
        int numRepeats = 50;
        // warp up
        cublasErrCheck(cublasSgemm(cublasHandle,
                CUBLAS_OP_N,
                CUBLAS_OP_N,
                m,
                n,
                k,
                &alpha,
                a_fp32, m,
                b_fp32, k,
                &beta,
                c_cublas, m)); 
        
        cudaErrCheck(cudaEventRecord(startcublas));
        for (int iteration = 0; iteration < numRepeats; ++iteration) {
            cublasErrCheck(cublasSgemm(cublasHandle,
                CUBLAS_OP_N,
                CUBLAS_OP_N,
                m,
                n,
                k,
                &alpha,
                a_fp32, m,
                b_fp32, k,
                &beta,
                c_cublas, m)); 
        }
        cudaErrCheck(cudaEventRecord(stopcublas));
        cudaErrCheck(cudaEventSynchronize(stopcublas));
        // Correctness check
        cudaErrCheck(cudaMemcpy(c_host_cublas, c_cublas, m * n * sizeof(float), cudaMemcpyDeviceToHost));
        correctnessCheck(m, n, k, c_host_cublas, value);
        // Check time
        float cublasTime = 0.0f;	
        cudaErrCheck(cudaEventElapsedTime(&cublasTime, startcublas, stopcublas)); 
        cublasTime /= numRepeats;
        printTime(cublasTime, m, n, k, s_max_tflops);
        
        cudaErrCheck(cudaEventDestroy(startcublas));             
        cudaErrCheck(cudaEventDestroy(stopcublas));
        cudaErrCheck(cudaFree(a_fp32));
        cudaErrCheck(cudaFree(b_fp32));
        cudaErrCheck(cudaFree(c_cublas));
        free(c_host_cublas);
    }
    std::cout << "[Peak TFLOPS]" << std::endl << std::setprecision(4) << s_max_tflops << std::endl;
    cudaErrCheck(cudaDeviceReset());
    


	return 0;
}
