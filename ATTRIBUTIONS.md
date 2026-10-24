# Attributions

## leog/claude-code-config-dir-patcher-vscode

`Sources/ClaudeSCore/ClaudeExtensionJSPatcher.swift` is a Swift
reimplementation (not a literal copy of the source code) of the regex
patterns and analysis/transform logic originally published by
**Leo Giovanetti** in
[leog/claude-code-config-dir-patcher-vscode](https://github.com/leog/claude-code-config-dir-patcher-vscode)
(`patch-regexes.js` and `patch-core.js`), under the MIT license below.

The discovery that the official `anthropic.claude-code` extension reads
`process.env.CLAUDE_CONFIG_DIR` directly in some storage helpers (instead
of the resolved value of `claudeCode.environmentVariables`), and the
regex patterns to locate and fix this in the extension's minified bundle,
are his work. We validated our Swift port against the official
`extension.js` and confirmed it produces output byte-for-byte identical to
the original patch.

```
MIT License

Copyright (c) 2026 Leo Giovanetti

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
