# Playmesh Visual Editor — Open-source and third-party notices

Playmesh Visual Editor is an unofficial modified distribution built on the
open-source technology of GDevelop. It is not affiliated with, sponsored by, or endorsed by GDevelop Ltd, GDevelop France SAS, or Florian Rival. The name
“GDevelop” is used only to identify the upstream open-source technology and
compatible project format. GDevelop names and logos remain the property of
their respective owners.

Playmesh 可视化编辑器是基于 GDevelop 开源技术的非官方修改版，与 GDevelop Ltd 无隶属关系、无赞助关系，也未获其背书。

This is a conservative, traceable attribution archive for the Playmesh WebIDE
based on GDevelop 5.6.276 (upstream tag `v5.6.276`, commit
`9ef4a53e6a9b351618a1e60a99f7d7f4baf36361`). It is not a legal-opinion
statement about the minimum notices required, and it is not asserted to be a
complete software bill of materials. Generated WebIDE archives mechanically
append the upstream GDevelop license files, package-local license material,
GDJS Runtime legal files, and every webpack `*.LICENSE.txt` attribution file
found in the audited production build. Exact duplicate texts are removed.
Those verbatim build-generated sections may identify additional transitive
packages.

## Component inventory

- GDevelop IDE, Core, GDJS and Extensions — 5.6.276 —
  <https://github.com/4ian/GDevelop/tree/v5.6.276> — MIT.
- Monaco Editor — npm lock identity 0.14.3; the separately copied AMD loader
  reports 0.14.6, so this distribution does not assert a single semantic
  version for all Monaco files — <https://github.com/microsoft/monaco-editor>
  — MIT. Monaco's own `ThirdPartyNotices.txt` is also included in generated
  WebIDE notices.
- React and React DOM — 18.2.0 — <https://github.com/facebook/react> — MIT.
- Firebase JavaScript SDK used by the WebIDE npm application — 9.0.0-beta.2 —
  <https://github.com/firebase/firebase-js-sdk> — Apache-2.0. Its
  locked package metadata declares Apache-2.0; the exact metadata and full
  Apache-2.0 text are preserved below.
- Firebase JavaScript SDK vendored by the GDevelop GDJS runtime — 8.3.3,
  according to the locked runtime NOTICE —
  <https://github.com/firebase/firebase-js-sdk> — Apache-2.0. Its separate
  source license and runtime NOTICE are mechanically preserved below.
- Fira Sans fonts (Regular, SemiBold and Bold; upstream files are not versioned
  by the GDevelop package) — <https://github.com/mozilla/Fira> — OFL-1.1.
- zip.js legacy browser sources (copyright notice identifies 2013 Gildas
  Lormeau; no package version is asserted) —
  <https://github.com/gildas-lormeau/zip.js> — BSD-3-Clause.

The GDevelop source contains integration bridges and README files for Piskel
and Yarn Classic, but the Playmesh source policy does not download their
external-editor archives and the audited WebIDE package contains no editor
payload from either project. They are therefore not asserted as distributed
components here. Enabling those downloads requires a new license inventory.

Component names are attribution and identification only; they do not imply
affiliation with or endorsement of Playmesh.

## BBText derivative provenance boundary

The distributed built-in BBText extension contains a vendored
`pixi-multistyle-text` dependency. The locked GDevelop source carries its
README, which identifies the upstream repository and MIT license, but does
not carry a semantic version or exact upstream code revision. The release
gate binds every actually vendored README/UMD/declaration byte by SHA-256 and
separately pins the upstream MIT license text to an immutable upstream
commit. This does not claim that the vendored derivative byte-matches that
commit. The bundled DialogueTree `bondage.js` dependency carries its MIT
`LICENSE.md` and version evidence; both are collected verbatim.

## Playmesh brand asset provenance boundary

The build gate binds the repository source path and SHA-256 of the copied
Playmesh logo and verifies the distributed copy has the same bytes. This is
technical provenance only. It does not establish or express a legal opinion
about copyright or trademark ownership.

## GDevelop MIT license

GDevelop IDE

The MIT License (MIT)

Copyright (c) 2017 Florian Rival

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the “Software”), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## MIT license used by Monaco Editor, React and React DOM

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the “Software”), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Relevant copyright notices include:

- Monaco Editor: Copyright (c) Microsoft Corporation.
- React and React DOM: Copyright (c) Meta Platforms, Inc. and affiliates.

## Apache License 2.0 used by Firebase

Apache License
Version 2.0, January 2004
<http://www.apache.org/licenses/>

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

“License” shall mean the terms and conditions for use, reproduction, and
distribution as defined by Sections 1 through 9 of this document.

“Licensor” shall mean the copyright owner or entity authorized by the
copyright owner that is granting the License.

“Legal Entity” shall mean the union of the acting entity and all other
entities that control, are controlled by, or are under common control with
that entity. For the purposes of this definition, “control” means (i) the
power, direct or indirect, to cause the direction or management of such
entity, whether by contract or otherwise, or (ii) ownership of fifty percent
(50%) or more of the outstanding shares, or (iii) beneficial ownership of
such entity.

“You” (or “Your”) shall mean an individual or Legal Entity exercising
permissions granted by this License.

“Source” form shall mean the preferred form for making modifications,
including but not limited to software source code, documentation source, and
configuration files.

“Object” form shall mean any form resulting from mechanical transformation or
translation of a Source form, including but not limited to compiled object
code, generated documentation, and conversions to other media types.

“Work” shall mean the work of authorship, whether in Source or Object form,
made available under the License, as indicated by a copyright notice that is
included in or attached to the work.

“Derivative Works” shall mean any work, whether in Source or Object form, that
is based on (or derived from) the Work and for which the editorial revisions,
annotations, elaborations, or other modifications represent, as a whole, an
original work of authorship. For the purposes of this License, Derivative
Works shall not include works that remain separable from, or merely link (or
bind by name) to the interfaces of, the Work and Derivative Works thereof.

“Contribution” shall mean any work of authorship, including the original
version of the Work and any modifications or additions to that Work or
Derivative Works thereof, that is intentionally submitted to Licensor for
inclusion in the Work by the copyright owner or by an individual or Legal
Entity authorized to submit on behalf of the copyright owner. For the
purposes of this definition, “submitted” means any form of electronic,
verbal, or written communication sent to the Licensor or its representatives,
including but not limited to communication on electronic mailing lists,
source code control systems, and issue tracking systems that are managed by,
or on behalf of, the Licensor for the purpose of discussing and improving the
Work, but excluding communication that is conspicuously marked or otherwise
designated in writing by the copyright owner as “Not a Contribution.”

“Contributor” shall mean Licensor and any individual or Legal Entity on behalf
of whom a Contribution has been received by Licensor and subsequently
incorporated within the Work.

2. Grant of Copyright License. Subject to the terms and conditions of this
License, each Contributor hereby grants to You a perpetual, worldwide,
non-exclusive, no-charge, royalty-free, irrevocable copyright license to
reproduce, prepare Derivative Works of, publicly display, publicly perform,
sublicense, and distribute the Work and such Derivative Works in Source or
Object form.

3. Grant of Patent License. Subject to the terms and conditions of this
License, each Contributor hereby grants to You a perpetual, worldwide,
non-exclusive, no-charge, royalty-free, irrevocable (except as stated in this
section) patent license to make, have made, use, offer to sell, sell, import,
and otherwise transfer the Work, where such license applies only to those
patent claims licensable by such Contributor that are necessarily infringed
by their Contribution(s) alone or by combination of their Contribution(s)
with the Work to which such Contribution(s) was submitted. If You institute
patent litigation against any entity (including a cross-claim or counterclaim
in a lawsuit) alleging that the Work or a Contribution incorporated within
the Work constitutes direct or contributory patent infringement, then any
patent licenses granted to You under this License for that Work shall
terminate as of the date such litigation is filed.

4. Redistribution. You may reproduce and distribute copies of the Work or
Derivative Works thereof in any medium, with or without modifications, and in
Source or Object form, provided that You meet the following conditions:

(a) You must give any other recipients of the Work or Derivative Works a copy
of this License; and

(b) You must cause any modified files to carry prominent notices stating that
You changed the files; and

(c) You must retain, in the Source form of any Derivative Works that You
distribute, all copyright, patent, trademark, and attribution notices from the
Source form of the Work, excluding those notices that do not pertain to any
part of the Derivative Works; and

(d) If the Work includes a “NOTICE” text file as part of its distribution,
then any Derivative Works that You distribute must include a readable copy of
the attribution notices contained within such NOTICE file, excluding those
notices that do not pertain to any part of the Derivative Works, in at least
one of the following places: within a NOTICE text file distributed as part of
the Derivative Works; within the Source form or documentation, if provided
along with the Derivative Works; or, within a display generated by the
Derivative Works, if and wherever such third-party notices normally appear.
The contents of the NOTICE file are for informational purposes only and do
not modify the License. You may add Your own attribution notices within
Derivative Works that You distribute, alongside or as an addendum to the
NOTICE text from the Work, provided that such additional attribution notices
cannot be construed as modifying the License.

You may add Your own copyright statement to Your modifications and may
provide additional or different license terms and conditions for use,
reproduction, or distribution of Your modifications, or for any such
Derivative Works as a whole, provided Your use, reproduction, and distribution
of the Work otherwise complies with the conditions stated in this License.

5. Submission of Contributions. Unless You explicitly state otherwise, any
Contribution intentionally submitted for inclusion in the Work by You to the
Licensor shall be under the terms and conditions of this License, without any
additional terms or conditions. Notwithstanding the above, nothing herein
shall supersede or modify the terms of any separate license agreement you may
have executed with Licensor regarding such Contributions.

6. Trademarks. This License does not grant permission to use the trade names,
trademarks, service marks, or product names of the Licensor, except as required
for reasonable and customary use in describing the origin of the Work and
reproducing the content of the NOTICE file.

7. Disclaimer of Warranty. Unless required by applicable law or agreed to in
writing, Licensor provides the Work (and each Contributor provides its
Contributions) on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied, including, without limitation, any warranties
or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
PARTICULAR PURPOSE. You are solely responsible for determining the
appropriateness of using or redistributing the Work and assume any risks
associated with Your exercise of permissions under this License.

8. Limitation of Liability. In no event and under no legal theory, whether in
tort (including negligence), contract, or otherwise, unless required by
applicable law (such as deliberate and grossly negligent acts) or agreed to in
writing, shall any Contributor be liable to You for damages, including any
direct, indirect, special, incidental, or consequential damages of any
character arising as a result of this License or out of the use or inability
to use the Work (including but not limited to damages for loss of goodwill,
work stoppage, computer failure or malfunction, or any and all other commercial
damages or losses), even if such Contributor has been advised of the
possibility of such damages.

9. Accepting Warranty or Additional Liability. While redistributing the Work
or Derivative Works thereof, You may choose to offer, and charge a fee for,
acceptance of support, warranty, indemnity, or other liability obligations
and/or rights consistent with this License. However, in accepting such
obligations, You may act only on Your own behalf and on Your sole
responsibility, not on behalf of any other Contributor, and only if You agree
to indemnify, defend, and hold each Contributor harmless for any liability
incurred by, or claims asserted against, such Contributor by reason of your
accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS

## Fira Sans — SIL Open Font License 1.1

Digitized data copyright (c) 2012-2015, The Mozilla Foundation and Telefonica
S.A.

SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007

PREAMBLE

The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership with
others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The fonts,
including any derivative works, can be bundled, embedded, redistributed
and/or sold with any software provided that any reserved names are not used
by derivative works. The fonts and derivatives, however, cannot be released
under any other type of license. The requirement for fonts to remain under
this license does not apply to any document created using the fonts or their
derivatives.

DEFINITIONS

“Font Software” refers to the set of files released by the Copyright Holder(s)
under this license and clearly marked as such. This may include source files,
build scripts and documentation.

“Reserved Font Name” refers to any names specified as such after the copyright
statement(s).

“Original Version” refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

“Modified Version” refers to any derivative made by adding to, deleting, or
substituting — in part or in whole — any of the components of the Original
Version, by changing formats or by porting the Font Software to a new
environment.

“Author” refers to any designer, engineer, programmer, technical writer or
other person who contributed to the Font Software.

PERMISSION & CONDITIONS

Permission is hereby granted, free of charge, to any person obtaining a copy
of the Font Software, to use, study, copy, merge, embed, modify, redistribute,
and sell modified and unmodified copies of the Font Software, subject to the
following conditions:

1) Neither the Font Software nor any of its individual components, in Original
or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy contains
the above copyright notice and this license. These can be included either as
stand-alone text files, human-readable headers or in the appropriate
machine-readable metadata fields within text or binary files as long as those
fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font Name(s)
unless explicit written permission is granted by the corresponding Copyright
Holder. This restriction only applies to the primary font name as presented to
the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font Software
shall not be used to promote, endorse or advertise any Modified Version,
except to acknowledge the contribution(s) of the Copyright Holder(s) and the
Author(s) or with their explicit written permission.

5) The Font Software, modified or unmodified, in part or in whole, must be
distributed entirely under this license, and must not be distributed under
any other license. The requirement for fonts to remain under this license does
not apply to any document created using the Font Software.

TERMINATION

This license becomes null and void if any of the above conditions are not met.

DISCLAIMER

THE FONT SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF COPYRIGHT, PATENT,
TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE FOR
ANY CLAIM, DAMAGES OR OTHER LIABILITY, INCLUDING ANY GENERAL, SPECIAL,
INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF THE USE OR INABILITY TO USE
THE FONT SOFTWARE OR FROM OTHER DEALINGS IN THE FONT SOFTWARE.

## zip.js — BSD 3-Clause license carried by the distributed source

Copyright (c) 2013 Gildas Lormeau. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

3. The names of the authors may not be used to endorse or promote products
derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED “AS IS” AND ANY EXPRESS OR IMPLIED WARRANTIES,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

## Monaco version evidence (no guessed single version)

- npm lock identity: `0.14.3`.
- distributed AMD loader reports: `0.14.6`.
- distributed `external/monaco-editor-min/vs/loader.js` SHA-256: `0c272c30972d036de6dec5e9d51ac358c11be58b4eef0fba4c85151f30e72ba6`.
- The matching package-local `LICENSE` and `ThirdPartyNotices.txt` are copied verbatim below.
- This evidence conflict is recorded explicitly; the distribution does not claim one Monaco semantic version.

## BBText pixi-multistyle-text byte and license evidence

- vendored `Extensions/BBText/pixi-multistyle-text/README.md` SHA-256: `36e1ccc5e973f62062f4aa767c0206fe33c052bbb9279535caa8f8bec626f8bf`.
- vendored `Extensions/BBText/pixi-multistyle-text/dist/pixi-multistyle-text.d.ts` SHA-256: `4d87f9033669b19e01c8626db64c095404932fe18ddef58399571f9c749d704f`.
- vendored `Extensions/BBText/pixi-multistyle-text/dist/pixi-multistyle-text.umd.js` SHA-256: `198df3e1399b06884328b882207df88ebd00fc6f65642f4c44a07bab5694c7ca`.
- attribution repository: `https://github.com/tleunen/pixi-multistyle-text.git`.
- license text source pinned to commit: `3a42873661533af916867f49917f47e764a26181`.
- upstream license source SHA-256: `268d10da911a73347c8c3eacc511aea1a99e1ef151ad90d7ddb5508d46b6bc7e`; repository copy SHA-256: `c57ae452dc3235880941f51a0cdd80f4f614014292c49e831221a0bf72fffd12`.
- The vendored derivative exact upstream code revision is unknown. The pinned commit identifies the separately preserved license text only; no byte equivalence is claimed.

## Playmesh logo build provenance (no rights conclusion)

- repository source: `assets/branding/playmesh-mark.png`.
- source and distributed-copy SHA-256: `67ded8c45a9814e0e138ab6f677409be3775d63f7ee33ef5b7570314cc5a4218`.
- pixel contract: `playmesh-transparent-mark-v1`.
- The build system records byte provenance only; it does not assert copyright or trademark ownership.

## Separate Firebase evidence chains

- WebIDE npm package: `9.0.0-beta.2`, lock integrity `sha512-gbcJ2sg/ECEP72sn2o4CRI2EjoF0r+v9jZ6zOZ1E/keWpTbZacWvMT4troW9LSmY5lxGBE2grl+EoWSD57Jrdg==`, dependency commit `d92a36260a856026263b29955551284d9ee29a58`, package metadata SHA-256 `8774d51797d604c5ab25de8fa16d064febb2e4e67d8a996db1fb7290057f7a94`, license declaration `Apache-2.0`.
- GDJS runtime package: `8.3.3` per the separately collected `Extensions/Firebase/A_firebasejs/NOTICE.txt`; its `LICENSE.md` and NOTICE are collected below.
- Both components use Apache-2.0, but their version and material evidence are intentionally kept separate.

## Mechanically collected verbatim materials

---

## Verbatim material: GDevelop upstream LICENSE.md

Source in locked build input: `LICENSE.md`  
Normalized-text SHA-256: `d0e2c4c090f460088a83dcfeea90af3b98bde627545fd8eb80c22f24ec1d76e8`

* The Core library, the game engine, the new IDE, and all extensions (respectively *Core*, *GDJS*, *new IDE* and *Extensions* folders) are under the **MIT license**.
* The name, GDevelop, and its logo are the exclusive property of Florian Rival.

See the license.md in each folders for the full licenses.

---

## Verbatim material: GDevelop upstream Core/LICENSE.md

Source in locked build input: `Core/LICENSE.md`  
Normalized-text SHA-256: `8b9bbb2b04450d5e74d5b52507e99339469535c89e409c9807f698ad5039bcea`

GDevelop Core (GDCore)
--------------------------

The MIT License (MIT)

Copyright (c) 2008-2016 Florian Rival

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


External libraries used by GDevelop Core
--------------------------------------------

* SFML is distributed under the zlib/png license

---

## Verbatim material: GDevelop upstream GDJS/LICENSE.md

Source in locked build input: `GDJS/LICENSE.md`  
Normalized-text SHA-256: `60da76f2c1dce18c4bc866d6f17dd76b419cf277cc76055caaeab2ed6510afa6`

GDevelop JS Platform (GDJS)
--------------------------------

The MIT License (MIT)

Copyright (c) 2008-2017 Florian Rival

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

External libraries used by GDevelop JS Platform
---------------------------------------------------

* Pixi.js is distributed under the MIT license

---

## Verbatim material: GDevelop upstream Extensions/LICENSE.md

Source in locked build input: `Extensions/LICENSE.md`  
Normalized-text SHA-256: `882e10bc3f67e248472048ffd5d869a03eabcbecf38c29fc3da7af10a095dac8`

GDevelop extensions
-------------------

The MIT License (MIT)

Copyright (c) 2008-2016 Florian Rival

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


External libraries used by extensions
-------------------------------------

For external libraries, refer to the readme or license file included in their
directories

---

## Verbatim material: GDevelop upstream newIDE/LICENSE.md

Source in locked build input: `newIDE/LICENSE.md`  
Normalized-text SHA-256: `b5d6551a329a77b3d2a02c8bf6ce2792bb4e5f2968209f176a6c2efa5562e431`

GDevelop IDE
------------

The MIT License (MIT)

Copyright (c) 2017 Florian Rival

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

---

## Verbatim material: monaco-editor LICENSE

Source in locked build input: `newIDE/app/node_modules/monaco-editor/LICENSE`  
Normalized-text SHA-256: `806766baa9009e389d0163173365c947273b560e1fedfacfc60e8d7bab6057da`

The MIT License (MIT)

Copyright (c) 2016 - present Microsoft Corporation

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

---

## Verbatim material: monaco-editor ThirdPartyNotices.txt

Source in locked build input: `newIDE/app/node_modules/monaco-editor/ThirdPartyNotices.txt`  
Normalized-text SHA-256: `7cd73d2ef8f338c8073ed58e206b75b5d20845b93a0a17cf6e22e985f3c8a1af`

THIRD-PARTY SOFTWARE NOTICES AND INFORMATION
Do Not Translate or Localize

This project incorporates components from the projects listed below. The original copyright notices and the licenses
under which Microsoft received such components are set forth below. Microsoft reserves all rights not expressly granted
herein, whether by implication, estoppel or otherwise.




%% winjs version 4.4.0 (https://github.com/winjs/winjs)
=========================================
WinJS

Copyright (c) Microsoft Corporation

All rights reserved.

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the ""Software""), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=========================================
END OF winjs NOTICES AND INFORMATION




%% string_scorer version 0.1.20 (https://github.com/joshaven/string_score)
=========================================
This software is released under the MIT license:

Copyright (c) Joshaven Potter

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
=========================================
END OF string_scorer NOTICES AND INFORMATION




%% chjj-marked NOTICES AND INFORMATION BEGIN HERE
=========================================
The MIT License (MIT)

Copyright (c) 2011-2014, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
=========================================
END OF chjj-marked NOTICES AND INFORMATION



%% typescript version 2.7.2 (https://github.com/Microsoft/TypeScript)
=========================================
Copyright (c) Microsoft Corporation. All rights reserved.

Apache License

Version 2.0, January 2004

http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

"License" shall mean the terms and conditions for use, reproduction, and distribution as defined by Sections 1 through 9 of this document.

"Licensor" shall mean the copyright owner or entity authorized by the copyright owner that is granting the License.

"Legal Entity" shall mean the union of the acting entity and all other entities that control, are controlled by, or are under common control with that entity. For the purposes of this definition, "control" means (i) the power, direct or indirect, to cause the direction or management of such entity, whether by contract or otherwise, or (ii) ownership of fifty percent (50%) or more of the outstanding shares, or (iii) beneficial ownership of such entity.

"You" (or "Your") shall mean an individual or Legal Entity exercising permissions granted by this License.

"Source" form shall mean the preferred form for making modifications, including but not limited to software source code, documentation source, and configuration files.

"Object" form shall mean any form resulting from mechanical transformation or translation of a Source form, including but not limited to compiled object code, generated documentation, and conversions to other media types.

"Work" shall mean the work of authorship, whether in Source or Object form, made available under the License, as indicated by a copyright notice that is included in or attached to the work (an example is provided in the Appendix below).

"Derivative Works" shall mean any work, whether in Source or Object form, that is based on (or derived from) the Work and for which the editorial revisions, annotations, elaborations, or other modifications represent, as a whole, an original work of authorship. For the purposes of this License, Derivative Works shall not include works that remain separable from, or merely link (or bind by name) to the interfaces of, the Work and Derivative Works thereof.

"Contribution" shall mean any work of authorship, including the original version of the Work and any modifications or additions to that Work or Derivative Works thereof, that is intentionally submitted to Licensor for inclusion in the Work by the copyright owner or by an individual or Legal Entity authorized to submit on behalf of the copyright owner. For the purposes of this definition, "submitted" means any form of electronic, verbal, or written communication sent to the Licensor or its representatives, including but not limited to communication on electronic mailing lists, source code control systems, and issue tracking systems that are managed by, or on behalf of, the Licensor for the purpose of discussing and improving the Work, but excluding communication that is conspicuously marked or otherwise designated in writing by the copyright owner as "Not a Contribution."

"Contributor" shall mean Licensor and any individual or Legal Entity on behalf of whom a Contribution has been received by Licensor and subsequently incorporated within the Work.

2. Grant of Copyright License. Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable copyright license to reproduce, prepare Derivative Works of, publicly display, publicly perform, sublicense, and distribute the Work and such Derivative Works in Source or Object form.

3. Grant of Patent License. Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable (except as stated in this section) patent license to make, have made, use, offer to sell, sell, import, and otherwise transfer the Work, where such license applies only to those patent claims licensable by such Contributor that are necessarily infringed by their Contribution(s) alone or by combination of their Contribution(s) with the Work to which such Contribution(s) was submitted. If You institute patent litigation against any entity (including a cross-claim or counterclaim in a lawsuit) alleging that the Work or a Contribution incorporated within the Work constitutes direct or contributory patent infringement, then any patent licenses granted to You under this License for that Work shall terminate as of the date such litigation is filed.

4. Redistribution. You may reproduce and distribute copies of the Work or Derivative Works thereof in any medium, with or without modifications, and in Source or Object form, provided that You meet the following conditions:

You must give any other recipients of the Work or Derivative Works a copy of this License; and

You must cause any modified files to carry prominent notices stating that You changed the files; and

You must retain, in the Source form of any Derivative Works that You distribute, all copyright, patent, trademark, and attribution notices from the Source form of the Work, excluding those notices that do not pertain to any part of the Derivative Works; and

If the Work includes a "NOTICE" text file as part of its distribution, then any Derivative Works that You distribute must include a readable copy of the attribution notices contained within such NOTICE file, excluding those notices that do not pertain to any part of the Derivative Works, in at least one of the following places: within a NOTICE text file distributed as part of the Derivative Works; within the Source form or documentation, if provided along with the Derivative Works; or, within a display generated by the Derivative Works, if and wherever such third-party notices normally appear. The contents of the NOTICE file are for informational purposes only and do not modify the License. You may add Your own attribution notices within Derivative Works that You distribute, alongside or as an addendum to the NOTICE text from the Work, provided that such additional attribution notices cannot be construed as modifying the License. You may add Your own copyright statement to Your modifications and may provide additional or different license terms and conditions for use, reproduction, or distribution of Your modifications, or for any such Derivative Works as a whole, provided Your use, reproduction, and distribution of the Work otherwise complies with the conditions stated in this License.

5. Submission of Contributions. Unless You explicitly state otherwise, any Contribution intentionally submitted for inclusion in the Work by You to the Licensor shall be under the terms and conditions of this License, without any additional terms or conditions. Notwithstanding the above, nothing herein shall supersede or modify the terms of any separate license agreement you may have executed with Licensor regarding such Contributions.

6. Trademarks. This License does not grant permission to use the trade names, trademarks, service marks, or product names of the Licensor, except as required for reasonable and customary use in describing the origin of the Work and reproducing the content of the NOTICE file.

7. Disclaimer of Warranty. Unless required by applicable law or agreed to in writing, Licensor provides the Work (and each Contributor provides its Contributions) on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied, including, without limitation, any warranties or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A PARTICULAR PURPOSE. You are solely responsible for determining the appropriateness of using or redistributing the Work and assume any risks associated with Your exercise of permissions under this License.

8. Limitation of Liability. In no event and under no legal theory, whether in tort (including negligence), contract, or otherwise, unless required by applicable law (such as deliberate and grossly negligent acts) or agreed to in writing, shall any Contributor be liable to You for damages, including any direct, indirect, special, incidental, or consequential damages of any character arising as a result of this License or out of the use or inability to use the Work (including but not limited to damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses), even if such Contributor has been advised of the possibility of such damages.

9. Accepting Warranty or Additional Liability. While redistributing the Work or Derivative Works thereof, You may choose to offer, and charge a fee for, acceptance of support, warranty, indemnity, or other liability obligations and/or rights consistent with this License. However, in accepting such obligations, You may act only on Your own behalf and on Your sole responsibility, not on behalf of any other Contributor, and only if You agree to indemnify, defend, and hold each Contributor harmless for any liability incurred by, or claims asserted against, such Contributor by reason of your accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS
=========================================
END OF typescript NOTICES AND INFORMATION



%% HTML 5.1 W3C Working Draft version 08 October 2015 (http://www.w3.org/TR/2015/WD-html51-20151008/)
=========================================
Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang). This software or document includes material copied
from or derived from HTML 5.1 W3C Working Draft (http://www.w3.org/TR/2015/WD-html51-20151008/.)

THIS DOCUMENT IS PROVIDED "AS IS," AND COPYRIGHT HOLDERS MAKE NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR IMPLIED, INCLUDING, BUT
NOT LIMITED TO, WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, NON-INFRINGEMENT, OR TITLE; THAT THE CONTENTS OF
THE DOCUMENT ARE SUITABLE FOR ANY PURPOSE; NOR THAT THE IMPLEMENTATION OF SUCH CONTENTS WILL NOT INFRINGE ANY THIRD PARTY
PATENTS, COPYRIGHTS, TRADEMARKS OR OTHER RIGHTS.

COPYRIGHT HOLDERS WILL NOT BE LIABLE FOR ANY DIRECT, INDIRECT, SPECIAL OR CONSEQUENTIAL DAMAGES ARISING OUT OF ANY USE OF THE
DOCUMENT OR THE PERFORMANCE OR IMPLEMENTATION OF THE CONTENTS THEREOF.

The name and trademarks of copyright holders may NOT be used in advertising or publicity pertaining to this document or its contents
without specific, written prior permission. Title to copyright in this document will at all times remain with copyright holders.
=========================================
END OF HTML 5.1 W3C Working Draft NOTICES AND INFORMATION




%% JS Beautifier version 1.6.2 (https://github.com/beautify-web/js-beautify)
=========================================
The MIT License (MIT)

Copyright (c) 2007-2017 Einar Lielmanis, Liam Newman, and contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
=========================================
END OF js-beautify NOTICES AND INFORMATION




%% Ionic documentation version 1.2.4 (https://github.com/driftyco/ionic-site)
=========================================
Copyright Drifty Co. http://drifty.com/.

Apache License

Version 2.0, January 2004

http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

"License" shall mean the terms and conditions for use, reproduction, and distribution as defined by Sections 1 through 9 of this document.

"Licensor" shall mean the copyright owner or entity authorized by the copyright owner that is granting the License.

"Legal Entity" shall mean the union of the acting entity and all other entities that control, are controlled by, or are under common control with that entity. For the purposes of this definition, "control" means (i) the power, direct or indirect, to cause the direction or management of such entity, whether by contract or otherwise, or (ii) ownership of fifty percent (50%) or more of the outstanding shares, or (iii) beneficial ownership of such entity.

"You" (or "Your") shall mean an individual or Legal Entity exercising permissions granted by this License.

"Source" form shall mean the preferred form for making modifications, including but not limited to software source code, documentation source, and configuration files.

"Object" form shall mean any form resulting from mechanical transformation or translation of a Source form, including but not limited to compiled object code, generated documentation, and conversions to other media types.

"Work" shall mean the work of authorship, whether in Source or Object form, made available under the License, as indicated by a copyright notice that is included in or attached to the work (an example is provided in the Appendix below).

"Derivative Works" shall mean any work, whether in Source or Object form, that is based on (or derived from) the Work and for which the editorial revisions, annotations, elaborations, or other modifications represent, as a whole, an original work of authorship. For the purposes of this License, Derivative Works shall not include works that remain separable from, or merely link (or bind by name) to the interfaces of, the Work and Derivative Works thereof.

"Contribution" shall mean any work of authorship, including the original version of the Work and any modifications or additions to that Work or Derivative Works thereof, that is intentionally submitted to Licensor for inclusion in the Work by the copyright owner or by an individual or Legal Entity authorized to submit on behalf of the copyright owner. For the purposes of this definition, "submitted" means any form of electronic, verbal, or written communication sent to the Licensor or its representatives, including but not limited to communication on electronic mailing lists, source code control systems, and issue tracking systems that are managed by, or on behalf of, the Licensor for the purpose of discussing and improving the Work, but excluding communication that is conspicuously marked or otherwise designated in writing by the copyright owner as "Not a Contribution."

"Contributor" shall mean Licensor and any individual or Legal Entity on behalf of whom a Contribution has been received by Licensor and subsequently incorporated within the Work.

2. Grant of Copyright License. Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable copyright license to reproduce, prepare Derivative Works of, publicly display, publicly perform, sublicense, and distribute the Work and such Derivative Works in Source or Object form.

3. Grant of Patent License. Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable (except as stated in this section) patent license to make, have made, use, offer to sell, sell, import, and otherwise transfer the Work, where such license applies only to those patent claims licensable by such Contributor that are necessarily infringed by their Contribution(s) alone or by combination of their Contribution(s) with the Work to which such Contribution(s) was submitted. If You institute patent litigation against any entity (including a cross-claim or counterclaim in a lawsuit) alleging that the Work or a Contribution incorporated within the Work constitutes direct or contributory patent infringement, then any patent licenses granted to You under this License for that Work shall terminate as of the date such litigation is filed.

4. Redistribution. You may reproduce and distribute copies of the Work or Derivative Works thereof in any medium, with or without modifications, and in Source or Object form, provided that You meet the following conditions:

You must give any other recipients of the Work or Derivative Works a copy of this License; and

You must cause any modified files to carry prominent notices stating that You changed the files; and

You must retain, in the Source form of any Derivative Works that You distribute, all copyright, patent, trademark, and attribution notices from the Source form of the Work, excluding those notices that do not pertain to any part of the Derivative Works; and

If the Work includes a "NOTICE" text file as part of its distribution, then any Derivative Works that You distribute must include a readable copy of the attribution notices contained within such NOTICE file, excluding those notices that do not pertain to any part of the Derivative Works, in at least one of the following places: within a NOTICE text file distributed as part of the Derivative Works; within the Source form or documentation, if provided along with the Derivative Works; or, within a display generated by the Derivative Works, if and wherever such third-party notices normally appear. The contents of the NOTICE file are for informational purposes only and do not modify the License. You may add Your own attribution notices within Derivative Works that You distribute, alongside or as an addendum to the NOTICE text from the Work, provided that such additional attribution notices cannot be construed as modifying the License. You may add Your own copyright statement to Your modifications and may provide additional or different license terms and conditions for use, reproduction, or distribution of Your modifications, or for any such Derivative Works as a whole, provided Your use, reproduction, and distribution of the Work otherwise complies with the conditions stated in this License.

5. Submission of Contributions. Unless You explicitly state otherwise, any Contribution intentionally submitted for inclusion in the Work by You to the Licensor shall be under the terms and conditions of this License, without any additional terms or conditions. Notwithstanding the above, nothing herein shall supersede or modify the terms of any separate license agreement you may have executed with Licensor regarding such Contributions.

6. Trademarks. This License does not grant permission to use the trade names, trademarks, service marks, or product names of the Licensor, except as required for reasonable and customary use in describing the origin of the Work and reproducing the content of the NOTICE file.

7. Disclaimer of Warranty. Unless required by applicable law or agreed to in writing, Licensor provides the Work (and each Contributor provides its Contributions) on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied, including, without limitation, any warranties or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A PARTICULAR PURPOSE. You are solely responsible for determining the appropriateness of using or redistributing the Work and assume any risks associated with Your exercise of permissions under this License.

8. Limitation of Liability. In no event and under no legal theory, whether in tort (including negligence), contract, or otherwise, unless required by applicable law (such as deliberate and grossly negligent acts) or agreed to in writing, shall any Contributor be liable to You for damages, including any direct, indirect, special, incidental, or consequential damages of any character arising as a result of this License or out of the use or inability to use the Work (including but not limited to damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses), even if such Contributor has been advised of the possibility of such damages.

9. Accepting Warranty or Additional Liability. While redistributing the Work or Derivative Works thereof, You may choose to offer, and charge a fee for, acceptance of support, warranty, indemnity, or other liability obligations and/or rights consistent with this License. However, in accepting such obligations, You may act only on Your own behalf and on Your sole responsibility, not on behalf of any other Contributor, and only if You agree to indemnify, defend, and hold each Contributor harmless for any liability incurred by, or claims asserted against, such Contributor by reason of your accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS
=========================================
END OF Ionic documentation NOTICES AND INFORMATION



%% vscode-swift version 0.0.1 (https://github.com/owensd/vscode-swift)
=========================================
The MIT License (MIT)

Copyright (c) 2015 David Owens II

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
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
=========================================
END OF vscode-swift NOTICES AND INFORMATION

---

## Verbatim material: react LICENSE

Source in locked build input: `newIDE/app/node_modules/react/LICENSE`  
Normalized-text SHA-256: `a80c79b8f80e824c8ea0612b7abadb9c92c48673cf0adc20b2a7f43e2b19faa0`

MIT License

Copyright (c) Facebook, Inc. and its affiliates.

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

---

## Verbatim material: WebIDE Firebase 9.0.0-beta.2 package Apache-2.0 evidence

Source in locked build input: `newIDE/app/node_modules/firebase/package.json`  
Normalized-text SHA-256: `fe9038d4f1944d8b8419f3c651c3212f88373efec29f40d46e27a31126270d82`

{
  "name": "firebase",
  "version": "9.0.0-beta.2",
  "private": false,
  "description": "Firebase JavaScript library for web and Node.js",
  "author": "Firebase <firebase-support@google.com> (https://firebase.google.com/)",
  "license": "Apache-2.0",
  "homepage": "https://firebase.google.com/",
  "keywords": [
    "authentication",
    "database",
    "Firebase",
    "firebase",
    "realtime",
    "storage",
    "performance",
    "remote-config"
  ],
  "files": [
    "**/dist/",
    "**/package.json",
    "/firebase*.js",
    "/firebase*.map",
    "compat/index.d.ts"
  ],
  "exports": {
    "./analytics": {
      "node": "./analytics/dist/index.cjs.js",
      "default": "./analytics/dist/index.esm.js"
    },
    "./app": {
      "node": "./app/dist/index.cjs.js",
      "default": "./app/dist/index.esm.js"
    },
    "./auth": {
      "node": "./auth/dist/index.cjs.js",
      "default": "./auth/dist/index.esm.js"
    },
    "./database": {
      "node": "./database/dist/index.cjs.js",
      "default": "./database/dist/index.esm.js"
    },
    "./firestore": {
      "node": "./firestore/dist/index.cjs.js",
      "default": "./firestore/dist/index.esm.js"
    },
    "./firestore/lite": {
      "node": "./firestore/lite/dist/index.cjs.js",
      "default": "./firestore/lite/dist/index.esm.js"
    },
    "./functions": {
      "node": "./functions/dist/index.cjs.js",
      "default": "./functions/dist/index.esm.js"
    },
    "./messaging": {
      "node": "./messaging/dist/index.cjs.js",
      "default": "./messaging/dist/index.esm.js"
    },
    "./performance": {
      "node": "./performance/dist/index.cjs.js",
      "default": "./performance/dist/index.esm.js"
    },
    "./remote-config": {
      "node": "./remote-config/dist/index.cjs.js",
      "default": "./remote-config/dist/index.esm.js"
    },
    "./storage": {
      "node": "./storage/dist/index.cjs.js",
      "default": "./storage/dist/index.esm.js"
    },
    "./compat/analytics": {
      "node": "./compat/analytics/dist/index.cjs.js",
      "default": "./compat/analytics/dist/index.esm.js"
    },
    "./compat/app": {
      "node": "./compat/app/dist/index.cjs.js",
      "default": "./compat/app/dist/index.esm.js"
    },
    "./compat/auth": {
      "node": "./compat/auth/dist/index.cjs.js",
      "default": "./compat/auth/dist/index.esm.js"
    },
    "./compat/database": {
      "node": "./compat/database/dist/index.cjs.js",
      "default": "./compat/database/dist/index.esm.js"
    },
    "./compat/firestore": {
      "node": "./compat/firestore/dist/index.cjs.js",
      "default": "./compat/firestore/dist/index.esm.js"
    },
    "./compat/functions": {
      "node": "./compat/functions/dist/index.cjs.js",
      "default": "./compat/functions/dist/index.esm.js"
    },
    "./compat/messaging": {
      "node": "./compat/messaging/dist/index.cjs.js",
      "default": "./compat/messaging/dist/index.esm.js"
    },
    "./compat/performance": {
      "node": "./compat/performance/dist/index.cjs.js",
      "default": "./compat/performance/dist/index.esm.js"
    },
    "./compat/remote-config": {
      "node": "./compat/remote-config/dist/index.cjs.js",
      "default": "./compat/remote-config/dist/index.esm.js"
    },
    "./compat/storage": {
      "node": "./compat/storage/dist/index.cjs.js",
      "default": "./compat/storage/dist/index.esm.js"
    }
  },
  "repository": {
    "type": "git",
    "url": "https://github.com/firebase/firebase-js-sdk.git"
  },
  "scripts": {
    "build": "rollup -c && gulp firebase-js && yarn build:compat",
    "build:release": "rollup -c rollup.config.release.js && gulp firebase-js && yarn build:compat:release",
    "build:compat": "rollup -c compat/rollup.config.js",
    "build:compat:release": "rollup -c compat/rollup.config.release.js",
    "dev": "rollup -c -w",
    "test": "echo 'No test suite for firebase wrapper'",
    "test:ci": "echo 'No test suite for firebase wrapper'"
  },
  "dependencies": {
    "@firebase/analytics": "0.0.900-exp.d92a36260",
    "@firebase/analytics-compat": "0.0.900-exp.d92a36260",
    "@firebase/app": "0.0.900-exp.d92a36260",
    "@firebase/app-compat": "0.0.900-exp.d92a36260",
    "@firebase/auth": "0.0.900-exp.d92a36260",
    "@firebase/auth-compat": "0.0.900-exp.d92a36260",
    "@firebase/database": "0.0.900-exp.d92a36260",
    "@firebase/functions": "0.0.900-exp.d92a36260",
    "@firebase/functions-compat": "0.0.900-exp.d92a36260",
    "@firebase/firestore": "0.0.900-exp.d92a36260",
    "@firebase/storage": "0.0.900-exp.d92a36260",
    "@firebase/performance": "0.0.900-exp.d92a36260",
    "@firebase/performance-compat": "0.0.900-exp.d92a36260",
    "@firebase/remote-config": "0.0.900-exp.d92a36260",
    "@firebase/remote-config-compat": "0.0.900-exp.d92a36260",
    "@firebase/messaging": "0.0.900-exp.d92a36260",
    "@firebase/messaging-compat": "0.0.900-exp.d92a36260",
    "@firebase/firestore-compat": "0.0.900-exp.d92a36260",
    "@firebase/storage-compat": "0.0.900-exp.d92a36260",
    "@firebase/database-compat": "0.0.900-exp.d92a36260"
  },
  "devDependencies": {
    "rollup": "2.35.1",
    "@rollup/plugin-commonjs": "17.1.0",
    "rollup-plugin-license": "2.2.0",
    "@rollup/plugin-node-resolve": "11.2.0",
    "rollup-plugin-sourcemaps": "0.6.3",
    "rollup-plugin-terser": "7.0.2",
    "rollup-plugin-typescript2": "0.29.0",
    "rollup-plugin-uglify": "6.0.4",
    "@rollup/plugin-alias": "3.1.1",
    "gulp": "4.0.2",
    "gulp-sourcemaps": "3.0.0",
    "gulp-concat": "2.6.1",
    "typescript": "4.2.2"
  },
  "components": [
    "analytics",
    "app",
    "auth",
    "functions",
    "firestore",
    "firestore/lite",
    "storage",
    "performance",
    "remote-config",
    "messaging",
    "database"
  ],
  "peerDependencies": {}
}

---

## Verbatim material: Firebase runtime LICENSE.md

Source in locked build input: `Extensions/Firebase/A_firebasejs/LICENSE.md`  
Normalized-text SHA-256: `58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd`


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

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

---

## Verbatim material: Firebase runtime NOTICE.txt

Source in locked build input: `Extensions/Firebase/A_firebasejs/NOTICE.txt`  
Normalized-text SHA-256: `140b822b17f1aff441b0a155f279477011985df44522472952efa4bc81726496`

This is the firebase js sdk, downloadable from https://firebase.google.com/docs/web/setup/#expandable-8. 
The file and sourcemaps names have been modified to be loaded properly by GDevelop.
The source can be found on https://github.com/firebase/firebase-js-sdk.
Type definitions can be found at https://www.unpkg.com/firebase/index.d.ts. 
They have been modified to remove the exports at the bottom in order to work with GDevelop.
The version of the Firebase SDK used is 8.3.3.

---

## Verbatim material: DialogueTree bundled bondage.js LICENSE

Source in locked build input: `Extensions/DialogueTree/bondage.js/LICENSE.md`  
Normalized-text SHA-256: `126bd86e0c1e5ca9b74890a1a739ca625c2ee0ed3df4c2f28b01269933c33c73`

The MIT License (MIT)

Copyright (c) 2017 j hayley

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

---

## Verbatim material: DialogueTree bundled bondage.js version evidence

Source in locked build input: `Extensions/DialogueTree/bondage.js/version.txt`  
Normalized-text SHA-256: `abcc59bd2eaa740fb7daf2b22affd92b14ab2cd7870065e5dcb1d99f4a345ca0`

This extension is using bondage.js library to parse yarn syntax.
https://github.com/hylyh/bondage.js

The current build used is built from commit 3c63e21

---

## Verbatim material: BBText bundled pixi-multistyle-text README attribution evidence

Source in locked build input: `Extensions/BBText/pixi-multistyle-text/README.md`  
Normalized-text SHA-256: `b14d19e40198a4409b9d48952e0d5f3d43259e86cad6d61a6d1a585162fa804d`

# pixi-multistyle-text

[![NPM](https://nodei.co/npm/pixi-multistyle-text.png)](https://nodei.co/npm/pixi-multistyle-text/)

Add a `MultiStyleText` object inside [pixi.js](https://github.com/GoodBoyDigital/pixi.js) to easily create text using different styles.

## Example

In the example below, we are defining 4 text styles.
`default` is the default style for the text, and the others matches the tags inside the text.

```js
let text = new MultiStyleText("Let's make some <ml>multiline</ml>\nand <ms>multistyle</ms> text for\n<pixi>Pixi.js!</pixi>",
{
    "default": {
        fontFamily: "Arial",
        fontSize: "24px",
        fill: "#cccccc",
        align: "center"
    },
    "ml": {
        fontStyle: "italic",
        fill: "#ff8888"
    },
    "ms": {
        fontStyle: "italic",
        fill: "#4488ff"
    },
    "pixi": {
        fontSize: "64px",
        fill: "#efefef"
    }
});
```

## Build instructions

The library is no longer maintain and need this fix to work with Pixi 7: 
- [Fix empty color attribute errors with Pixi 7](https://github.com/D8H/pixi-multistyle-text/pull/1)

```bash
yarn install
yarn build
```

## Usage

### `text = new MultiStyleText(text, textStyles)`

Creates a new `MultiStyleText` with the given text and styles.

#### `textStyles`

Type: `{ [key: string]: ExtendedTextStyle }`

Each key of this dictionary should match with a tag in the text. Use the key `default` for the default style.

Each `ExtendedTextStyle` object can have [any of the properties of a standard PIXI text style](http://pixijs.download/release/docs/PIXI.TextStyle.html), in addition to a `valign` property that allows you to specify where text is rendered relative to larger text on the same line (`"top"`, `"middle"`, or `"bottom"`).

The `align`, `wordWrap`, `wordWrapWidth`, and `breakWord` properties are ignored on all styles _except for the `default` style_, which controls those properties for the entire text object.

If text is rendered without any value assigned to a given parameter, Pixi's defaults are used.

## Demo

```bash
yarn demo
```

## License

MIT, see [LICENSE.md](http://github.com/tleunen/pixi-multistyle-text/blob/master/LICENSE.md) for details.

---

## Verbatim material: BBText pixi-multistyle-text MIT license text pinned separately

Source in locked build input: `third_party/gdevelop/pixi-multistyle-text-LICENSE.md`  
Normalized-text SHA-256: `ee5e1e086f8ea9f7d75feaeeb16a1f9ccfebc5c6028721dda9686ddc69876f29`

The MIT License (MIT)

Copyright (c) 2014 Tommy Leunen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

---

## Verbatim material: GDJS runtime legal material

Source in locked build input: `Cordova/www/LICENSE.GDevelop.txt`  
Normalized-text SHA-256: `69dec409c40c2877275efcf0f025081e4601dde0339c0376931ebd55c812ad91`

Part of this app is using the GDevelop game engine, which is licensed under the MIT license.
Find more information on https://gdevelop.io/.

---

## Verbatim material: GDJS runtime legal material

Source in locked build input: `Extensions/Spine/spine-pixi-v7/Spine-Runtimes-License-Agreement.txt`  
Normalized-text SHA-256: `f4291c6d5efa51bbc3b40a6a9bc5cef5454c2a8ffe8044ef6d4229caeac30821`

Spine Runtimes License Agreement
Last updated February 20, 2024. Replaces all prior versions.

Copyright (c) 2013-2024, Esoteric Software LLC

Integration of the Spine Runtimes into software or otherwise creating derivative works of the Spine Runtimes is permitted under the terms and conditions of Section 2 of the Spine Editor License Agreement:
http://esotericsoftware.com/spine-editor-license

Otherwise, it is permitted to integrate the Spine Runtimes into software or otherwise create derivative works of the Spine Runtimes (collectively, "Products"), provided that each user of the Products must obtain their own Spine Editor license and redistribution of the Products in any form must include this license and copyright notice.

THE SPINE RUNTIMES ARE PROVIDED BY ESOTERIC SOFTWARE LLC "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL ESOTERIC SOFTWARE LLC BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES, BUSINESS INTERRUPTION, OR LOSS OF USE, DATA, OR PROFITS) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THE SPINE RUNTIMES, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

---

## Verbatim material: Webpack-emitted attribution

Source in locked build input: `Resource3DPreview.worker.e1fb31ba8feda867e3f0.worker.js.LICENSE.txt`  
Normalized-text SHA-256: `2985412ac9c57178d1c1a1170ad3926e80b7ce1eb2d196ad0a23885a9ede560d`

/**
 * @license
 * Copyright 2010-2023 Three.js Authors
 * SPDX-License-Identifier: MIT
 */

---

## Verbatim material: Webpack-emitted attribution

Source in locked build input: `static/js/7509.c18f5f3e.chunk.js.LICENSE.txt`  
Normalized-text SHA-256: `d12ebe74c388d46ecc522ab17eedf51c2d95222f526d37df004e28c7da079749`

/*!---------------------------------------------------------------------------------------------
 *  Copyright (C) David Owens II, owensd.io. All rights reserved.
 *--------------------------------------------------------------------------------------------*/

---

## Verbatim material: Webpack-emitted attribution

Source in locked build input: `static/js/8060.34df078e.chunk.js.LICENSE.txt`  
Normalized-text SHA-256: `ecb61f46146c353220b79d6da56d743583c91f4729a016e6a6ef50f7fefa5007`

/*!
	Copyright (c) 2018 Jed Watson.
	Licensed under the MIT License (MIT), see
	http://jedwatson.github.io/classnames
*/

/*!
  Copyright (c) 2016 Jed Watson.
  Licensed under the MIT License (MIT), see
  http://jedwatson.github.io/classnames
*/

/*! https://mths.be/punycode v1.4.1 by @mathias */

/**
 * @license
 * Copyright 2010-2023 Three.js Authors
 * SPDX-License-Identifier: MIT
 */

/**
 * @license
 * Copyright 2019 Kevin Verdieck, originally developed at Palantir Technologies, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @license
 * Lodash <https://lodash.com/>
 * Copyright JS Foundation and other contributors <https://js.foundation/>
 * Released under MIT license <https://lodash.com/license>
 * Based on Underscore.js 1.8.3 <http://underscorejs.org/LICENSE>
 * Copyright Jeremy Ashkenas, DocumentCloud and Investigative Reporters & Editors
 */

/**
 * @license
 * Lodash <https://lodash.com/>
 * Copyright OpenJS Foundation and other contributors <https://openjsf.org/>
 * Released under MIT license <https://lodash.com/license>
 * Based on Underscore.js 1.8.3 <http://underscorejs.org/LICENSE>
 * Copyright Jeremy Ashkenas, DocumentCloud and Investigative Reporters & Editors
 */

/**
 * @license React
 * react-is.production.min.js
 *
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

/**
 * A better abstraction over CSS.
 *
 * @copyright Oleg Isonen (Slobodskoi) / Isonen 2014-present
 * @website https://github.com/cssinjs/jss
 * @license MIT
 */

---

## Verbatim material: Webpack-emitted attribution

Source in locked build input: `static/js/8450.7a734dbe.chunk.js.LICENSE.txt`  
Normalized-text SHA-256: `d41b5a8fb4c433b42cb2dad5b0f09acd9ed9e9949507ee94e66aa38accdcad23`

/*! pako 2.0.2 https://github.com/nodeca/pako @license (MIT AND Zlib) */

---

## Verbatim material: Webpack-emitted attribution

Source in locked build input: `static/js/main.39ec779a.js.LICENSE.txt`  
Normalized-text SHA-256: `338f1c59a665a128bd3c6d21c1e3eece3851996eec6ae4e42a03689c9596cb4a`

/*!
 * Determine if an object is a Buffer
 *
 * @author   Feross Aboukhadijeh <https://feross.org>
 * @license  MIT
 */

/*!
Copyright (C) 2015-2017 Andrea Giammarchi - @WebReflection

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

/*! *****************************************************************************
Copyright (c) Microsoft Corporation. All rights reserved.
Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
MERCHANTABLITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing permissions
and limitations under the License.
***************************************************************************** */

/**
 * @license
 * Copyright 2017 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @license
 * Copyright 2019 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @license
 * Copyright 2020 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @license
 * Copyright 2020 Google LLC.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @license
 * Copyright 2021 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @license React
 * react-dom.production.min.js
 *
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

/**
 * @license React
 * react-jsx-runtime.production.min.js
 *
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

/**
 * @license React
 * react.production.min.js
 *
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

/**
 * @license React
 * scheduler.production.min.js
 *
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

/** @license React v16.13.1
 * react-is.production.min.js
 *
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */
