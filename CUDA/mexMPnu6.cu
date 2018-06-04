/*
 * Example of how to use the mxGPUArray API in a MEX file.  This example shows
 * how to write a MEX function that takes a gpuArray input and returns a
 * gpuArray output, e.g. B=mexFunction(A).
 *
 * Copyright 2012 The MathWorks, Inc.
 */
#include <stdio.h>
#include <stdlib.h>
#include <cuda.h>
#include <math.h>
#include <stdint.h>
#include "mex.h"
#include "gpu/mxGPUArray.h"
#include <cstdlib>
#include <algorithm>
#include <iostream>
using namespace std;

const int  Nthreads = 1024, maxFR = 100000, NrankMax = 3, nmaxiter = 500, NchanMax = 32;
//////////////////////////////////////////////////////////////////////////////////////////
__global__ void	spaceFilter(const double *Params, const float *data, const float *U, 
        const int *iC, const int *iW, float *dprod){    
  volatile __shared__ float  sU[32*NrankMax];
  volatile __shared__ int iU[32]; 
  float x;
  int tid, bid, i,k, Nrank, Nchan, NT, Nfilt, NchanU;

  tid 		= threadIdx.x;
  bid 		= blockIdx.x;
  NT      	=   (int) Params[0];
  Nfilt    	=   (int) Params[1];
  Nrank     = (int) Params[6];
  NchanU    = (int) Params[10];
  Nchan     = (int) Params[9];
  
  if (tid<NchanU)
      iU[tid] = iC[tid + NchanU * iW[bid]];
  __syncthreads();  
  
  if(tid<NchanU*Nrank)
      sU[tid]= U[iU[tid%NchanU] + Nchan * bid + Nchan * Nfilt * (tid/NchanU)];
        
  //sU[tid]= U[tid%NchanU + NchanU * bid + NchanU * Nfilt * (tid/NchanU)];
  
  __syncthreads();  
  
  while (tid<NT){
      for (k=0;k<Nrank;k++){
          x = 0.0f;
          for(i=0;i<NchanU;i++)
              x  += sU[i + NchanU*k] * data[tid + NT * iU[i]];
          dprod[tid + NT*bid + k*NT*Nfilt]   = x;
      }
      
      tid += blockDim.x;
      __syncthreads();
  }
}
//////////////////////////////////////////////////////////////////////////////////////////
__global__ void	spaceFilterUpdate(const double *Params, const float *data, const float *U, const bool *UtU,
        const int *iC, const int *iW, float *dprod,  const int *st, const int *id, const int *counter){
    volatile __shared__ float  sU[32*NrankMax];
    volatile __shared__ int iU[32];
    float x;
    int tid, bid, ind, nt0, i, t, k, Nrank, NT, Nfilt, NchanU, Nchan;
    
    tid 		= threadIdx.x;
    bid 		= blockIdx.x;
    NT      	= (int) Params[0];
    Nfilt    	= (int) Params[1];
    Nrank     = (int) Params[6];
    NchanU    = (int) Params[10];
    nt0       = (int) Params[4];
    Nchan     = (int) Params[9];
    
    // just need to do this for all filters that have overlap with id[bid] and st[id]
    // tidx still represents time, from -nt0 to nt0
    // tidy loops through all filters that have overlap
    
    if (tid<NchanU)
        iU[tid] = iC[tid + NchanU * iW[bid]];
    __syncthreads();
    
    if (tid<NchanU)
       for (k=0;k<Nrank;k++)
            sU[tid + k * NchanU] = U[iU[tid] + Nchan * bid + Nchan * Nfilt * k];

    __syncthreads();
    
    for(ind=counter[1];ind<counter[0];ind++)
        if (UtU[id[ind] + Nfilt *bid]){
            t = st[ind] + tid - nt0;
            // if this is a hit, threads compute all time offsets
            if (t>=0 & t<NT){
                for (k=0;k<Nrank;k++){
                    x = 0.0f;
                    for(i=0;i<NchanU;i++)
                        x  += sU[i + NchanU*k] * data[t + NT * iU[i]];
                    dprod[t + NT*bid + k*NT*Nfilt]   = x;
                }
            }            
        }
}

//////////////////////////////////////////////////////////////////////////////////////////
__global__ void	timeFilter(const double *Params, const float *data, const float *W, float *conv_sig){    
  volatile __shared__ float sW[81*NrankMax], sdata[(Nthreads+81)*NrankMax]; 
  float x;
  int tid, tid0, bid, i, nid, Nrank, NT, Nfilt, nt0;

  tid 		= threadIdx.x;
  bid 		= blockIdx.x;
  NT      	=   (int) Params[0];
  Nfilt    	=   (int) Params[1];
  Nrank     = (int) Params[6];
  nt0       = (int) Params[4];
  
  if(tid<nt0*Nrank)
      sW[tid]  = W[tid%nt0 + (bid + Nfilt * (tid/nt0))* nt0];      
  __syncthreads();
  
  tid0 = 0;
  while (tid0<NT-Nthreads-nt0+1){
	  if (tid<nt0*NrankMax) 
          sdata[tid%nt0 + (tid/nt0)*(Nthreads+nt0)] = 
			data[tid0 + tid%nt0+ NT*(bid + Nfilt*(tid/nt0))];
	  
      #pragma unroll 3
      for(nid=0;nid<Nrank;nid++)
          sdata[tid + nt0+nid*(Nthreads+nt0)] = data[nt0+tid0 + tid+ NT*(bid +nid*Nfilt)];
	  
	  __syncthreads();
      
	  x = 0.0f;
      for(nid=0;nid<Nrank;nid++){
		  #pragma unroll 4
          for(i=0;i<nt0;i++)
              x    += sW[i + nid*nt0]  * sdata[i+tid + nid*(Nthreads+nt0)];
          
	  }
      conv_sig[tid0  + tid + NT*bid]              = x;

      tid0+=Nthreads;
      __syncthreads();
  }
}
//////////////////////////////////////////////////////////////////////////////////////////
__global__ void	timeFilterUpdate(const double *Params, const float *data, const float *W, 
        const bool *UtU, float *conv_sig, const int *st, const int *id, const int *counter){    
    
  volatile __shared__ float  sW[81*NrankMax]; 
  float x;
  int tid, tid0, bid, t, k,ind, Nrank, NT, Nfilt, nt0;

  tid 		= threadIdx.x;
  bid 		= blockIdx.x;
  NT      	=   (int) Params[0];
  Nfilt    	=   (int) Params[1];
  Nrank     = (int) Params[6];
  nt0       = (int) Params[4];
  
   if (tid<nt0)
       for (k=0;k<Nrank;k++)
           sW[tid + k*nt0]= W[tid + nt0*bid + nt0*Nfilt * k];                  
  __syncthreads();
  
  for(ind=counter[1];ind<counter[0];ind++)
      if (UtU[id[ind] + Nfilt *bid]){
          tid0 = st[ind] - nt0 + tid;
          if (tid0>=0 && tid0<NT-nt0){
              x = 0.0f;              
              for (k=0;k<Nrank;k++)
                  for (t=0;t<nt0;t++)
                      x += sW[t +k*nt0] * data[t + tid0 + NT * bid + NT * Nfilt *k];                      
       
              conv_sig[tid0 + NT*bid]   = x;
          }
          
      }
  
}
//////////////////////////////////////////////////////////////////////////////////////////
__global__ void  bestFilter(const double *Params, const float *data, 
	const float *mu, float *err, int *ftype){
  int tid, tid0, i, bid, NT, Nfilt, ibest = 0, nt0;
  float  x, Cf, Ci, Cbest, lam;

  tid 		= threadIdx.x;
  bid 		= blockIdx.x;
  NT 		= (int) Params[0];
  Nfilt 	= (int) Params[1];
  lam 	    = (float) Params[7];
  nt0       = (int) Params[4];
  
  tid0 = tid + bid * blockDim.x;
  while (tid0<NT-nt0){
      Cbest = 0.0f;
      for (i=0; i<Nfilt;i++){
          x  = max(0.0f, data[tid0 + NT * i]);
          Ci = x + lam/mu[i];
          Cf =  Ci*Ci / (1.0f + lam/(mu[i] * mu[i])) - lam;
                  
          if (Cf > Cbest + 1e-6){
              Cbest 	= Cf;
              ibest 	= i;
          }
      }
      err[tid0] 	= Cbest;
      ftype[tid0] 	= ibest;
      
      tid0 += blockDim.x * gridDim.x;
  }
}

//////////////////////////////////////////////////////////////////////////////////////////
__global__ void  bestFilterUpdate(const double *Params, const float *data, 
	const float *mu, float *err, int *ftype, const int *st, const int *id, 
        const int *counter){
  int tid,  ind, i,t, NT, Nfilt, ibest = 0, nt0;
  float  Cf, Ci, x,Cbest, lam;

  tid 		= threadIdx.x;  
  NT 		= (int) Params[0];
  Nfilt 	= (int) Params[1];
  lam 	    = (float) Params[7];
  nt0       = (int) Params[4];
  
  // we only need to compute this at updated locations
  ind = counter[1] + blockIdx.x;
  
  if (ind<counter[0]){
      t = st[ind]-nt0 + tid;
      if (t>=0 && t<NT){
          Cbest = 0.0f;
          for (i=0; i<Nfilt;i++){
              x = max(0.0f, data[t + NT * i]);
              Ci = x + lam/mu[i];
              Cf =  Ci*Ci / (1.0f + lam/(mu[i] * mu[i])) - lam;
                      
              if (Cf > Cbest + 1e-6){
                  Cbest 	= Cf;                  
                  ibest 	= i;                  
              }
          }
          err[t] 	= Cbest;          
          ftype[t] 	= ibest;
      }
  }
}


//////////////////////////////////////////////////////////////////////////////////////////
__global__ void	cleanup_spikes(const double *Params, const float *data, 
        const float *mu, const float *err, const int *ftype, int *st, 
        int *id, float *x, float *y, int *counter){
    
  int lockout, indx, tid, bid, NT, tid0,  j, t0, id0;
  volatile __shared__ float sdata[Nthreads+2*81+1];
  bool flag=0;
  float err0, Th, x0, lam;
  
  lockout   = (int) Params[4] - 1;
  tid 		= threadIdx.x;
  bid 		= blockIdx.x;
  lam 	    = (float) Params[7];
  
  NT      	=   (int) Params[0];
  tid0 		= bid * blockDim.x ;
  Th 		= (float) Params[2];
  
  while(tid0<NT-Nthreads-lockout+1){
      if (tid<2*lockout)
          sdata[tid] = err[tid0 + tid];
      sdata[tid+2*lockout] = err[2*lockout + tid0 + tid];
      
      __syncthreads();
      
      err0 = sdata[tid+lockout];
      if(err0>Th*Th){
          flag = 0;
          for(j=-lockout;j<=lockout;j++)
              if(sdata[tid+lockout+j]>err0){
                  flag = 1;
                  break;
              }
          if(flag==0){
              indx = atomicAdd(&counter[0], 1);
              if (indx<maxFR){
                  t0        = tid+lockout+tid0;
                  id0       = ftype[t0];                  
                  x0        = max(0.0f, data[t0 + NT * id0]);
                  
                  st[indx] = t0;
                  id[indx] = id0;
                  //y[indx]  = x0/mu[id0];
                  x[indx]  = (x0 + lam/mu[id0]) / (1.0f + lam/(mu[id0] * mu[id0]));
                  y[indx]  = x[indx]/mu[id0];
              }
          }
      }
      
      tid0 += blockDim.x * gridDim.x;
  }
}

//////////////////////////////////////////////////////////////////////////////////////////
__global__ void	extractFEAT(const double *Params, const int *st, const int *id,
        const float *x, const int *counter, const float *dout, const int *iList,
        const float *mu, float *d_feat){
    int t, tidx, tidy,Nblocks,NthreadsX,idF, bid,  NT, ind, tcurr, Nnearest;
    float rMax, Ci, Cf, lam;
    tidx 		= threadIdx.x;
    tidy 		= threadIdx.y;
    
    bid 		= blockIdx.x;
    NT 		= (int) Params[0];
    Nnearest 	= (int) Params[5];
    NthreadsX 	= blockDim.x;
    Nblocks               = gridDim.x;
    lam 	    = (float) Params[7];
    
    // each thread x does a nearby filter
    // each thread x combines with blocks to go through all new spikes    
    ind = counter[1]+tidx + NthreadsX * bid;
    
    while(ind<counter[0]){
        tcurr = st[ind];
        rMax = 0.0f;
        idF = iList[tidy + Nnearest * id[ind]];
        
        for (t=-3;t<3;t++){
            Ci = dout[tcurr +t+ idF * NT] + lam/mu[idF];
            Cf = Ci / sqrt(lam/(mu[idF] * mu[idF]) + 1.0f);
            rMax = max(rMax, Cf);
        }
        d_feat[tidy + ind * Nnearest] = rMax;
        ind += NthreadsX * Nblocks;
    }
}
//////////////////////////////////////////////////////////////////////////////////////////
__global__ void	subtract_spikes(const double *Params,  const int *st, 
        const int *id, const float *x, const int *counter, float *dataraw, 
        const float *W, const float *U){
  int nt0, tidx, tidy, k, NT, ind, Nchan, Nfilt, Nrank;
  float X;

  NT        = (int) Params[0];
  nt0       = (int) Params[4];
  Nchan     = (int) Params[9];
  Nfilt    	=   (int) Params[1];
  Nrank     = (int) Params[6];
  
  tidx 		= threadIdx.x;
  ind       = counter[1]+blockIdx.x;
  
  while(ind<counter[0]){
      tidy = threadIdx.y;
      
      while (tidy<Nchan){
          X = 0.0f;          
          for (k=0;k<Nrank;k++)
              X += W[tidx + id[ind]* nt0 + nt0*Nfilt*k] * 
                      U[tidy + id[ind] * Nchan + Nchan*Nfilt*k];                        
          
          dataraw[tidx + st[ind] + NT * tidy] -= x[ind] * X;          
          tidy += blockDim.y;
      }
      ind += gridDim.x;
  }
}

//////////////////////////////////////////////////////////////////////////////////////////
__global__ void computeSpikeGoodness(const double *Params, const int *counter, const float *datarez, 
        const float *dorig, 
         const int *st, const int *id, const int *iW, const int *iC, 
        const float *mask,  const float *wPCA, float *spk_score){
    
    volatile __shared__ float  sPCA[81*NrankMax], sX[NchanMax * NrankMax], sY[NchanMax * NrankMax];
  int nt0, tidx, tidy, bid, ind, NT, NchanU,k, t,Nrank, mychan, chMax;
  float X, Y; 
  
  NT        = (int) Params[0];  
  nt0       = (int) Params[4];
  Nrank     = (int) Params[6];
  NchanU    = (int) Params[10];
   
  // tidy indicates which PC to project
  tidy 		= threadIdx.y;
  // tidx loops over channels to project
  tidx 		= threadIdx.x;

  bid 		= blockIdx.x;
  
  while (tidx<nt0){
    sPCA[tidx + tidy * nt0] = wPCA[tidx + tidy*nt0];
    tidx += blockDim.x;
  }
  __syncthreads();
  
  tidx 		= threadIdx.x;
  
  // we need wPCA projections in here, and then to decide based on total
  // residual variance if a spike is any good
  ind = bid;
  
  while(ind<counter[0]){
      chMax = iW[id[ind]];
      mychan = iC[tidx + chMax*NchanU];
      
      X = 0.0f;
      Y = 0.0f;
      for (t=0;t<nt0;t++){
          X += datarez[st[ind]+t + NT * mychan] * sPCA[t + tidy * nt0];
          Y +=   dorig[st[ind]+t + NT * mychan] * sPCA[t + tidy * nt0];
      }
      
      sX[tidy + tidx*Nrank] = X * X;
      sY[tidy + tidx*Nrank] = Y * Y;
      
      __syncthreads();
      if (tidx==0){
          X = 0.0f;
          Y = 0.0f;
          for (k=0;k<NchanU;k++){
              X += sX[tidy + k*Nrank] * mask[k + NchanU * id[ind]];
              Y += sY[tidy + k*Nrank] * mask[k + NchanU * id[ind]];              
          }
          
          sX[tidy] = X;
          sY[tidy] = Y;
      }
      __syncthreads();
      if(tidx==0 && tidy==0){
          X = 0;
          Y = 0;
          for (k=0;k<Nrank;k++){
              X+= sX[k];
              Y+= sY[k];
          }
          
          spk_score[ind] = sqrt(X);
          spk_score[ind+counter[0]] = sqrt(Y);
      }
      __syncthreads();
      
      ind += gridDim.x;
  }
}
//////////////////////////////////////////////////////////////////////////////////////////
__global__ void average_snips(const double *Params, const int *st, const int *id,
        const float *x, const float *y, float *HIST, const int *counter, const float *dataraw, 
        const float *W, const float *U, float *WU, float *nsp, const float *spkscore){
    
  int nt0, tidx, tidy, bid, ind, NT, Nchan,k, Nrank, Nfilt;
  float xsum, pm, X, ThS, y0; 
  
  NT        = (int) Params[0];
  Nfilt    	=   (int) Params[1];
  nt0       = (int) Params[4];
  Nrank     = (int) Params[6];
  pm        = (float) Params[8];
  Nchan     = (int) Params[9];
  ThS      = (float) Params[11];
   
  tidx 		= threadIdx.x;
  bid 		= blockIdx.x;
  
  // we need wPCA projections in here, and then to decide based on total 
  // residual variance if a spike is any good
  
  for(ind=0; ind<counter[0];ind++)
      if (id[ind]==bid && spkscore[ind]<ThS){          
          tidy 		= threadIdx.y;
          
          // only do this if the spike is "GOOD"        
          if (tidy==0 && tidx==0){
              nsp[bid]++;
              
              // add to the histogram of this cluster
              y0 = y[ind];
              y0 = min(.999f, max(0.0f, y0 - 0.8f)/0.4f);
              HIST[((int)(y0 * 100)) + bid * 100] ++;
          }
          
          while (tidy<Nchan){
              X = 0.0f;
              for (k=0;k<Nrank;k++)
                  X += W[tidx + bid* nt0 + nt0*Nfilt*k] *
                          U[tidy + bid * Nchan + Nchan*Nfilt*k];
              
              xsum = dataraw[st[ind]+tidx + NT * tidy] + x[ind] * X;
              
              WU[tidx+tidy*nt0 + nt0*Nchan * bid] *= pm;
              WU[tidx+tidy*nt0 + nt0*Nchan * bid] +=(1-pm) * xsum;
              
              tidy+=blockDim.y;
          }
      }
}
//////////////////////////////////////////////////////////////////////////////////////////
__global__ void	addback_spikes(const double *Params,  const int *st, 
        const int *id, const float *x, const int *count, float *dataraw, 
        const float *W, const float *U, const int iter, const float *spkscore){
  int nt0, tidx, tidy, k, NT, ind, Nchan, Nfilt, Nrank;
  float X, ThS;

  NT        = (int) Params[0];
  nt0       = (int) Params[4];
  Nchan     = (int) Params[9];
  Nfilt    	=   (int) Params[1];
  Nrank     = (int) Params[6];
  ThS      = (float) Params[11];
  
  tidx 		= threadIdx.x;
  ind       = count[iter]+blockIdx.x;
  
  while(ind<count[iter+1]){
      if (spkscore[ind]>ThS){
          
          tidy = threadIdx.y;
          // only do this if the spike is "BAD"
          while (tidy<Nchan){
              X = 0.0f;              
              for (k=0;k<Nrank;k++)
                  X += W[tidx + id[ind]* nt0 + nt0*Nfilt*k] *
                          U[tidy + id[ind] * Nchan + Nchan*Nfilt*k];
              
              dataraw[tidx + st[ind] + NT * tidy] += x[ind] * X;
              tidy += blockDim.y;
          }
      }
      ind += gridDim.x;
  }
}

//////////////////////////////////////////////////////////////////////////////////////////

/*
 * Host code
 */
void mexFunction(int nlhs, mxArray *plhs[],
                 int nrhs, mxArray const *prhs[])
{
  /* Initialize the MathWorks GPU API. */
  mxInitGPU();

  /* Declare input variables*/
  double *Params, *d_Params;
  int nt0, NT, Nfilt, Nnearest, Nrank, NchanU;

  
  /* read Params and copy to GPU */
  Params  	= (double*) mxGetData(prhs[0]);
  NT		= (int) Params[0];
  Nfilt     = (int) Params[1];
  nt0       = (int) Params[4];
  Nnearest  = (int) Params[5];
  Nrank     = (int) Params[6];
  NchanU    = (int) Params[10];
  
  cudaMalloc(&d_Params,      sizeof(double)*mxGetNumberOfElements(prhs[0]));
  cudaMemcpy(d_Params,Params,sizeof(double)*mxGetNumberOfElements(prhs[0]),cudaMemcpyHostToDevice);

   /* collect input GPU variables*/
  mxGPUArray const  *W, *iList,  *U, *iC, *iW, *mu, *UtU, *mask, *wPCA, *dorig;
  const float     *d_W, *d_U,  *d_mu, *d_wPCA, *d_mask, *d_dorig;
  const int *d_iList, *d_iC, *d_iW;
  float *d_draw, *d_dWU, *d_nsp;
  const bool *d_UtU;
  
  
  dorig         = mxGPUCreateFromMxArray(prhs[1]);
  d_dorig       = (float const *)(mxGPUGetDataReadOnly(dorig));
  U             = mxGPUCreateFromMxArray(prhs[3]);
  d_U        	= (float const *)(mxGPUGetDataReadOnly(U));
  W             = mxGPUCreateFromMxArray(prhs[4]);
  d_W        	= (float const *)(mxGPUGetDataReadOnly(W));
  mu            = mxGPUCreateFromMxArray(prhs[5]);
  d_mu          = (float const *)(mxGPUGetDataReadOnly(mu));
  iC            = mxGPUCreateFromMxArray(prhs[6]);
  d_iC          = (int const *)(mxGPUGetDataReadOnly(iC));
  iW            = mxGPUCreateFromMxArray(prhs[7]);
  d_iW        	= (int const *)(mxGPUGetDataReadOnly(iW));
  UtU           = mxGPUCreateFromMxArray(prhs[8]);
  d_UtU        	= (bool const *)(mxGPUGetDataReadOnly(UtU));
  iList         = mxGPUCreateFromMxArray(prhs[9]);
  d_iList       = (int const *)  (mxGPUGetDataReadOnly(iList));
  wPCA          = mxGPUCreateFromMxArray(prhs[10]);
  d_wPCA        = (float const *)(mxGPUGetDataReadOnly(wPCA));
  mask          = mxGPUCreateFromMxArray(prhs[11]);
  d_mask        = (float const *)(mxGPUGetDataReadOnly(mask));
  
   // dWU is not a constant , so the data has to be "copied" over
  mxGPUArray *dWU, *draw, *nsp;
  dWU       = mxGPUCopyFromMxArray(prhs[2]);
  d_dWU     = (float *)(mxGPUGetData(dWU));    
  draw       = mxGPUCopyFromMxArray(prhs[1]);
  d_draw     = (float *)(mxGPUGetData(draw));  

  const mwSize dimsNsp[] 	= {Nfilt,1}; 
  nsp 		= mxGPUCreateGPUArray(2, dimsNsp, mxSINGLE_CLASS, mxREAL, MX_GPU_DO_NOT_INITIALIZE);  
  d_nsp 		= (float *)(mxGPUGetData(nsp));
    
  /* allocate new GPU variables*/  
  float *d_err, *d_x, *d_y, *d_dout, *d_feat, *d_data, *d_spkscore, *d_hist;
  int *d_st,  *d_ftype,  *d_id, *d_counter, *d_count;

  cudaMalloc(&d_dout,   NT * Nfilt* sizeof(float));
  cudaMalloc(&d_data,   NT * Nfilt*Nrank* sizeof(float));
  
  cudaMalloc(&d_err,   NT * sizeof(float));
  cudaMalloc(&d_ftype, NT * sizeof(int));
  cudaMalloc(&d_st,    maxFR * sizeof(int));
  cudaMalloc(&d_id,    maxFR * sizeof(int));
  cudaMalloc(&d_x,     maxFR * sizeof(float));
  cudaMalloc(&d_y,     maxFR * sizeof(float));
  cudaMalloc(&d_spkscore,     2*maxFR * sizeof(float));
  cudaMalloc(&d_hist,     Nfilt*100 * sizeof(float));
  
  cudaMalloc(&d_counter,   2*sizeof(int));
  cudaMalloc(&d_count,   nmaxiter*sizeof(int));
  cudaMalloc(&d_feat,     maxFR * Nnearest * sizeof(float));
  
  cudaMemset(d_nsp,    0, Nfilt * sizeof(float));
  cudaMemset(d_dout,    0, NT * Nfilt * sizeof(float));
  cudaMemset(d_data,    0, Nrank * NT * Nfilt * sizeof(float));
  cudaMemset(d_counter, 0, 2*sizeof(int));
  cudaMemset(d_count,    0, nmaxiter*sizeof(int));
  cudaMemset(d_st,      0, maxFR *   sizeof(int));
  cudaMemset(d_id,      0, maxFR *   sizeof(int));
  cudaMemset(d_spkscore,      0, 2*maxFR *   sizeof(float));
  cudaMemset(d_hist,     0, Nfilt*100 * sizeof(float));
  cudaMemset(d_x,       0, maxFR *    sizeof(float));
  cudaMemset(d_y,       0, maxFR *    sizeof(float));
  cudaMemset(d_feat,    0, maxFR * Nnearest *   sizeof(float));
  
  int *counter;
  counter = (int*) calloc(1,2 * sizeof(int));
  
  cudaMemset(d_err,     0, NT * sizeof(float));
  cudaMemset(d_ftype,   0, NT * sizeof(int));
  
  dim3 tpB(8, 2*nt0-1), tpF(16, Nnearest), tpS(nt0, 16), tpW(NchanU, Nrank);
  
  // filter the data with the spatial templates
  spaceFilter<<<Nfilt, Nthreads>>>(d_Params, d_draw, d_U, d_iC, d_iW, d_data);
  
  // filter the data with the temporal templates
  timeFilter<<<Nfilt, Nthreads>>>(d_Params, d_data, d_W, d_dout); 
  
  // compute the best filter
  bestFilter<<<NT/Nthreads,Nthreads>>>(d_Params, d_dout, d_mu, d_err, d_ftype);
  
  // loop to find and subtract spikes
  for(int k=0;k<(int) Params[3];k++){
      // ignore peaks that are smaller than another nearby peak
      cleanup_spikes<<<NT/Nthreads,Nthreads>>>(d_Params, d_dout, d_mu, d_err,
              d_ftype, d_st, d_id, d_x, d_y, d_counter);
      
      // add new spikes to 2nd counter
      cudaMemcpy(counter, d_counter, 2*sizeof(int), cudaMemcpyDeviceToHost);
      if (counter[0]>maxFR){
          counter[0] = maxFR;
          cudaMemcpy(d_counter, counter, sizeof(int), cudaMemcpyHostToDevice);
      }
      
      // extract template features before subtraction
      if (Params[12])
          extractFEAT<<<64, tpF>>>(d_Params, d_st, d_id, d_x, d_counter, d_dout, d_iList, d_mu, d_feat);
      
      // subtract spikes from raw data here
      subtract_spikes<<<Nfilt,tpS>>>(d_Params,  d_st, d_id, d_x, d_counter, d_draw, d_W, d_U);
      
      // filter the data with the spatial templates
      spaceFilterUpdate<<<Nfilt, 2*nt0-1>>>(d_Params, d_draw, d_U, d_UtU, d_iC, d_iW, d_data,
              d_st, d_id, d_counter);
      
      // filter the data with the temporal templates
      timeFilterUpdate<<<Nfilt, 2*nt0-1>>>(d_Params, d_data, d_W, d_UtU, d_dout,
              d_st, d_id, d_counter);
      
      if (counter[0]-counter[1]>0)
          bestFilterUpdate<<<counter[0]-counter[1], 2*nt0-1>>>(d_Params, d_dout, d_mu,
                  d_err, d_ftype, d_st, d_id, d_counter);
      
      cudaMemcpy(d_count+k+1, d_counter, sizeof(int), cudaMemcpyDeviceToDevice);
      
      // update 1st counter from 2nd counter
      cudaMemcpy(d_counter+1, d_counter, sizeof(int), cudaMemcpyDeviceToDevice);
  }
  
  // determine a score for each spike
  computeSpikeGoodness<<<Nfilt, tpW>>>(d_Params, d_counter, d_draw, d_dorig, d_st, d_id,
          d_iW, d_iC, d_mask, d_wPCA, d_spkscore);

//   update dWU here by adding back to subbed spikes.  
  average_snips<<<Nfilt,tpS>>>(d_Params, d_st, d_id, d_x, d_y, d_hist, d_counter, 
          d_draw, d_W, d_U, d_dWU, d_nsp, d_spkscore);
  
//   add back to the residuals the spikes with unexplained variance
  for(int iter=0;iter<(int) Params[3];iter++)      
      addback_spikes<<<Nfilt,tpS>>>(d_Params,  d_st, d_id, d_x, 
              d_count, d_draw, d_W, d_U, iter, d_spkscore);  
  
  float *x, *y, *feat, *spkscore, *hist;
  int *st, *id;
  int minSize;
  if (counter[0]<maxFR)  minSize = counter[0];
  else                   minSize = maxFR;  
  const mwSize dimst[] 	= {minSize,1}; 
  
  plhs[0] = mxCreateNumericArray(2, dimst, mxINT32_CLASS, mxREAL);
  st = (int*) mxGetData(plhs[0]);
  plhs[1] = mxCreateNumericArray(2, dimst, mxINT32_CLASS, mxREAL);
  id = (int*) mxGetData(plhs[1]);
  plhs[2] = mxCreateNumericArray(2, dimst, mxSINGLE_CLASS, mxREAL);
  x =  (float*) mxGetData(plhs[2]);  
  plhs[3] = mxCreateNumericArray(2, dimst, mxSINGLE_CLASS, mxREAL);
  y =  (float*) mxGetData(plhs[3]);  
  const mwSize dimsf[] 	= {Nnearest, minSize}; 
  plhs[4] = mxCreateNumericArray(2, dimsf, mxSINGLE_CLASS, mxREAL);
  feat =  (float*) mxGetData(plhs[4]);  
  
  // dWU stays a GPU array
  plhs[5] 	= mxGPUCreateMxArrayOnGPU(dWU);
  plhs[6] 	= mxGPUCreateMxArrayOnGPU(draw);
  plhs[7] 	= mxGPUCreateMxArrayOnGPU(nsp);
  
  const mwSize dimst2[] 	= {minSize,2}; 
  plhs[8] = mxCreateNumericArray(2, dimst2, mxSINGLE_CLASS, mxREAL);
  spkscore =  (float*) mxGetData(plhs[8]);  
  const mwSize dimst3[] 	= {100, Nfilt}; 
  plhs[9] = mxCreateNumericArray(2, dimst3, mxSINGLE_CLASS, mxREAL);
  hist =  (float*) mxGetData(plhs[9]);  
  
  cudaMemcpy(st, d_st, minSize * sizeof(int),   cudaMemcpyDeviceToHost);
  cudaMemcpy(id, d_id, minSize * sizeof(int),   cudaMemcpyDeviceToHost);
  cudaMemcpy(x,   d_x, minSize * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(y,   d_y, minSize * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(spkscore,  d_spkscore, 2*minSize * sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(feat,   d_feat, minSize * Nnearest*sizeof(float), cudaMemcpyDeviceToHost);
  cudaMemcpy(hist,  d_hist, Nfilt*100 * sizeof(float), cudaMemcpyDeviceToHost);
  
  cudaFree(d_counter);
  cudaFree(d_Params);
  cudaFree(d_ftype);
  cudaFree(d_err);
  cudaFree(d_st);
  cudaFree(d_id);
  cudaFree(d_x);
  cudaFree(d_y);
  cudaFree(d_spkscore);
  cudaFree(d_hist);
  cudaFree(d_feat);
  cudaFree(d_dout);
  cudaFree(d_data);
  
  mxGPUDestroyGPUArray(draw);
  mxGPUDestroyGPUArray(dorig);
  mxGPUDestroyGPUArray(mask);
  mxGPUDestroyGPUArray(wPCA);
  mxGPUDestroyGPUArray(dWU);
  mxGPUDestroyGPUArray(U);
  mxGPUDestroyGPUArray(UtU);
  mxGPUDestroyGPUArray(W);
  mxGPUDestroyGPUArray(mu);  
  mxGPUDestroyGPUArray(iC);  
  mxGPUDestroyGPUArray(nsp);
  mxGPUDestroyGPUArray(iW);  
  mxGPUDestroyGPUArray(iList);
  
}