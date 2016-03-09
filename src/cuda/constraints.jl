#=
# Code change history:
#     Zheng Li (zheng@bitfusion.io) at Bifusion.io Inc.   : Add multi-GPU support.
#
=#
############################################################
# apply L2 constraint
############################################################

function apply_l2_cons!{T <: AbstractFloat}(backend::GPUBackend, blob::CuTensorBlob{T},
                                            coef::AbstractFloat, ninputs::Integer, nunits::Integer)
  # we allocate a bit of temporary memory here
  # we could instead also store this in the cons type
  # but that would double the memory footprint of a network
  # which is prohibitive for large models!
  # --
  # NOTE stokasto:
  # an even better alternative would be to write
  # a dedicated kernel for normalization
  # but since the weight matrices are usually small
  # I am not sure whether that will pay off especially
  # since the constraints only apply rarely
  # I also tested using cublas cublasSnorm2 but that was way slower
  # than computing all norms using gemm
  @assert(ninputs*nunits == length(blob))
  # allocate
  tmpA = make_blob(backend, T, size(blob)...)
  onesv = make_blob(backend, ones(T, ninputs, 1, 1, 1))
  tmp_norm = make_blob(backend, T, (nunits, 1, 1, 1))
  tmp_norm_host = zeros(T, nunits)
  # copy blob so that it stays intact
  copy!(tmpA, blob)

  # we compute the squared norm of all colums of matrix A as:
  #  ||A||^2 = transpose(A .* A) * ones(size(A))
  # square blob inplace
  CuVec.mul!(backend, T, get_ptr(tmpA).p, get_ptr(tmpA).p, length(blob))
  # and reduce via gemv to get the sum
  CuBLAS.gemm(get_cublas_ctx(backend), CuBLAS.OP_T, CuBLAS.OP_N, nunits, 1, ninputs,
              convert(T, 1), get_ptr(tmpA), ninputs, get_ptr(onesv), ninputs, convert(T, 0), get_ptr(tmp_norm), nunits)
  # copy back for doing the norm size check on the cpu
  copy!(tmp_norm_host, tmp_norm)

  for i = 1:nunits
    # calculate offset in blob vector
    offset = sizeof(T) * (i-1) * ninputs
    off_ptr = CudaPtr(get_ptr(blob).p + offset)
    @inbounds norm = sqrt(tmp_norm_host[i])
    if norm > coef
      scale_factor = (1. / norm) * coef
      CuBLAS.scal(get_cublas_ctx(backend), ninputs, convert(T, scale_factor), off_ptr, 1)
    end
  end
  destroy(tmpA)
  destroy(onesv)
  destroy(tmp_norm)
end
