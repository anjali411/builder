#!/usr/bin/env bash

export CMAKE_LIBRARY_PATH=$PREFIX/lib:$PREFIX/include:$CMAKE_LIBRARY_PATH
export CMAKE_PREFIX_PATH=$PREFIX
# compile for Kepler, Kepler+Tesla, Maxwell, Pascal, Volta
export TORCH_CUDA_ARCH_LIST="3.5;5.2+PTX;6.0;6.1;7.0"
export TORCH_NVCC_FLAGS="-Xfatbin -compress-all"
export PYTORCH_BINARY_BUILD=1
export TH_BINARY_BUILD=1
export PYTORCH_BUILD_VERSION=$PKG_VERSION
export PYTORCH_BUILD_NUMBER=$PKG_BUILDNUM
export NCCL_ROOT_DIR=/usr/local/cuda


fname_with_sha256() {
    HASH=$(sha256sum $1 | cut -c1-8)
    DIRNAME=$(dirname $1)
    BASENAME=$(basename $1)
    if [[ $BASENAME == "libnvrtc-builtins.so" ]]; then
	echo $1
    else
	INITNAME=$(echo $BASENAME | cut -f1 -d".")
	ENDNAME=$(echo $BASENAME | cut -f 2- -d".")
	echo "$DIRNAME/$INITNAME-$HASH.$ENDNAME"
    fi
}

# for some reason if we use exact version numbers for CUDA9 .so files 
# (like .so.9.0.176), we see segfaults during dlopen somewhere
# deep inside these libs.
# hence for CUDA9, use .9.0, and dont use hashed names
DEPS_LIST=(
    "/usr/local/cuda/lib64/libcudart.so.9.0"
    "/usr/local/cuda/lib64/libnvToolsExt.so.1"
    "/usr/local/cuda/lib64/libcublas.so.9.0"
    "/usr/local/cuda/lib64/libcurand.so.9.0"
    "/usr/local/cuda/lib64/libcusparse.so.9.0"
    "/usr/local/cuda/lib64/libnvrtc.so.9.0"
    "/usr/local/cuda/lib64/libnvrtc-builtins.so"
    "/usr/local/cuda/lib64/libcudnn.so.7"
    "/usr/local/cuda/lib64/libnccl.so.2"
)

DEPS_SONAME=(
    "libcudart.so.9.0"
    "libnvToolsExt.so.1"
    "libcublas.so.9.0"
    "libcurand.so.9.0"
    "libcusparse.so.9.0"
    "libnvrtc.so.9.0"
    "libnvrtc-builtins.so"
    "libcudnn.so.7"
    "libnccl.so.2"
)


if [[ "$OSTYPE" == "darwin"* ]]; then
    MACOSX_DEPLOYMENT_TARGET=10.9 python setup.py install
else
    # install
    python setup.py install

    # copy over needed dependent .so files over and tag them with their hash
    patched=()
    for filepath in "${DEPS_LIST[@]}"
    do
	filename=$(basename $filepath)
	destpath=$SP_DIR/torch/lib/$filename
	if [[ "$filepath" != "$destpath" ]]; then
	    cp $filepath $destpath
	fi

	patchedpath=$(fname_with_sha256 $destpath)
	patchedname=$(basename $patchedpath)
	if [[ "$destpath" != "$patchedpath" ]]; then
	    mv $destpath $patchedpath
	fi

	patched+=("$patchedname")
	echo "Copied $filepath to $patchedpath"
    done

    # run patchelf to fix the so names to the hashed names
    for ((i=0;i<${#DEPS_LIST[@]};++i));
    do
	find $SP_DIR/torch -name '*.so*' | while read sofile; do
	    origname=${DEPS_SONAME[i]}
	    patchedname=${patched[i]}
	    if [[ "$origname" != "$patchedname" ]]; then
		set +e
		patchelf --print-needed $sofile | grep $origname 2>&1 >/dev/null
		ERRCODE=$?
		set -e
		if [ "$ERRCODE" -eq "0" ]; then
		    echo "patching $sofile entry $origname to $patchedname"
		    patchelf --replace-needed $origname $patchedname $sofile
		fi
	    fi
	done
    done

    # set RPATH of _C.so and similar to $ORIGIN, $ORIGIN/lib and conda/lib
    find $SP_DIR/torch -name "*.so*" -maxdepth 1 -type f | while read sofile; do
	echo "Setting rpath of $sofile to " '$ORIGIN:$ORIGIN/lib:$ORIGIN/../../..'
	patchelf --set-rpath '$ORIGIN:$ORIGIN/lib:$ORIGIN/../../..' $sofile
	patchelf --print-rpath $sofile
    done
    
    # set RPATH of lib/ files to $ORIGIN and conda/lib
    find $SP_DIR/torch/lib -name "*.so*" -maxdepth 1 -type f | while read sofile; do
	echo "Setting rpath of $sofile to " '$ORIGIN:$ORIGIN/lib:$ORIGIN/../../../..'
	patchelf --set-rpath '$ORIGIN:$ORIGIN/../../../..' $sofile
	patchelf --print-rpath $sofile
    done
    
fi
