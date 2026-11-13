// Signs an update with Peek's release key so installed copies of Peek will accept it.
//   UPDATE_PRIVATE_KEY=<base64 Ed25519 seed> swift scripts/sign-update.swift build/Peek.zip
// Prints the base64 signature. The key comes from the environment (a GitHub Actions secret), never a file in the repo.
import Foundation
import CryptoKit

let raw = ProcessInfo.processInfo.environment["UPDATE_PRIVATE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
guard CommandLine.arguments.count == 2, let seed = Data(base64Encoded: raw),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    FileHandle.standardError.write("usage: UPDATE_PRIVATE_KEY=... swift scripts/sign-update.swift <file>\n".data(using: .utf8)!)
    exit(1)
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
print(try key.signature(for: data).base64EncodedString())
