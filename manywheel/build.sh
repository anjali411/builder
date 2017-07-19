export PYTORCH_BUILD_VERSION=0.2
export PYTORCH_BUILD_NUMBER=1
export PYTORCH_BINARY_BUILD=1
export TH_BINARY_BUILD=1

CUDA__VERSION=$(nvcc --version|tail -n1|cut -f5 -d" "|cut -f1 -d",")

export TORCH_CUDA_ARCH_LIST="3.0;3.5;5.0;5.2+PTX"
if [[ $CUDA_VERSION == "8.0" ]]; then
    echo "CUDA 8.0 Detected"
    export TORCH_CUDA_ARCH_LIST="$TORCH_CUDA_ARCH_LIST;6.0;6.1"
fi
export TORCH_NVCC_FLAGS="-Xfatbin -compress-all"

export CMAKE_LIBRARY_PATH="/opt/intel/lib:/lib:$CMAKE_LIBRARY_PATH"

# clone pytorch source code
git clone https://github.com/pytorch/pytorch -b binaryfix
cd pytorch

OLD_PATH=$PATH
# Compile wheels
for PYDIR in /opt/python/*; do
    export PATH=$PYDIR/bin:$OLD_PATH
    python setup.py clean
    pip install -r requirements.txt
    pip install numpy
    time pip wheel . -w wheelhouse
done

pip install auditwheel
yum install -y zip

for whl in wheelhouse/torch*.whl; do
    auditwheel repair $whl -w /wheelhouse/ -L lib
done

for whl in /wheelhouse/torch*manylinux*.whl; do
    # auditwheel repair is not enough
    # TH, THNN, THC, THCUNN need some manual work too, as they are not
    # touched by auditwheel
    mkdir tmp
    cd tmp
    cp $whl .
    unzip $(basename $whl)
    rm -f $(basename $whl)

    # libTH
    patchelf --set-rpath '$ORIGIN' torch/lib/libTH.so.1
    patchelf --replace-needed libgomp.so.1 libgomp-ae56ecdc.so.1.0.0 torch/lib/libTH.so.1

    # libTHNN
    patchelf --set-rpath '$ORIGIN' torch/lib/libTHNN.so.1
    patchelf --replace-needed libgomp.so.1       libgomp-ae56ecdc.so.1.0.0      torch/lib/libTHNN.so.1

    # libTHC
    patchelf --set-rpath '$ORIGIN' torch/lib/libTHC.so.1
    patchelf --replace-needed libgomp.so.1       libgomp-ae56ecdc.so.1.0.0      torch/lib/libTHC.so.1
    patchelf --replace-needed libcudart.so.8.0   libcudart-5d6d23a3.so.8.0.61   torch/lib/libTHC.so.1
    patchelf --replace-needed libcublas.so.8.0   libcublas-66855eba.so.8.0.61   torch/lib/libTHC.so.1
    patchelf --replace-needed libcusparse.so.8.0 libcusparse-94011b8d.so.8.0.61 torch/lib/libTHC.so.1
    patchelf --replace-needed libcurand.so.8.0   libcurand-3d68c345.so.8.0.61   torch/lib/libTHC.so.1

    # libTHCUNN
    patchelf --set-rpath '$ORIGIN' torch/lib/libTHCUNN.so.1
    patchelf --replace-needed libcudart.so.8.0   libcudart-5d6d23a3.so.8.0.61   torch/lib/libTHCUNN.so.1
    patchelf --replace-needed libcusparse.so.8.0 libcusparse-94011b8d.so.8.0.61 torch/lib/libTHCUNN.so.1

    # libTHS
    patchelf --set-rpath '$ORIGIN' torch/lib/libTHS.so.1

    # libTHCS
    patchelf --set-rpath '$ORIGIN' torch/lib/libTHCS.so.1
    patchelf --replace-needed libcudart.so.8.0   libcudart-5d6d23a3.so.8.0.61   torch/lib/libTHCS.so.1
    patchelf --replace-needed libcublas.so.8.0   libcublas-66855eba.so.8.0.61   torch/lib/libTHCS.so.1
    patchelf --replace-needed libcusparse.so.8.0 libcusparse-94011b8d.so.8.0.61 torch/lib/libTHCS.so.1

    # libTHPP
    patchelf --set-rpath '$ORIGIN' torch/lib/libTHPP.so.1
    patchelf --replace-needed libcudart.so.8.0   libcudart-5d6d23a3.so.8.0.61   torch/lib/libTHPP.so.1

    # libTHD
    patchelf --set-rpath '$ORIGIN' torch/lib/libTHD.so.1

    # libATen
    patchelf --set-rpath '$ORIGIN' torch/lib/libATen.so.1
    patchelf --replace-needed libcudart.so.8.0   libcudart-5d6d23a3.so.8.0.61   torch/lib/libATen.so.1
    
    # libnccl
    patchelf --set-rpath '$ORIGIN' torch/lib/libnccl.so.1
    patchelf --replace-needed libcudart.so.8.0   libcudart-5d6d23a3.so.8.0.61   torch/lib/libnccl.so.1
    rm torch/lib/libnccl.so

    # libshm
    patchelf --set-rpath '$ORIGIN' torch/lib/libshm.so

    # zip up the wheel back
    zip -r $(basename $whl) torch*

    # replace original wheel
    rm -f $whl
    mv $(basename $whl) $whl
    cd ..
    rm -rf tmp
done


mkdir -p /remote/wheelhouse
cp /wheelhouse/torch*.whl /remote/wheelhouse/

# remove stuff before testing
rm -rf /usr/local/cuda*
rm -rf /opt/rh
pushd /pytorch/test
for PYDIR in /opt/python/*; do
    "${PYDIR}/bin/pip" uninstall -y torch
    "${PYDIR}/bin/pip" install torch --no-index -f /wheelhouse
    LD_LIBRARY_PATH="" PYCMD=$PYDIR/bin/python ./run_test.sh
done
