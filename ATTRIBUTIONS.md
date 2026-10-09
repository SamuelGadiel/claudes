# Atribuições

## leog/claude-code-config-dir-patcher-vscode

`Sources/ClaudeSwitcherCore/ClaudeExtensionJSPatcher.swift` é uma reimplementação
em Swift (não uma cópia literal do código-fonte) dos padrões de regex e da
lógica de análise/transformação originalmente publicados por **Leo Giovanetti**
em [leog/claude-code-config-dir-patcher-vscode](https://github.com/leog/claude-code-config-dir-patcher-vscode)
(`patch-regexes.js` e `patch-core.js`), sob a licença MIT abaixo.

A descoberta de que a extensão oficial `anthropic.claude-code` lê
`process.env.CLAUDE_CONFIG_DIR` diretamente em alguns storage helpers (em vez
do valor resolvido de `claudeCode.environmentVariables`), e os padrões de
regex para localizar e corrigir isso no bundle minificado da extensão, são
trabalho dele. Validamos nossa porta Swift contra o `extension.js` oficial e
confirmamos que ela produz uma saída byte-a-byte idêntica à do patch original.

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
