# Third-party notices

Little Voices bundles or builds in the components below. The MIT, Apache-2.0, Zlib and Unicode
licence texts that several of them use are at the end.

## Gradium Phonon

Phonon, the on-device text-to-speech model, is provided by [Gradium](https://gradium.ai).

- The model is Phonon 31m ([`gradium/phonon-31m-en`](https://huggingface.co/gradium/phonon-31m-en)),
  licensed under the Apache License, Version 2.0 (the text is below). It is not in this
  repository: `scripts/download_models.py` downloads it into `models/phonon/`. App builds
  bundle its weights, config and tokenizer, unmodified, with the characters' voices.
- The characters' voices, in `src/voices/`, are used under Gradium's terms, not this
  repository's licence.
- Its runtime, Gradium's [`ptts`](https://github.com/gradium-ai/xn-ptts) crate, is licensed
  under MIT OR Apache-2.0. Cargo fetches it and the crates below from crates.io, and they are
  compiled into the app through `native/phonon-ffi`.
- Phonon runs on the device and makes no network requests.

The crates compiled into the app's Phonon library, with the copyright notices their licence
files carry (build-time procedural macros are not listed):

| Crate | Version | Licence | Copyright |
| --- | --- | --- | --- |
| ahash | 0.8.12 | MIT OR Apache-2.0 | Copyright (c) 2018 Tom Kaitchuck |
| aho-corasick | 1.1.5 | Unlicense OR MIT | Copyright (c) 2015 Andrew Gallant |
| allocator-api2 | 0.2.21 | MIT OR Apache-2.0 | — |
| base64 | 0.13.1 | MIT OR Apache-2.0 | Copyright (c) 2015 Alice Maz |
| bit-set | 0.8.0 | Apache-2.0 OR MIT | Copyright (c) 2023 The Rust Project Developers |
| bit-vec | 0.8.0 | Apache-2.0 OR MIT | Copyright (c) 2023 The Rust Project Developers |
| bitflags | 1.3.2 | MIT OR Apache-2.0 | Copyright (c) 2014 The Rust Project Developers |
| bitflags | 2.13.2 | MIT OR Apache-2.0 | Copyright (c) 2014 The Rust Project Developers |
| bytemuck | 1.25.2 | Zlib OR Apache-2.0 OR MIT | Copyright (c) 2019 Daniel "Lokathor" Gee. |
| byteorder | 1.5.0 | Unlicense OR MIT | Copyright (c) 2015 Andrew Gallant |
| castaway | 0.2.4 | MIT | Copyright (c) 2021 Stephen M. Coakley |
| cfg-if | 1.0.5 | MIT OR Apache-2.0 | Copyright (c) 2014 Alex Crichton |
| compact_str | 0.9.1 | MIT | Copyright (c) 2021 Parker Timmerman |
| crossbeam-deque | 0.8.8 | MIT OR Apache-2.0 | Copyright (c) 2019 The Crossbeam Project Developers |
| crossbeam-epoch | 0.9.21 | MIT OR Apache-2.0 | Copyright (c) 2019 The Crossbeam Project Developers |
| crossbeam-utils | 0.8.23 | MIT OR Apache-2.0 | Copyright (c) 2019 The Crossbeam Project Developers |
| daachorse | 3.0.3 | MIT OR Apache-2.0 | — |
| dary_heap | 0.3.9 | MIT OR Apache-2.0 | — |
| dasp_frame | 0.11.0 | MIT OR Apache-2.0 | — |
| dasp_sample | 0.11.0 | MIT OR Apache-2.0 | — |
| derive_builder | 0.20.2 | MIT OR Apache-2.0 | Copyright (c) 2016 rust-derive-builder contributors |
| dyn-stack | 0.13.2 | MIT | Copyright (c) 2022 sarah |
| ebur128 | 0.1.10 | MIT | Copyright (c) 2011 Jan Kokemüller; Copyright (c) 2020 Sebastian Dröge |
| either | 1.19.0 | MIT OR Apache-2.0 | Copyright (c) 2015 |
| equivalent | 1.0.2 | Apache-2.0 OR MIT | Copyright (c) 2016--2023 |
| esaxx-rs | 0.1.10 | Apache-2.0 | — |
| fancy-regex | 0.17.0 | MIT | Copyright 2015 The Fancy Regex Authors. |
| foldhash | 0.2.0 | Zlib | Copyright (c) 2024 Orson Peters |
| getrandom | 0.3.4 | MIT OR Apache-2.0 | Copyright (c) 2018-2025 The rust-random Project Developers; Copyright (c) 2014 The Rust Project Developers |
| half | 2.7.1 | MIT OR Apache-2.0 | — |
| hashbrown | 0.16.1 | MIT OR Apache-2.0 | Copyright (c) 2016 Amanieu d'Antras |
| itertools | 0.14.0 | MIT OR Apache-2.0 | Copyright (c) 2015 |
| itoa | 1.0.18 | MIT OR Apache-2.0 | — |
| lazy_static | 1.5.1 | MIT OR Apache-2.0 | — |
| libc | 0.2.190 | MIT OR Apache-2.0 | Copyright (c) The Rust Project Developers |
| libm | 0.2.16 | MIT | Copyright (c) 2018 Jorge Aparicio; Copyright © 2005-2020 Rich Felker, et al. (musl); Copyright © 1993,2004 Sun Microsystems; Copyright © 2003-2011 David Schultz; Copyright © 2003-2009 Steven G. Kargl; Copyright © 2003-2009 Bruce D. Evans; Copyright © 2008 Stephen L. Moshier; Copyright © 2017-2018 Arm Limited |
| log | 0.4.34 | MIT OR Apache-2.0 | Copyright (c) 2014 The Rust Project Developers |
| macro_rules_attribute | 0.2.3 | Apache-2.0 OR MIT OR Zlib | Copyright (c) 2019 Daniel Henry-Mantilla |
| matchers | 0.2.0 | MIT | Copyright (c) 2019 Eliza Weisman |
| memchr | 2.8.3 | Unlicense OR MIT | Copyright (c) 2015 Andrew Gallant |
| memmap2 | 0.9.11 | MIT OR Apache-2.0 | Copyright (c) 2015 Dan Burkert; Copyright (c) 2020 Yevhenii Reizner |
| minimal-lexical | 0.2.1 | MIT OR Apache-2.0 | Copyright (c) 2009 The Go Authors. All rights reserved. |
| monostate | 0.1.18 | MIT OR Apache-2.0 | — |
| nom | 7.1.3 | MIT | Copyright (c) 2014-2019 Geoffroy Couprie |
| nu-ansi-term | 0.50.3 | MIT | Copyright (c) 2014 Benjamin Sago; Copyright (c) 2021-2022 The Nushell Project Developers |
| num-complex | 0.4.6 | MIT OR Apache-2.0 | Copyright (c) 2014 The Rust Project Developers |
| num-traits | 0.2.19 | MIT OR Apache-2.0 | Copyright (c) 2014 The Rust Project Developers |
| num_cpus | 1.17.0 | MIT OR Apache-2.0 | Copyright (c) 2015-2025 Sean McArthur |
| once_cell | 1.21.4 | MIT OR Apache-2.0 | — |
| pin-project-lite | 0.2.17 | Apache-2.0 OR MIT | — |
| ppv-lite86 | 0.2.21 | MIT OR Apache-2.0 | Copyright 2019 The CryptoCorrosion Contributors; Copyright (c) 2019 The CryptoCorrosion Contributors |
| ptts | 0.4.0 | MIT OR Apache-2.0 | — |
| pulp | 0.22.3 | MIT | Copyright (c) 2021 sarah |
| pulp-wasm-simd-flag | 0.1.1 | MIT | — |
| rand | 0.9.5 | MIT OR Apache-2.0 | Copyright 2018 Developers of the Rand project; Copyright (c) 2014 The Rust Project Developers |
| rand_chacha | 0.9.0 | MIT OR Apache-2.0 | Copyright 2018 Developers of the Rand project; Copyright (c) 2014 The Rust Project Developers |
| rand_core | 0.9.5 | MIT OR Apache-2.0 | Copyright 2018 Developers of the Rand project; Copyright (c) 2014 The Rust Project Developers |
| rand_distr | 0.5.1 | MIT OR Apache-2.0 | Copyright 2018 Developers of the Rand project |
| raw-cpuid | 11.6.0 | MIT | Copyright (c) 2015 Gerd Zellweger |
| rayon | 1.12.0 | MIT OR Apache-2.0 | Copyright (c) 2010 The Rust Project Developers |
| rayon-cond | 0.4.0 | Apache-2.0 OR MIT | Copyright (c) 2018 Josh Stone |
| rayon-core | 1.13.0 | MIT OR Apache-2.0 | Copyright (c) 2010 The Rust Project Developers |
| reborrow | 0.5.5 | MIT | Copyright (c) 2022 sarah |
| regex | 1.13.1 | MIT OR Apache-2.0 | Copyright (c) 2014 The Rust Project Developers |
| regex-automata | 0.4.18 | MIT OR Apache-2.0 | Copyright (c) 2014 The Rust Project Developers |
| regex-syntax | 0.8.11 | MIT OR Apache-2.0 | Copyright (c) 2014 The Rust Project Developers |
| ryu | 1.0.23 | Apache-2.0 OR BSL-1.0 | — |
| safetensors | 0.7.0 | Apache-2.0 | — |
| serde | 1.0.229 | MIT OR Apache-2.0 | — |
| serde_core | 1.0.229 | MIT OR Apache-2.0 | — |
| serde_json | 1.0.154 | MIT OR Apache-2.0 | — |
| sharded-slab | 0.1.7 | MIT | Copyright (c) 2019 Eliza Weisman |
| smallvec | 1.16.3 | MIT OR Apache-2.0 | Copyright (c) 2018 The Servo Project Developers |
| spm_precompiled | 0.1.4 | Apache-2.0 | — |
| stable_deref_trait | 1.2.1 | MIT OR Apache-2.0 | Copyright (c) 2017 Robert Grosse |
| static_assertions | 1.1.0 | MIT OR Apache-2.0 | Copyright (c) 2017 Nikolai Vazquez |
| sysctl | 0.6.0 | MIT | Copyright (c) 2017 Johannes Lundberg |
| thiserror | 1.0.69 | MIT OR Apache-2.0 | — |
| thiserror | 2.0.21 | MIT OR Apache-2.0 | — |
| thread_local | 1.1.10 | MIT OR Apache-2.0 | Copyright (c) 2016 The Rust Project Developers |
| tokenizers | 0.23.2 | Apache-2.0 | — |
| tracing | 0.1.44 | MIT | Copyright (c) 2019 Tokio Contributors |
| tracing-core | 0.1.36 | MIT | Copyright (c) 2019 Tokio Contributors |
| tracing-log | 0.2.0 | MIT | Copyright (c) 2019 Tokio Contributors |
| tracing-subscriber | 0.3.23 | MIT | Copyright (c) 2019 Tokio Contributors |
| unicode-normalization-alignments | 0.1.12 | MIT OR Apache-2.0 | Copyright (c) 2015 The Rust Project Developers |
| unicode-segmentation | 1.13.3 | MIT OR Apache-2.0 | Copyright (c) 2015 The Rust Project Developers |
| unicode_categories | 0.1.1 | MIT OR Apache-2.0 | Copyright (c) 2015 The unicode-categories Developers |
| xn | 0.2.11 | MIT OR Apache-2.0 | — |
| xn-gemm | 0.20.2 | MIT | Copyright (c) 2021 sarah |
| xn-gemm-c32 | 0.20.2 | MIT | Copyright (c) 2021 sarah |
| xn-gemm-c64 | 0.20.2 | MIT | Copyright (c) 2021 sarah |
| xn-gemm-common | 0.20.2 | MIT | Copyright (c) 2021 sarah |
| xn-gemm-f16 | 0.20.2 | MIT | Copyright (c) 2021 sarah |
| xn-gemm-f32 | 0.20.2 | MIT | Copyright (c) 2021 sarah |
| xn-gemm-f64 | 0.20.2 | MIT | Copyright (c) 2021 sarah |
| yoke | 0.8.3 | Unicode-3.0 | Copyright © 2020-2024 Unicode, Inc. |
| zerocopy | 0.8.62 | BSD-2-Clause OR Apache-2.0 OR MIT | Copyright 2023 The Fuchsia Authors; Copyright 2019 The Fuchsia Authors. |
| zerofrom | 0.1.8 | Unicode-3.0 | Copyright © 2020-2024 Unicode, Inc. |
| zmij | 1.0.23 | MIT | — |

## Pipecat Audience

Pipecat Audience, the model that reads who each line is for, is published by Pipecat AI
([`pipecat-ai/audience`](https://huggingface.co/pipecat-ai/audience)) and is used under the
Apache License, Version 2.0 (the text is in `src/python/pipecat_audience/LICENSE`).

- Release rc2.1's request types, input rendering, rules of evidence, rules baseline and
  features are included unmodified in `src/python/pipecat_audience/runtime/`.
- The model is not distributed in this repository: `scripts/download_models.py` downloads
  its Core ML package into `models/audience/`. App builds bundle the compiled models, its
  `tokenizer.json` and its `config.json`.
- Its base model is Ettin (`jhu-clsp/ettin-encoder-32m`), whose tokenizer is ModernBERT's,
  under the MIT License:

```text
MIT License

Copyright (c) 2025 Johns Hopkins University Center for Language and Speech Processing

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

## Pipecat

The app embeds [Pipecat](https://github.com/pipecat-ai/pipecat) 1.12.0, the pipecat-ai release
with the app's patch applied (see [patches/README.md](patches/README.md)):

```text
BSD 2-Clause License

Copyright (c) 2024–2026, Daily

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Embedded Python

The app embeds CPython from BeeWare's Python-Apple-support (3.13-b14), without the extension
modules that link OpenSSL, BZip2 and XZ, and these packages:

| Component | Licence |
| --- | --- |
| CPython 3.13.14 | PSF License 2.0 |
| libFFI 3.4.7, linked into CPython's `_ctypes` | MIT |
| mpdecimal 4.0.0, linked into CPython's `_decimal` | BSD 2-Clause |
| pydantic 2.13.5, pydantic-core 2.46.5 | MIT |
| annotated-types 0.8.0, typing-inspection 0.4.4, docstring-parser 0.18.0 | MIT |
| Markdown 3.10.3, websockets 17.1 | BSD 3-Clause |
| typing-extensions 4.16.0 | PSF License 2.0 |
| loguru 0.7.3 | MIT |
| attrs 26.1.0 | MIT |

In the app, CPython's licence is in `python/lib/python3.13/LICENSE.txt` and each package's is
in its `.dist-info` folder in `python-packages/`, except loguru's:

```text
MIT License

Copyright (c) 2017

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

## pipecat-visemes

The lip-sync analyzer (`LipsyncDSP.swift`, `FormantLipsyncAnalyzer.swift`) and the
pose sampling in `LipsyncTimeline.swift` are ported from pipecat-visemes. The analyzer's
test fixture in `tests/fixtures/lipsync/` (`speech.wav` and its expected keyframes) was
generated with its Python analyzer.

```text
BSD 2-Clause License

Copyright (c) 2026, Daily

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## CMU Pronouncing Dictionary

Lip sync's pronunciations (`src/ios/PipecatVoice/Assets.xcassets/Pronunciations.dataset/cmudict.lzma`)
are packed by `scripts/pack_cmudict.py` from the
[CMU Pronouncing Dictionary](https://github.com/cmusphinx/cmudict), `cmudict.dict` at revision
`74790861f652b15e4ac49015a90074ad62a27690`: the first pronunciation of each ASCII word and
contraction, with its stress.

```text
Copyright (C) 1993-2015 Carnegie Mellon University. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
   The contents of this file are deemed to be source code.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in
   the documentation and/or other materials provided with the
   distribution.

This work was supported in part by funding from the Defense Advanced
Research Projects Agency, the Office of Naval Research and the National
Science Foundation of the United States of America, and by member
companies of the Carnegie Mellon Sphinx Speech Consortium. We acknowledge
the contributions of many volunteers to the expansion and improvement of
this dictionary.

THIS SOFTWARE IS PROVIDED BY CARNEGIE MELLON UNIVERSITY ``AS IS'' AND
ANY EXPRESSED OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL CARNEGIE MELLON UNIVERSITY
NOR ITS EMPLOYEES BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Licence texts

### MIT

For the crates above under MIT (or offering it), with the copyright notices listed with them:

```text
Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

### Apache License 2.0

For Phonon 31m, for `tokenizers`, `safetensors`, `esaxx-rs` and `spm_precompiled`, and for the
crates offering it:

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS
```

### Zlib

For `foldhash`:

```text
Copyright (c) 2024 Orson Peters

This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use of
this software.

Permission is granted to anyone to use this software for any purpose, including
commercial applications, and to alter it and redistribute it freely, subject to
the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim
    that you wrote the original software. If you use this software in a product,
    an acknowledgment in the product documentation would be appreciated but is
    not required.

2. Altered source versions must be plainly marked as such, and must not be
    misrepresented as being the original software.

3. This notice may not be removed or altered from any source distribution.
```

### Unicode License v3

For `yoke` and `zerofrom`:

```text
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 2020-2024 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
```
