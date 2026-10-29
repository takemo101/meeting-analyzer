// build/native/include/transcribe.h（scripts/build-native.sh が作る）への転送。
// vad.h などが `#include "transcribe.h"` と書くので、このターゲットの include を、探す場所にして、本物へ導く。
#include "../../../build/native/include/transcribe.h"
