import CryptoKit
import Foundation

let args = CommandLine.arguments
// All arguments are public data: public key, file path, signature, signed byte count.
guard args.count == 5,
      let keyData = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[3]),
      let count = Int(args[4]), count >= 0 else { fatalError("Invalid signature verification inputs") }
let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
guard count <= data.count else { fatalError("Signed length exceeds file size") }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
guard key.isValidSignature(signature, for: data.prefix(count)) else { fatalError("Invalid Ed25519 signature") }
