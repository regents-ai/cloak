# Third-Party Notices & Attributions

Regents Cloak integrates with and bundles the following upstream projects, open-weight models, and decentralized inference protocols. All trademarks and brand marks belong to their respective owners.

---

## Upstream Cloud, Payment & Network Integrations

| Integration | Role in Cloak | Website | Source / Docs |
|---|---|---|---|
| **Venice AI** | Token Inference default provider (zero-data-retention inference, SIWE + HTTP x402 Base USDC) | https://venice.ai | https://docs.venice.ai · https://github.com/veniceai |
| **Boundless** | Token Inference open-weight provider over HTTP 402 MPP sessions | https://boundless.network | https://boundless.network/news/mpp-payments |
| **Tempo & Machine Payments Protocol (MPP)** | USDC.e payment channels & session vouchers (`mpp-rs` v0.20.0) | https://tempo.xyz · https://mpp.dev | https://github.com/tempoxyz/mpp-rs |
| **NEAR AI Cloud & Dstack** | Private Cloud Intel TDX + NVIDIA GPU hardware-attested enclaves | https://cloud.near.ai | https://github.com/nearai · https://github.com/Dstack-TEE/dstack |
| **Open Anonymity (zkAPI)** | Anon V unlinkable zero-knowledge ETH payments, inspired by Vitalik Buterin | https://zkapi.openanonymity.ai | https://github.com/ethereum/zkapi · https://github.com/vbuterin/zkapi |
| **Darkbloom (Eigen Labs)** | Decentralized Apple Silicon inference serving runtime and network | https://darkbloom.dev | https://github.com/Layr-Labs/d-inference |

---

## Bundled Open-Source Software & Licenses

### 1. llama.cpp (`b12633`)
- **Source:** https://github.com/ggml-org/llama.cpp
- **License:** MIT License
- **Notice:**
```text
MIT License

Copyright (c) 2023-2026 The ggml authors

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

### 2. vmlx-swift (OsaurusAI) & Apple MLX Swift
- **Website:** https://osaurus.ai
- **Source:** https://github.com/osaurus-ai/vmlx-swift · https://github.com/ml-explore/mlx-swift
- **Pinned Revision:** `52fdb628936dda1e87a315252e62524ee301b778`
- **License:** MIT License
- **Notice:**
```text
MIT License

Copyright (c) 2023 ml-explore
Copyright (c) OsaurusAI / vmlx-swift contributors

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

### 3. Open Anonymity / zkAPI (`zkapi-clientd` & `zkapi-walletd`)
- **Website:** https://zkapi.openanonymity.ai
- **Source:** https://github.com/ethereum/zkapi · https://github.com/vbuterin/zkapi · https://github.com/mingyech/zkapi
- **License:** MIT License
- **Notice:**
```text
MIT License

Copyright (c) 2026 Open Anonymity Team

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

### 4. Machine Payments Protocol Rust Toolkit (`mpp` `v0.20.0`)
- **Website:** https://mpp.dev · https://tempo.xyz
- **Source:** https://github.com/tempoxyz/mpp-rs
- **License:** Dual-licensed under MIT License OR Apache License, Version 2.0 (Copyright Tempo / mpp-rs contributors).

### 5. The Tor Project (`tor 0.4.9.16`, Tor Expert Bundle `16.0.1`) & `libevent`
- **Website:** https://www.torproject.org
- **Source:** https://gitlab.torproject.org/tpo/core/tor
- **License:** 3-Clause BSD License
- **Notice:**
```text
Copyright (c) 2001-2004, Roger Dingledine
Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson
Copyright (c) 2007-2026, The Tor Project, Inc.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.

    * Neither the names of the copyright owners nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### 6. Pi Coding Agent (`@earendil-works/pi-coding-agent` `v1.3.0`)
- **Source:** https://github.com/earendil-works/pi
- **License:** MIT License (Copyright Mario Zechner and contributors)

### 7. Node.js (`v24.22.2`)
- **Website:** https://nodejs.org
- **Source:** https://github.com/nodejs/node
- **License:** MIT License (Copyright OpenJS Foundation and Node.js contributors)

### 8. Sparkle (`v2.8.1`)
- **Website:** https://sparkle-project.org
- **Source:** https://github.com/sparkle-project/Sparkle
- **License:** MIT License (with bundled `bsdiff` 2-Clause BSD, `sais-lite` MIT, and `orlp/ed25519` zlib/public-domain components)
- **Notice:**
```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### 9. Swift Argument Parser (`v1.8.2`)
- **Source:** https://github.com/apple/swift-argument-parser
- **License:** Apache License, Version 2.0 (Copyright Apple Inc. and the Swift project authors)

---

## Optional Downloaded Open-Weight Local Models

Local model weights are downloaded directly from HuggingFace on user request and verified by SHA-256 against `reference/models.json`.

| Model | Maintainer / Quantizer | Repository | License |
|---|---|---|---|
| **Inkling 2 Mini (Base)** | Thinking Machines | https://huggingface.co/thinkingmachines/Inkling-2-Mini | Apache-2.0 |
| **Inkling 2 Mini (Fast / JANGH2)** | OsaurusAI | https://huggingface.co/OsaurusAI/Inkling-2-Mini-JANGH2 | Apache-2.0 |
| **Inkling 2 Mini (GGUF tiers)** | Unsloth · Xylolabs · ggml-org | https://huggingface.co/unsloth/Inkling-2-Mini-GGUF · https://huggingface.co/Xylolabs/Inkling-2-Mini-GGUF | Apache-2.0 |
| **Inkling 2 Mini Uncensored LoRA** | AtomicChat | https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF | Apache-2.0 |
| **Qwen 3.5 9B (Prompt Rewriter)** | Qwen · Unsloth | https://huggingface.co/Qwen/Qwen3.5-9B · https://huggingface.co/unsloth/Qwen3.5-9B-GGUF | Apache-2.0 |

Full text of the Apache License, Version 2.0 is available at https://www.apache.org/licenses/LICENSE-2.0.
