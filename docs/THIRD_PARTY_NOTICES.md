# Third-party notices

The Android PRoot runner libraries in `android/app/src/main/jniLibs/` are
distributed under the MIT license from
[`tall-1997/daidai-panel-native`](https://github.com/tall-1997/daidai-panel-native).
The required upstream copyright notice is retained here:

Source commit: `90748201492cf1830404dafebddb0732ae076725`.

```text
MIT License

Copyright (c) 2026 tall-1997

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Those binaries are used only as the Android-native PRoot execution boundary;
the FLS rootfs and panel source are downloaded from the FLS `proot-runtime`
release and FLS repository respectively. Flutter, Dart, and package licenses
remain governed by their upstream distributions.
