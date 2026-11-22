# Wordlists

`bip39-english.txt` is the English wordlist of BIP-0039 (2048 words), byte for byte as published in
[bitcoin/bips](https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt)
(SHA-256 `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`). The same list ships
in the reference implementation [trezor/python-mnemonic](https://github.com/trezor/python-mnemonic)
under the MIT License (Copyright (c) 2013 Pavol Rusnak). Matilde uses it for the 12-word Matilde
key (`MatildeKeyWords.swift`, `docs/sync-encryption.md`).

The Swift copy in `Sources/MatildeKit/SyncCrypto/MatildeKeyWords.swift` is generated from this file:

    python3 packages/MatildeKit/Wordlists/generate.py

`MatildeKeyTests.testWordlistIsTheBIP39EnglishList` checks that the two agree with the published hash.

MIT License (python-mnemonic):

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
> associated documentation files (the "Software"), to deal in the Software without restriction,
> including without limitation the rights to use, copy, modify, merge, publish, distribute,
> sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions: The above copyright notice and this
> permission notice shall be included in all copies or substantial portions of the Software.
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.
