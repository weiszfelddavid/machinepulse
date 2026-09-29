# Third-party notices

## Swift Testing 6.2.1

MachinePulse uses the Swift Testing project only to build and run tests. Swift Testing and its Swift Syntax build dependency are not linked into or bundled with MachinePulse.app.

The Swift Testing Project — <https://github.com/swiftlang/swift-testing>

Copyright © 2023 Apple Inc. and the Swift project authors.

Licensed under the Apache License, Version 2.0, with the Runtime Library Exception. You may obtain a copy of the license at <https://www.apache.org/licenses/LICENSE-2.0>. Unless required by applicable law or agreed to in writing, the software is distributed on an “AS IS” basis, without warranties or conditions of any kind.

## Swift Syntax 602.0.0

Swift Syntax is an Apple Swift Testing build dependency and is not linked into or bundled with MachinePulse.app.

Swift Syntax — <https://github.com/swiftlang/swift-syntax>

Copyright © 2014–2024 Apple Inc. and the Swift project authors.

Licensed under the Apache License, Version 2.0, with the Runtime Library Exception. The same license link and disclaimer above apply.

## disktree

MachinePulse's Storage section ports the directory classification, reclaimable-space rules, "Worth a look" findings, size formatting, squarified treemap layout, and agent hand-off prompt from `tobi/disktree` at commit `158f9cc` into Swift and into the bundled Python collector. MachinePulse does not bundle or launch the upstream program, and it does not port its removal code: MachinePulse never deletes anything.

Source: <https://github.com/tobi/disktree>

MIT License

Copyright (c) 2026 Tobi Lütke

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## xdr-boost reference implementation

MachinePulse's optional EDR overlay adapts the documented Metal/multiply compositing technique reviewed in `levelsio/xdr-boost` at commit `f1d938db8f05952d6e4fa394f1b4c1f44a47bb1a`. MachinePulse does not bundle or launch the upstream executable.

Source: <https://github.com/levelsio/xdr-boost>

MIT License

Copyright (c) 2026 Pieter Levels

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
