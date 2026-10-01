# cuda-probe.py: the CUDA runtime calls NITROS makes at startup, run as the
# container user before launch. Exit 0 and "OK ..." when CUDA works; else the
# failing call and cudaError. err=801 means /dev shadowed the CDI GPU devices.
import ctypes, sys

_loaded = None
rt = None
for _name in ("libcudart.so", "libcudart.so.13", "libcudart.so.12",
              "/usr/local/cuda/lib64/libcudart.so"):
    try:
        rt = ctypes.CDLL(_name)
        _loaded = _name
        break
    except OSError:
        continue
if rt is None:
    print("NO_CUDART"); sys.exit(2)

# Decode CUDA error codes into human-readable strings for the journal.
rt.cudaGetErrorString.restype = ctypes.c_char_p
rt.cudaGetErrorString.argtypes = [ctypes.c_int]
def estr(code):
    try:
        return rt.cudaGetErrorString(code).decode()
    except Exception:
        return "?"

def fail(stage, code):
    # cudaGetLastError clears the sticky error so a retry starts clean.
    try: rt.cudaGetLastError()
    except Exception: pass
    print("%s err=%d(%s) lib=%s" % (stage, code, estr(code), _loaded))

# Version / device sanity (does the runtime even see a GPU?).
drv = ctypes.c_int(-1); run = ctypes.c_int(-1); ndev = ctypes.c_int(-1)
rt.cudaDriverGetVersion(ctypes.byref(drv))
rt.cudaRuntimeGetVersion(ctypes.byref(run))
rc = rt.cudaGetDeviceCount(ctypes.byref(ndev))
if rc != 0:
    fail("DEVICE_COUNT_FAIL drv=%d run=%d" % (drv.value, run.value), rc)
    sys.exit(6)

# cudaFree(0) forces primary-context init (the first thing that touches the GPU).
rc = rt.cudaFree(ctypes.c_void_p(0))
if rc != 0:
    fail("CTX_INIT_FAIL drv=%d run=%d ndev=%d" % (drv.value, run.value, ndev.value), rc)
    sys.exit(3)

# cudaDeviceGetDefaultMemPool(&pool, device=0)
pool = ctypes.c_void_p()
rc = rt.cudaDeviceGetDefaultMemPool(ctypes.byref(pool), 0)
if rc != 0:
    fail("GET_POOL_FAIL", rc); sys.exit(4)

# cudaMemPoolSetAttribute(pool, cudaMemPoolAttrReleaseThreshold=4, &threshold)
# This is the exact call that returns cudaErrorNotSupported in NITROS.
val = ctypes.c_uint64(1 << 30)
rc = rt.cudaMemPoolSetAttribute(pool, 4, ctypes.byref(val))
if rc != 0:
    fail("SET_ATTR_FAIL", rc); sys.exit(5)

print("OK drv=%d run=%d ndev=%d lib=%s" % (drv.value, run.value, ndev.value, _loaded))
sys.exit(0)
