import Foundation
enum StikJITPairingFileStore {
 static let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("StikJIT", isDirectory: true)
  .appendingPathComponent("pairingFile.plist")
 static var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
 static func store(_ data: Data) throws {
  try validate(data)
  try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: fileURL, options: .atomic)
 }
 static func load() throws -> Data {
  let data = try Data(contentsOf: fileURL)
  try validate(data)
  return data
 }
 private static func validate(_ data: Data) throws {
  _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
 }
}
