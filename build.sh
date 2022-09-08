#!/bin/bash
set -e

# haswell: Intel/AMD AVX2
# westmere: Intel/AMD SSE4.2
# icelake might also work - still buggy
SIMD_IMPLEMENTATIONS="haswell westmere"
# file to parse in testing
PARSE_FILE=twitter.json
# number of iterations to test 
N=3

while getopts "hsw" OPTION
do
	case $OPTION in
		h) help
				exit;;
		s) simd=true;;
		w) wasm=true;;
	esac
done

SCRIPT=$(readlink -f "$0")
SCRIPT_PATH=$(dirname "$SCRIPT")

help() {
  echo "Build the simdjson library and corresponding parse.cpp"
  echo "application. Run tests for the specific build target and"
  echo "available SIMD implementations (if specified)."
  echo
  echo "Syntax: bash run.sh -[h|s|w]"
  echo "options:"
  echo "h   Print this help menu."
  echo "s   SIMD instructions included."
  echo "w   Build to WASM target."
  echo
}

build_with_pthread() {
  PREFIX="-DWAMR_BUILD_SIMD="
  if [[ -n "$1" ]]; then OPT="${PREFIX}1"; else OPT="${PREFIX}0"; fi
  cmake .. -DWAMR_BUILD_BULK_MEMORY=1 -DWAMR_BUILD_LIB_PTHREAD=1 ${OPT}
  make
}

if [[ "$wasm" = true ]]; then 
  echo "compiling parse.cpp to wasm target..."
  if [[ "$simd" = true ]]; then OPT="-msimd128"; fi
  em++ -O3 -mbulk-memory -matomics "$OPT"             \
    -Wl,--export=__data_end,--export=__heap_base      \
    -Wl,--shared-memory,--no-check-features           \
    -s ERROR_ON_UNDEFINED_SYMBOLS=0                   \
    -o out/parse.wasm                                 \
    parse.cpp simdjson.cpp

  # Testing code for SIMD intrinsics 
  echo "generating wat file..."
  ${WABT_PATH}/build/wasm2wat \
    --enable-threads \
    -o out/parse${OPT}.wat \
    out/parse.wasm

  echo "rebuilding iwasm..."
  cd ${WAMR_PATH}/product-mini/platforms/linux/build
  build_with_pthread $simd
  echo "rebuilding wamr..."
  cd ${WAMR_PATH}/wamr-compiler/build 
  build_with_pthread $simd
  cd ${SCRIPT_PATH}   

  echo "building AOT module..."
  ${WAMR_PATH}/wamr-compiler/build/wamrc      \
    --enable-multi-thread                     \
    -o out/parse.aot                          \
    out/parse.wasm

  if [[ "$simd" = true ]]; then 
    set -- $SIMD_IMPLEMENTATIONS
    imp=$1 
    out="simd128"
  else 
    imp="fallback" 
    out="fallback"
  fi
  # TODO: step not working for WASM - incorporate SIMDe
  echo "running iwasm..."
  cat json-files/${PARSE_FILE} |                          \
    ${WAMR_PATH}/product-mini/platforms/linux/build/iwasm \
    --dir=${SCRIPT_PATH}                                  \
    out/parse.aot "$imp" "$N"                             

else
  echo "compiling parse.cpp to native target..."
  g++ -O3 -o out/parse parse.cpp simdjson.cpp  

  if [[ "$simd" = true ]]; then
    for imp in $SIMD_IMPLEMENTATIONS; do
      cp /dev/null results/native_${imp}.csv
      echo "testing $imp..."
      cat json-files/${PARSE_FILE} | out/parse "$imp" "$N" \
      > results/native_${imp}.csv
    done

  else
    cp /dev/null results/native_fallback.csv
    echo "testing fallback..."
    cat json-files/${PARSE_FILE} | out/parse "fallback" "$N" \
    > results/native_fallback.csv
  fi
fi