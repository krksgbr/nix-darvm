import Darwin
import Foundation

func duplicateOwnedSocketDescriptor(_ descriptor: Int32) throws -> Int32 {
  let duplicated = Darwin.dup(descriptor)
  guard duplicated >= 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
  return duplicated
}
